import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/music_metadata.dart';
import 'deezer_artwork_repository.dart';
import 'media_cache.dart';
import 'source_operation.dart';

/// Public metadata only. Tracker URLs, credentials and torrent hashes are never
/// sent to MusicBrainz or Cover Art Archive.
class MusicMetadataRepository {
  MusicMetadataRepository({
    required this.cache,
    http.Client? client,
    this.requestInterval = const Duration(milliseconds: 1100),
    this.requestTimeout = const Duration(seconds: 15),
  }) : client = client ?? http.Client();
  final DiskMediaCache cache;
  final http.Client client;
  final Duration requestInterval, requestTimeout;
  late final _artworkFallback = DeezerArtworkRepository(
    cache: cache,
    client: client,
    timeout: requestTimeout,
  );
  final Map<String, Future<Map<String, dynamic>>> _pending = {};
  final Map<String, Future<String?>> _covers = {};
  final List<_MetadataRequest> _requests = [];
  bool _requesting = false;
  DateTime? _lastRequest;
  bool _disposed = false;
  static const _agent = 'Mumpa/1.2.2 (https://github.com/d0rj/mumpa)';

  void _checkGeneration(int generation) {
    if (_disposed || generation != cache.generation) {
      throw const SourceCancelled();
    }
  }

  Future<Map<String, dynamic>> _api(
    String entity,
    Map<String, String> params, {
    bool lowPriority = false,
    SourceOperation? operation,
    int? expectedGeneration,
  }) {
    operation?.check();
    final generation = expectedGeneration ?? cache.generation;
    _checkGeneration(generation);
    final uri = Uri.https('musicbrainz.org', '/ws/2/$entity', {
      'fmt': 'json',
      ...params,
    });
    final key = 'mb:$uri';
    final pendingKey = '$generation:${operation?.hashCode ?? ''}:$key';
    return _pending.putIfAbsent(
      pendingKey,
      () => _fetchJson(uri, key, lowPriority, operation, generation)
          .whenComplete(() {
            _pending.remove(pendingKey);
          }),
    );
  }

  Future<http.Response> _schedule(
    Uri uri,
    bool lowPriority,
    SourceOperation? operation,
    int generation,
  ) {
    if (_disposed) {
      return Future.error(StateError('Музыкальный каталог закрыт.'));
    }
    final request = _MetadataRequest(uri, lowPriority, operation, generation);
    _requests.add(request);
    if (!_requesting) unawaited(_drainRequests());
    return request.result.future;
  }

  Future<void> _drainRequests() async {
    _requesting = true;
    try {
      while (_requests.isNotEmpty) {
        if (_lastRequest != null) {
          final delay =
              requestInterval - DateTime.now().difference(_lastRequest!);
          if (delay > Duration.zero) await Future<void>.delayed(delay);
        }
        if (_requests.isEmpty) break;
        final interactive = _requests.indexWhere((r) => !r.lowPriority);
        final request = _requests.removeAt(interactive < 0 ? 0 : interactive);
        try {
          if (_disposed) throw StateError('Музыкальный каталог закрыт.');
          _checkGeneration(request.generation);
          request.operation?.check();
          _lastRequest = DateTime.now();
          final pending = client
              .send(
                http.AbortableRequest(
                    'GET',
                    request.uri,
                    abortTrigger: request.operation?.whenCancelled,
                  )
                  ..headers.addAll({
                    'User-Agent': _agent,
                    'Accept': 'application/json',
                  }),
              )
              .then(http.Response.fromStream);
          request.result.complete(
            await (request.operation?.wait(pending) ?? pending).timeout(
              requestTimeout,
            ),
          );
        } catch (e, stack) {
          request.result.completeError(e, stack);
        }
      }
    } finally {
      _requesting = false;
    }
  }

