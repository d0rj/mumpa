import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/music_metadata.dart';
import 'bounded_http.dart';
import 'media_cache.dart';
import 'source_operation.dart';

/// Public catalogue fields only. No audio, previews, accounts or tracker data.
class DeezerCatalogRepository {
  DeezerCatalogRepository({
    required this.cache,
    required this.client,
    this.interval = const Duration(milliseconds: 350),
    this.timeout = const Duration(seconds: 10),
  });
  final DiskMediaCache cache;
  final http.Client client;
  final Duration interval, timeout;
  Future<void> _tail = Future.value();
  DateTime? _lastRequest;
  DateTime? _retryAfter;
  final Set<SourceOperation> _active = {};
  bool _disposed = false;

  Future<Map<String, dynamic>> _get(Uri uri, SourceOperation? caller) async {
    final generation = cache.generation;
    final operation = SourceOperation();
    final remove = caller?.onCancel(operation.cancel);
    _active.add(operation);
    void check() {
      caller?.check();
      operation.check();
      if (_disposed || generation != cache.generation) {
        throw const SourceCancelled();
      }
    }

    final key = 'deezer-catalog:v1:$uri';
    try {
      check();
      final cached = await cache.read(key);
      check();
      if (cached != null) {
        try {
          final data = jsonDecode(utf8.decode(cached)) as Map<String, dynamic>;
          if (data['error'] == null) return data;
        } catch (_) {
          /* Fetch again after a corrupt cache entry. */
        }
        await cache.remove(key);
      }
      final previous = _tail;
      final turn = Completer<void>();
      _tail = turn.future;
      try {
        await operation.wait(previous);
        check();
        final now = DateTime.now();
        if (_retryAfter?.isAfter(now) == true) {
          throw const HttpException(
            'Deezer временно ограничил запросы. Повтори позже.',
          );
        }
        final delay = _lastRequest == null
            ? Duration.zero
            : interval - now.difference(_lastRequest!);
        if (delay > Duration.zero) {
          await operation.wait(Future<void>.delayed(delay));
        }
        check();
        _lastRequest = DateTime.now();
        final response = await getBounded(
          client,
          uri,
          operation: operation,
          timeout: timeout,
          maxBytes: 1024 * 1024,
          headers: {
            'User-Agent': 'Mumpa/1.3.5 (https://github.com/d0rj/mumpa)',
            'Accept': 'application/json',
          },
        );
        check();
        if (response.statusCode == 429 || response.statusCode == 503) {
          final seconds = int.tryParse(response.headers['retry-after'] ?? '');
          DateTime? date;
          try {
            date = HttpDate.parse(response.headers['retry-after'] ?? '');
          } on HttpException {
            /* Numeric or absent header. */
          }
          _retryAfter = seconds != null
              ? DateTime.now().add(Duration(seconds: seconds.clamp(1, 86400)))
              : date ?? DateTime.now().add(const Duration(seconds: 30));
        }
        if (response.statusCode != 200) {
          throw HttpException('Deezer: HTTP ${response.statusCode}.');
        }
        final data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        if (data['error'] != null) {
          throw const HttpException('Deezer: каталог временно недоступен.');
        }
        if (data['data'] is! List && data['id'] is! num) {
          throw const FormatException('Некорректный ответ Deezer.');
        }
        await cache.put(
          key,
          response.bodyBytes,
          extension: 'json',
          ttl: const Duration(days: 7),
          expectedGeneration: generation,
        );
        check();
        return data;
      } finally {
        // A cancelled waiter must not let the next request overtake its predecessor.
        unawaited(
          previous.whenComplete(() {
            if (!turn.isCompleted) turn.complete();
          }),
        );
      }
    } finally {
      remove?.call();
      _active.remove(operation);
    }
  }

  Future<List<MusicRecording>> search(
    String query, {
    SourceOperation? operation,
  }) async {
    final phrase = musicSearchPhrase(query).trim();
    if (phrase.isEmpty) return const [];
    final data = await _get(
      Uri.https('api.deezer.com', '/search', {'q': phrase, 'limit': '25'}),
      operation,
    );
    final rows = data['data'];
    if (rows is! List) {
      throw const FormatException('Некорректный поиск Deezer.');
    }
    return List.unmodifiable(rows.whereType<Map>().map(parseRecording));
  }

  Future<MusicRecording> recording(
    String id, {
    SourceOperation? operation,
  }) async {
    if (!RegExp(r'^\d{1,20}$').hasMatch(id)) {
      throw const FormatException('Invalid Deezer ID');
    }
    return parseRecording(
      await _get(Uri.https('api.deezer.com', '/track/$id'), operation),
    );
  }

  Future<MusicArtist> artist(String id, {SourceOperation? operation}) async {
    if (!RegExp(r'^\d{1,20}$').hasMatch(id)) {
      throw const FormatException('Invalid Deezer ID');
    }
    final details = await _get(
      Uri.https('api.deezer.com', '/artist/$id'),
      operation,
    );
    final songs = await _get(
      Uri.https('api.deezer.com', '/artist/$id/top', {'limit': '25'}),
      operation,
    );
    return MusicArtist(
      id: id,
      name: details['name'] as String,
      provider: 'deezer',
      recordings: List.unmodifiable(
        (songs['data'] as List).whereType<Map>().map(parseRecording),
      ),
    );
  }

  static MusicRecording parseRecording(Map data) {
    final main = data['artist'] as Map?;
    final id = data['id'];
    final title = data['title'];
    if (id is! num ||
        main?['id'] is! num ||
        main?['name'] is! String ||
        title is! String) {
      throw const FormatException('Incomplete Deezer recording');
    }
    final credits = <CatalogArtist>[
      CatalogArtist(
        id: '${main!['id']}',
        name: main['name'] as String,
        provider: 'deezer',
      ),
      for (final item in (data['contributors'] as List? ?? []).whereType<Map>())
        if (item['id'] is num &&
            item['name'] is String &&
            item['id'] != main['id'])
          CatalogArtist(
            id: '${item['id']}',
            name: item['name'] as String,
            provider: 'deezer',
          ),
    ];
    final isrc = '${data['isrc'] ?? ''}'.toUpperCase();
    final album = (data['album'] as Map?)?['title'];
    return MusicRecording(
      id: '$id',
      title: title,
      provider: 'deezer',
      artist: credits.map((a) => a.name).join(' feat. '),
      primaryArtist: main['name'] as String,
      artistId: '${main['id']}',
      artistCredits: List.unmodifiable(credits),
      durationMs: ((data['duration'] as num?)?.toDouble() ?? 0).round() * 1000,
      albumTitles: List.unmodifiable([
        if (album is String && album.isNotEmpty) album,
      ]),
      disambiguation: data['title_version'] as String? ?? '',
      isrcs: List.unmodifiable([
        if (RegExp(r'^[A-Z]{2}[A-Z0-9]{3}\d{7}$').hasMatch(isrc)) isrc,
      ]),
      explicit: data['explicit_lyrics'] as bool?,
    );
  }

  void dispose() {
    _disposed = true;
    for (final operation in _active.toList()) {
      operation.cancel();
    }
  }
}
