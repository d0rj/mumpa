import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/music_metadata.dart';
import 'media_cache.dart';
import 'source_operation.dart';

/// Public album metadata and small covers only; never requests audio/previews.
class DeezerArtworkRepository {
  DeezerArtworkRepository({
    required this.cache,
    required this.client,
    this.timeout = const Duration(seconds: 12),
  });

  final DiskMediaCache cache;
  final http.Client client;
  final Duration timeout;
  final Map<String, Future<List<Map>>> _catalogs = {};
  final List<Completer<void>> _waiting = [];
  final Set<SourceOperation> _active = {};
  int _running = 0;
  bool _disposed = false;

  void _check(int generation) {
    if (_disposed || cache.generation != generation) {
      throw const SourceCancelled();
    }
  }

  Future<T> _bounded<T>(int generation, Future<T> Function() job) async {
    _check(generation);
    if (_running >= 2) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      _check(generation);
      return await job();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _running--;
      }
    }
  }

  Future<Map> _json(Uri uri, int generation) async {
    final key = 'deezer:$uri';
    final saved = await cache.read(key);
    _check(generation);
    if (saved != null) {
      try {
        return jsonDecode(utf8.decode(saved)) as Map;
      } catch (_) {
        await cache.remove(key);
      }
    }
    return _bounded(generation, () async {
      final bytes = await _receive(uri, generation, image: false);
      final data = jsonDecode(utf8.decode(bytes)) as Map;
      if (data['error'] != null) throw const FormatException('Deezer error');
      await cache.put(
        key,
        bytes,
        extension: 'json',
        ttl: const Duration(days: 7),
        expectedGeneration: generation,
      );
      _check(generation);
      return data;
    });
  }

  Future<List<Map>> _albums(String artist, int generation) {
    final pendingKey = '$generation:${normalizeMusicName(artist)}';
    return _catalogs.putIfAbsent(
      pendingKey,
      () =>
          (() async {
            final data = await _json(
              Uri.https('api.deezer.com', '/search/artist', {
                'q': artist.trim(),
                'limit': '8',
              }),
              generation,
            );
            final matches = (data['data'] as List? ?? [])
                .whereType<Map>()
                .where(
                  (item) =>
                      normalizeMusicName(item['name'] as String? ?? '') ==
                      normalizeMusicName(artist),
                );
            final albums = <Map>[];
            // Same-name artists remain separate. Only scoped album lists are used.
            for (final match in matches.take(2)) {
              final id = match['id'];
              if (id is! int || id <= 0) continue;
              for (var index = 0; index < 200; index += 100) {
                final page = await _json(
                  Uri.https('api.deezer.com', '/artist/$id/albums', {
                    'limit': '100',
                    'index': '$index',
                  }),
                  generation,
                );
                final items = (page['data'] as List? ?? [])
                    .whereType<Map>()
                    .toList();
                albums.addAll(items);
                if (items.length < 100 || page['next'] == null) break;
              }
            }
            return albums;
          })().whenComplete(() {
            _catalogs.remove(pendingKey);
          }),
    );
  }

  Future<String?> cover(String artist, String title, int generation) async {
    final identity =
        '${normalizeMusicName(artist)}:${artworkAlbumIdentity(title)}';
    final key = 'deezer-cover:$identity';
    final saved = await cache.pathFor(key);
    _check(generation);
    if (saved != null) return saved;
    if (await cache.read('deezer-no-cover:$identity') != null) return null;
    final albums = await _albums(artist, generation);
    _check(generation);
    final matching = albums
        .where(
          (item) =>
              artworkAlbumIdentity(item['title'] as String? ?? '') ==
              artworkAlbumIdentity(title),
        )
        .toList();
    for (final item in matching) {
      final uri = Uri.tryParse(item['cover_medium'] as String? ?? '');
      if (uri == null || !_imageHost(uri)) continue;
      try {
        final bytes = await _bounded(
          generation,
          () => _receive(uri, generation, image: true),
        );
        return cache.put(
          key,
          bytes,
          extension: 'image',
          ttl: const Duration(days: 30),
          expectedGeneration: generation,
        );
      } on SourceCancelled {
        rethrow;
      } catch (_) {
        // A broken edition image must not hide a second valid album cover.
        _check(generation);
      }
    }
    if (matching.isNotEmpty) return null;
    await cache.put(
      'deezer-no-cover:$identity',
      Uint8List.fromList([0]),
      ttl: const Duration(hours: 24),
      expectedGeneration: generation,
    );
    return null;
  }

  Future<String?> cachedCover(String artist, String title) => cache.pathFor(
    'deezer-cover:${normalizeMusicName(artist)}:${artworkAlbumIdentity(title)}',
  );

  bool _imageHost(Uri uri) =>
      uri.scheme == 'https' &&
      (uri.host == 'dzcdn.net' || uri.host.endsWith('.dzcdn.net')) &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443);

  Future<Uint8List> _receive(
    Uri uri,
    int generation, {
    required bool image,
  }) async {
    final operation = SourceOperation();
    _active.add(operation);
    final deadline = Timer(timeout, operation.cancel);
    try {
      for (var hop = 0; hop < 4; hop++) {
        _check(generation);
        final response = await operation.wait(
          client.send(
            http.AbortableRequest(
                'GET',
                uri,
                abortTrigger: operation.whenCancelled,
              )
              ..headers['User-Agent'] =
                  'Mumpa/1.2.2 (https://github.com/d0rj/mumpa)'
              ..followRedirects = false,
          ),
        );
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers['location'];
          await response.stream.listen((_) {}).cancel();
          if (location == null) throw const FormatException('Missing redirect');
          uri = uri.resolve(location);
          if (!image || !_imageHost(uri)) {
            throw const FormatException('Unexpected artwork redirect');
          }
          continue;
        }
        if (response.statusCode != 200 ||
            (image &&
                !(response.headers['content-type'] ?? '').startsWith(
                  'image/',
                ))) {
          await response.stream.listen((_) {}).cancel();
          throw const FormatException('Artwork unavailable');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream.timeout(timeout)) {
          operation.check();
          _check(generation);
          bytes.add(chunk);
          if (bytes.length > (image ? 5 : 2) * 1024 * 1024) {
            operation.cancel();
            throw const FormatException('Artwork response too large');
          }
        }
        _check(generation);
        if (bytes.isEmpty) {
          throw const FormatException('Empty artwork response');
        }
        return bytes.takeBytes();
      }
      throw const FormatException('Too many artwork redirects');
    } finally {
      deadline.cancel();
      operation.cancel();
      _active.remove(operation);
    }
  }

  void dispose() {
    _disposed = true;
    for (final operation in _active) {
      operation.cancel();
    }
  }
}

/// Ignore only catalogue type/featuring suffixes. Live/Deluxe/Remaster stay.
String artworkAlbumIdentity(String value) => normalizeMusicName(
  value
      .replaceAll(
        RegExp(r'\s*[\[(]feat\.?\s+[^\])]+[\])]', caseSensitive: false),
        '',
      )
      .replaceFirst(
        RegExp(
          r'\s*(?:-\s*|[\[(])(?:EP|ЕР|LP|Single|Сингл)[\])]?\s*$',
          caseSensitive: false,
        ),
        '',
      ),
);