  Future<Map<String, dynamic>> _fetchJson(
    Uri uri,
    String key,
    bool lowPriority,
    SourceOperation? operation,
    int generation,
  ) async {
    _checkGeneration(generation);
    final saved = await cache.read(key);
    _checkGeneration(generation);
    if (saved != null) {
      try {
        return Map<String, dynamic>.from(jsonDecode(utf8.decode(saved)) as Map);
      } catch (_) {
        await cache.remove(key);
      }
    }
    try {
      final response = await _schedule(uri, lowPriority, operation, generation);
      operation?.check();
      _checkGeneration(generation);
      if (response.statusCode == 503 || response.statusCode == 429) {
        throw const HttpException(
          'MusicBrainz временно ограничил запросы. Повтори позже.',
        );
      }
      if (response.statusCode != 200) {
        throw HttpException('MusicBrainz: HTTP ${response.statusCode}.');
      }
      if (response.bodyBytes.length > 4 * 1024 * 1024) {
        throw const FormatException(
          'Ответ музыкального каталога слишком большой.',
        );
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
      await cache.put(
        key,
        response.bodyBytes,
        extension: 'json',
        ttl: const Duration(days: 7),
        expectedGeneration: generation,
      );
      _checkGeneration(generation);
      return data;
    } on http.ClientException {
      throw const HttpException(
        'Музыкальная база недоступна. Локальная медиатека продолжает работать.',
      );
    }
  }

  /// Bounded spelling hints, never an automatic artist identity match. The
  /// caller must still compare edit distance and expose any changed query.
  Future<List<String>> suggestArtistNames(
    String query, {
    SourceOperation? operation,
  }) async {
    operation?.check();
    final word = normalizeMusicName(query);
    if (!RegExp(r'^[\p{L}\p{N}]{5,64}$', unicode: true).hasMatch(word)) {
      return const [];
    }
    final result = await _api('artist', {
      'query': 'artist:$word~1',
      'limit': '8',
    }, operation: operation);
    operation?.check();
    return List<String>.unmodifiable(
      (result['artists'] as List? ?? [])
          .whereType<Map>()
          .map((artist) => artist['name'])
          .whereType<String>()
          .where((name) => name.trim().isNotEmpty)
          .toSet(),
    );
  }

  Future<MusicArtist?> artist(String name, {SourceOperation? operation}) async {
    final generation = cache.generation;
    final phrase = musicSearchPhrase(name);
    final result = await _api(
      'artist',
      {
        'query': 'artist:"$phrase" OR alias:"$phrase" OR sortname:"$phrase"',
        'limit': '8',
      },
      operation: operation,
      expectedGeneration: generation,
    );
    _checkGeneration(generation);
    final candidates = (result['artists'] as List? ?? []).whereType<Map>();
    final candidate = candidates.where((item) {
      final names = [
        item['name'],
        item['sort-name'],
        ...(item['aliases'] as List? ?? []).whereType<Map>().map(
          (a) => a['name'],
        ),
      ];
      return names.whereType<String>().any(
        (n) => normalizeMusicName(n) == normalizeMusicName(name),
      );
    }).firstOrNull;
    // Do not silently attach a different similarly named band.
    if (candidate == null) return null;
    final id = candidate['id'] as String;
    final details = await _api(
      'artist/$id',
      {'inc': 'aliases'},
      operation: operation,
      expectedGeneration: generation,
    );
    final albums = await _api(
      'release-group',
      {'artist': id, 'limit': '100', 'inc': 'artist-credits'},
      operation: operation,
      expectedGeneration: generation,
    );
    final recordings = await _api(
      'recording',
      {'artist': id, 'limit': '25', 'inc': 'artist-credits'},
      operation: operation,
      expectedGeneration: generation,
    );
    _checkGeneration(generation);
    return MusicArtist(
      id: id,
      name: details['name'] as String,
      type: details['type'] as String? ?? '',
      country: details['country'] as String? ?? '',
      disambiguation: details['disambiguation'] as String? ?? '',
      aliases: List.unmodifiable([
        if (details['sort-name'] is String) details['sort-name'] as String,
        ...(details['aliases'] as List? ?? [])
            .whereType<Map>()
            .map((a) => a['name'])
            .whereType<String>(),
      ]),
      albums: List.unmodifiable(
        (albums['release-groups'] as List? ?? [])
            .whereType<Map>()
            .map((j) => _group(j, details['name'] as String))
            .toList()
          ..sort((a, b) => b.year.compareTo(a.year)),
      ),
      recordings: List.unmodifiable(
        (recordings['recordings'] as List? ?? []).whereType<Map>().map(
          (j) => _recording(
            j,
            fallbackArtist: details['name'] as String,
            fallbackId: id,
          ),
        ),
      ),
    );
  }

  Future<List<MusicRecording>> searchRecordings(
    String query, {
    SourceOperation? operation,
  }) async {
    final generation = cache.generation;
    final phrase = musicSearchPhrase(query);
    if (phrase.isEmpty) return [];
    var result = await _api(
      'recording',
      {'query': phrase, 'limit': '25'},
      operation: operation,
      expectedGeneration: generation,
    );
    _checkGeneration(generation);
    if ((result['recordings'] as List? ?? []).isEmpty) {
      result = await _api(
        'recording',
        {'query': 'recording:"$phrase"', 'limit': '25'},
        operation: operation,
        expectedGeneration: generation,
      );
    }
    _checkGeneration(generation);
    final seen = <String>{};
    return (result['recordings'] as List? ?? [])
        .whereType<Map>()
        .where((j) => (int.tryParse('${j['score']}') ?? 100) >= 70)
        .map((j) => _recording(j))
        .where((r) => seen.add(r.id))
        .toList();
  }

  Future<MusicRecording> recordingWithAlbums(
    MusicRecording recording, {
    SourceOperation? operation,
  }) async {
    final generation = cache.generation;
    if (recording.albumTitles.isNotEmpty) return recording;
    final data = await _api(
      'recording/${recording.id}',
      {'inc': 'artists+releases'},
      operation: operation,
      expectedGeneration: generation,
    );
    _checkGeneration(generation);
    return _recording(
      data,
      fallbackArtist: recording.artist,
      fallbackId: recording.artistId,
    );
  }

  static String _credit(Map j) {
    final credits = (j['artist-credit'] as List? ?? []).whereType<Map>();
    return credits
        .map(
          (a) =>
              '${a['name'] ?? (a['artist'] as Map?)?['name'] ?? ''}${a['joinphrase'] ?? ''}',
        )
        .join();
  }

  static MusicReleaseGroup _group(Map j, String fallback) => MusicReleaseGroup(
    id: j['id'] as String,
    title: j['title'] as String,
    artist: _credit(j).isEmpty ? fallback : _credit(j),
    year: (j['first-release-date'] as String? ?? '').split('-').first,
    type: j['primary-type'] as String? ?? '',
  );

  static MusicRecording _recording(
    Map j, {
    String fallbackArtist = '',
    String? fallbackId,
  }) {
    final credits = (j['artist-credit'] as List? ?? []).whereType<Map>();
    return MusicRecording(
      id: j['id'] as String,
      title: j['title'] as String,
      artist: _credit(j).isEmpty ? fallbackArtist : _credit(j),
      artistId:
          (credits.firstOrNull?['artist'] as Map?)?['id'] as String? ??
          fallbackId,
      primaryArtist:
          (credits.firstOrNull?['artist'] as Map?)?['name'] as String? ??
          fallbackArtist,
      durationMs: (j['length'] as num?)?.toInt() ?? 0,
      disambiguation: j['disambiguation'] as String? ?? '',
      albumTitles: List.unmodifiable(
        (j['releases'] as List? ?? [])
            .whereType<Map>()
            .map((r) => r['title'])
            .whereType<String>()
            .toSet(),
      ),
    );
  }

  Future<String?> coverForReleaseTitle(String title) {
    final identity = parseReleaseIdentity(title);
    if (identity == null) return Future.value(null);
    return coverForAlbum(identity.artist, identity.album);
  }

  /// Resolve only persisted artwork. This never schedules HTTP or promotes
  /// FIFO entries, so a ready cover can be shown before optional torrent work.
  Future<String?> cachedCoverForAlbum(
    String artistName,
    String albumTitle,
  ) async {
    final generation = cache.generation;
    try {
      _checkGeneration(generation);
      if (artistName.trim().isEmpty || albumTitle.trim().isEmpty) return null;
      final fallback = await _artworkFallback.cachedCover(
        artistName,
        albumTitle,
      );
      _checkGeneration(generation);
      if (fallback != null) return fallback;
      final artist = musicSearchPhrase(artistName);
      final album = musicSearchPhrase(albumTitle);
      final uri = Uri.https('musicbrainz.org', '/ws/2/release-group', {
        'fmt': 'json',
        'query': 'artist:"$artist" AND releasegroup:"$album"',
        'limit': '5',
      });
      final saved = await cache.read('mb:$uri');
      _checkGeneration(generation);
      if (saved == null) return null;
      final data = jsonDecode(utf8.decode(saved)) as Map;
      final id = (data['release-groups'] as List? ?? [])
          .whereType<Map>()
          .where(
            (item) =>
                normalizeMusicName(item['title'] as String? ?? '') ==
                    normalizeMusicName(albumTitle) &&
                normalizeMusicName(_credit(item)) ==
                    normalizeMusicName(artistName),
          )
          .map((item) => item['id'])
          .whereType<String>()
          .firstOrNull;
      if (id == null) return null;
      final cover = await cache.pathFor('cover:$id');
      _checkGeneration(generation);
      return cover;
    } catch (_) {
      // Optional artwork must not turn a missing or corrupt cache into an
      // error, and invalidated work must not trigger a replacement request.
      return null;
    }
  }

  /// Album tags and torrent folders already provide separate identity fields.
  /// Do not strip meaningful parentheses or dashes as a release-title parser
  /// would; exact normalized artist/title matching remains required.
  Future<String?> coverForAlbum(
    String artistName,
    String albumTitle,
  ) => _coverJob(
    'album:${normalizeMusicName(artistName)}:${normalizeMusicName(albumTitle)}',
    (generation) async {
      if (artistName.trim().isEmpty || albumTitle.trim().isEmpty) return null;
      final savedFallback = await cachedCoverForAlbum(artistName, albumTitle);
      _checkGeneration(generation);
      if (savedFallback != null) return savedFallback;
      // A missing MB release, missing CAA image, or unavailable metadata service
      // must not prevent another public catalogue from providing the cover.
      try {
        final artist = musicSearchPhrase(artistName),
            album = musicSearchPhrase(albumTitle);
        final data = await _api(
          'release-group',
          {'query': 'artist:"$artist" AND releasegroup:"$album"', 'limit': '5'},
          lowPriority: true,
          expectedGeneration: generation,
        );
        _checkGeneration(generation);
        final match = (data['release-groups'] as List? ?? [])
            .whereType<Map>()
            .where(
              (j) =>
                  normalizeMusicName(j['title'] as String? ?? '') ==
                      normalizeMusicName(albumTitle) &&
                  normalizeMusicName(_credit(j)) ==
                      normalizeMusicName(artistName),
            )
            .firstOrNull;
        if (match != null) {
          final cover = await coverForGroup(match['id'] as String);
          if (cover != null) return cover;
        }
      } on SourceCancelled {
        rethrow;
      } catch (_) {
        _checkGeneration(generation);
      }
      return _artworkFallback.cover(artistName, albumTitle, generation);
    },
  );

  Future<String?> coverForGroup(String id) =>
      _coverJob('group:$id', (generation) => _cover(id, generation));

  Future<String?> _coverJob(String key, Future<String?> Function(int) action) {
    // Only coalesce in flight. Disk cache remains the authority after eviction
    // and clearing; a Future must not keep returning a removed file path.
    final generation = cache.generation;
    final pendingKey = '$generation:$key';
    return _covers.putIfAbsent(
      pendingKey,
      () =>
          (() async {
            _checkGeneration(generation);
            final result = await action(generation);
            _checkGeneration(generation);
            return result;
          })().catchError((Object _) => null).whenComplete(() {
            _covers.remove(pendingKey);
          }),
    );
  }

  Future<String?> _cover(String id, int generation) async {
    if (!RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(id)) return null;
    final key = 'cover:$id';
    _checkGeneration(generation);
    final saved = await cache.pathFor(key);
    _checkGeneration(generation);
    if (saved != null) return saved;
    if (await cache.read('no-cover:$id') != null) return null;
    var notFound = false;
    for (final size in ['250', '500']) {
      var uri = Uri.https(
        'coverartarchive.org',
        '/release-group/$id/front-$size',
      );
      for (var hop = 0; hop < 5; hop++) {
        _checkGeneration(generation);
        if (_disposed) return null;
        final response = await client
            .send(
              http.Request('GET', uri)
                ..headers['User-Agent'] = _agent
                ..followRedirects = false,
            )
            .timeout(requestTimeout);
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers['location'];
          // Closing the subscription avoids draining an unbounded error body.
          await response.stream.listen((_) {}).cancel();
          if (location == null) return null;
          uri = uri.resolve(location);
          if (uri.scheme == 'http') uri = uri.replace(scheme: 'https');
          if (uri.scheme != 'https' ||
              !(uri.host == 'coverartarchive.org' ||
                  uri.host == 'archive.org' ||
                  uri.host.endsWith('.archive.org'))) {
            return null;
          }
          continue;
        }
        if (response.statusCode != 200) {
          await response.stream.listen((_) {}).cancel();
          if (response.statusCode == 404) {
            notFound = true;
          }
          break;
        }
        if (!(response.headers['content-type'] ?? '').startsWith('image/')) {
          await response.stream.listen((_) {}).cancel();
          return null;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream.timeout(requestTimeout)) {
          bytes.add(chunk);
          if (bytes.length > 5 * 1024 * 1024) {
            throw const FormatException('Обложка слишком большая.');
          }
        }
        final data = bytes.takeBytes();
        if (data.isEmpty) return null;
        return cache.put(
          key,
          data,
          extension: 'image',
          ttl: const Duration(days: 30),
          expectedGeneration: generation,
        );
      }
    }
    if (notFound) {
      await cache.put(
        'no-cover:$id',
        Uint8List.fromList([0]),
        ttl: const Duration(hours: 24),
        expectedGeneration: generation,
      );
    }
    return null;
  }

  void dispose() {
    _disposed = true;
    _artworkFallback.dispose();
    client.close();
    for (final request in _requests) {
      request.result.completeError(StateError('Музыкальный каталог закрыт.'));
    }
    _requests.clear();
  }
}

class _MetadataRequest {
  _MetadataRequest(this.uri, this.lowPriority, this.operation, this.generation);
  final Uri uri;
  final bool lowPriority;
  final SourceOperation? operation;
  final int generation;
  final result = Completer<http.Response>();
}
