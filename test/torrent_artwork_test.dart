import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/torrent_artwork_repository.dart';
import 'package:mumpa/data/torrent_metainfo.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';

final _image = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6ZQAAAABJRU5ErkJggg==',
);

List<int> _encode(Object value) {
  if (value is int) return ascii.encode('i${value}e');
  if (value is String) return _encode(Uint8List.fromList(utf8.encode(value)));
  if (value is Uint8List) {
    return [...ascii.encode('${value.length}:'), ...value];
  }
  if (value is List) {
    return [108, ...value.expand((item) => _encode(item as Object)), 101];
  }
  final map = value as Map<String, Object>, keys = map.keys.toList()..sort();
  return [
    100,
    for (final key in keys) ...[..._encode(key), ..._encode(map[key]!)],
    101,
  ];
}

Uint8List _metainfo(
  List<(String, int)> paths, {
  String title = 'Band - Discography',
}) => Uint8List.fromList(
  _encode({
    'info': <String, Object>{
      'name': title,
      'piece length': 16384,
      'pieces': Uint8List(20),
      'files': [
        for (final (path, bytes) in paths)
          <String, Object>{'length': bytes, 'path': path.split('/')},
      ],
    },
  }),
);

Map<String, Object> _state(TorrentInfo info) => {
  'hash': info.hash,
  'title': info.title,
  'file_stats': [
    for (final file in info.files)
      {'id': file.index, 'path': file.path, 'length': file.bytes},
  ],
};

http.StreamedResponse _json(Object value, [int code = 200]) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(value))),
      code,
      headers: {'content-type': 'application/json'},
    );
http.StreamedResponse _picture([List<int>? bytes]) => http.StreamedResponse(
  Stream.value(bytes ?? _image),
  206,
  contentLength: (bytes ?? _image).length,
  headers: {'content-type': 'image/png'},
);

class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() {
    closed = true;
  }
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Expected artwork request did not arrive.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory root, sources;
  late DiskMediaCache cache;
  late TorrentService torrents;
  late TorrentArtworkRepository artwork;
  late TorrentInfo info;
  var endpointCalls = 0;

  Future<void> save(
    List<(String, int)> paths, {
    String title = 'Band - Discography',
  }) async {
    final bytes = _metainfo(paths, title: title);
    info = readTorrentMetainfo(bytes);
    await File(
      '${sources.path}/${stableId(info.hash)}.torrent',
    ).writeAsBytes(bytes);
  }

  List<Track> tracks() => torrents.tracks(info, artist: 'Band');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-torrent-artwork-');
    sources = await Directory('${root.path}/sources').create();
    cache = DiskMediaCache(Directory('${root.path}/cache'));
    endpointCalls = 0;
    torrents = TorrentService(
      sources: sources,
      endpoint: () async {
        endpointCalls++;
        return 'http://127.0.0.1:54321';
      },
    );
    artwork = TorrentArtworkRepository(torrents: torrents, cache: cache);
  });
  tearDown(() async {
    artwork.dispose();
    torrents.dispose();
    await root.delete(recursive: true);
  });

  test(
    'selection respects physical album, codec and CD wrappers; flat mixed is ambiguous',
    () async {
      await save([
        ('Albums/2001 - One/CD1/FLAC/01.flac', 100),
        ('Albums/2001 - One/CD2/FLAC/02.flac', 100),
        ('Albums/2001 - One/cover.jpg', _image.length),
        ('Albums/2001 - One/CD1/front.png', _image.length),
        ('Live/2001 - One/cover.jpg', _image.length),
        ('Live/2001 - One/03.flac', 100),
        ('2002 - Two/cover.jpg', _image.length),
        ('2002 - Two/01.flac', 100),
      ]);
      final audio = tracks();
      expect(selectTorrentArtwork(info, audio[0])?.index, 3);
      expect(selectTorrentArtwork(info, audio[1])?.index, 3);
      expect(selectTorrentArtwork(info, audio[2])?.index, 5);
      expect(selectTorrentArtwork(info, audio[3])?.index, 7);
      expect(
        selectTorrentArtwork(
          info,
          Track(
            id: audio[0].id,
            title: audio[0].title,
            artist: audio[0].artist,
            album: audio[0].album,
            source: TrackSource.torrent,
            torrentHash: audio[0].torrentHash,
            torrentPath: audio[0].torrentPath,
            torrentIndex: 5,
          ),
        )?.index,
        3,
      );

      await save([
        ('01.mp3', 100),
        ('02.mp3', 100),
        ('cover.jpg', _image.length),
      ], title: 'VA - Trackography');
      expect(selectTorrentArtwork(info, tracks().first), isNull);
      await save([
        ('FLAC/CD1/01.flac', 100),
        ('cover.jpg', _image.length),
      ], title: 'Band - Album, 2001, FLAC');
      expect(selectTorrentArtwork(info, tracks().first)?.index, 2);
    },
  );

  test(
    'ambiguous disc images and oversized files never start the engine',
    () async {
      await save([
        ('2001 - One/CD1/01.mp3', 100),
        ('2001 - One/CD2/02.mp3', 100),
        ('2001 - One/CD1/cover.jpg', _image.length),
        ('2001 - One/CD2/cover.jpg', _image.length),
        ('2001 - One/cover.png', 5 * 1024 * 1024 + 1),
      ]);
      expect(await artwork.load(tracks().first), isNull);
      expect(endpointCalls, 0);
      await save([
        ('2001 - One/01.mp3', 100),
        ('2002 - Two/cover.jpg', _image.length),
      ]);
      expect(await artwork.load(tracks().first), isNull);
      expect(endpointCalls, 0);
    },
  );

  test(
    'artwork selection uses the exact audio path despite stale sorted IDs',
    () async {
      await save([
        ('2001 - One/01.mp3', 100),
        ('2001 - One/cover.png', _image.length),
        ('2002 - Two/01.mp3', 100),
        ('2002 - Two/cover.png', _image.length),
      ]);
      final audio = tracks().first;
      Track withPath(String path, {String? hash}) => Track(
        id: audio.id,
        title: audio.title,
        artist: audio.artist,
        album: audio.album,
        source: TrackSource.torrent,
        torrentHash: hash ?? audio.torrentHash,
        torrentPath: path,
        torrentIndex: 3,
      );
      expect(
        selectTorrentArtwork(info, withPath(audio.torrentPath!))?.index,
        2,
      );
      expect(
        selectTorrentArtwork(
          info,
          withPath('${info.title}/2001 - One/missing.mp3'),
        ),
        isNull,
      );
      expect(
        selectTorrentArtwork(info, withPath(audio.torrentPath!, hash: 'other')),
        isNull,
      );
    },
  );

  test(
    'disk-only cover lookup survives restart and never starts the engine',
    () async {
      await save([
        ('2001 - One/01.mp3', 100),
        ('2001 - One/02.mp3', 100),
        ('2001 - One/cover.jpg', _image.length),
        ('2002 - Two/01.mp3', 100),
        ('2002 - Two/cover.jpg', _image.length),
      ]);
      final saved = await cache.put(
        'torrent-cover:${info.hash}:3',
        _image,
        extension: 'png',
      );
      artwork.dispose();
      torrents.dispose();
      torrents = TorrentService(
        sources: sources,
        endpoint: () async {
          endpointCalls++;
          throw StateError('Offline lookup must not resolve an endpoint.');
        },
      );
      final restartedCache = DiskMediaCache(cache.root);
      artwork = TorrentArtworkRepository(
        torrents: torrents,
        cache: restartedCache,
        clientFactory: () =>
            throw StateError('Offline lookup created a client.'),
      );
      final audio = tracks();
      expect(await artwork.cachedCover(audio[0]), saved);
      expect(await artwork.cachedCover(audio[1]), saved);
      expect(await artwork.cachedCover(audio[2]), isNull);
      expect(endpointCalls, 0);
      await restartedCache.clear();
      expect(await artwork.cachedCover(audio[0]), isNull);
      expect(endpointCalls, 0);
      artwork.dispose();
      expect(await artwork.cachedCover(audio[0]), isNull);
    },
  );

  test(
    'fetches only the cover index, coalesces siblings and respects cache eviction',
    () async {
      await save([
        ('2001 - One/01.mp3', 100),
        ('2001 - One/02.mp3', 100),
        ('2001 - One/cover.jpg', _image.length),
      ]);
      final clients = <_Client>[], indexes = <String>[];
      artwork = TorrentArtworkRepository(
        torrents: torrents,
        cache: cache,
        clientFactory: () {
          final client = _Client((request) async {
            if (request.url.path == '/torrents') return _json(_state(info));
            expect(request, isA<http.AbortableRequest>());
            expect(request.url.path, '/stream');
            expect(request.headers['Range'], 'bytes=0-${_image.length - 1}');
            indexes.add(request.url.queryParameters['index']!);
            return _picture();
          });
          clients.add(client);
          return client;
        },
      );
      final audio = tracks();
      final paths = await Future.wait([
        artwork.load(audio[0]),
        artwork.load(audio[1]),
      ]);
      expect(paths[0], isNotNull);
      expect(paths[1], paths[0]);
      expect(indexes, ['3']);
      expect(clients, hasLength(1));
      expect(clients.single.closed, isTrue);
      expect(await File(paths[0]!).readAsBytes(), _image);
      final previousCalls = endpointCalls;
      expect(await artwork.load(audio[0]), paths[0]);
      expect(endpointCalls, previousCalls);
      await cache.clear();
      expect(await File(paths[0]!).exists(), isFalse);
      expect(await artwork.load(audio[1]), isNotNull);
      expect(indexes, ['3', '3']);
      expect(clients.every((client) => client.closed), isTrue);
    },
  );

  test(
    'streams the engine sorted cover ID and keeps the metainfo cache identity',
    () async {
      await save([
        ('2001 - One/cover.png', _image.length),
        ('2001 - One/01.mp3', 100),
      ]);
      final expectedCover = info.files.first;
      final indexes = <String>[];
      artwork = TorrentArtworkRepository(
        torrents: torrents,
        cache: cache,
        clientFactory: () => _Client((request) async {
          if (request.url.path == '/torrents') {
            return _json({
              'hash': info.hash,
              'title': info.title,
              'file_stats': [
                {'id': 1, 'path': info.files[1].path, 'length': 100},
                {
                  'id': 2,
                  'path': expectedCover.path,
                  'length': expectedCover.bytes,
                },
              ],
            });
          }
          indexes.add(request.url.queryParameters['index']!);
          return _picture();
        }),
      );
      final track = tracks().single;
      final saved = await artwork.load(track);
      expect(saved, isNotNull);
      expect(indexes, ['2']);
      expect(await cache.pathFor('torrent-cover:${info.hash}:1'), saved);
      expect(await cache.pathFor('torrent-cover:${info.hash}:2'), isNull);
      expect(await artwork.cachedCover(track), saved);
    },
  );

  test(
    'rejects ambiguous or mismatched engine paths without opening a stream',
    () async {
      await save([
        ('2001 - One/01.mp3', 100),
        ('2001 - One/cover.png', _image.length),
      ]);
      var mode = 0, streams = 0;
      final cover = info.files[1];
      artwork = TorrentArtworkRepository(
        torrents: torrents,
        cache: cache,
        clientFactory: () => _Client((request) async {
          if (request.url.path != '/torrents') {
            streams++;
            return _picture();
          }
          return _json({
            'hash': info.hash,
            'title': info.title,
            'file_stats': [
              {'id': 1, 'path': info.files.first.path, 'length': 100},
              {
                'id': 2,
                'path': mode == 0
                    ? '${info.title}/2002 - Two/cover.png'
                    : cover.path,
                'length': mode == 1 ? cover.bytes + 1 : cover.bytes,
              },
              if (mode == 2)
                {'id': 3, 'path': cover.path, 'length': cover.bytes},
            ],
          });
        }),
      );
      for (mode = 0; mode < 3; mode++) {
        expect(await artwork.load(tracks().first), isNull);
      }
      expect(streams, 0);
      expect((await cache.stats()).count, 0);
    },
  );

  test(
    'restores missing native metadata from the saved metainfo before cover streaming',
    () async {
      await save([
        ('2001 - One/01.mp3', 100),
        ('2001 - One/folder.png', _image.length),
      ]);
      var uploaded = false;
      final requests = <String>[];
      artwork = TorrentArtworkRepository(
        torrents: torrents,
        cache: cache,
        clientFactory: () => _Client((request) async {
          if (request.url.path == '/torrents') {
            requests.add('get');
            return uploaded
                ? _json(_state(info))
                : _json({'error': 'not loaded'}, 404);
          }
          if (request.url.path == '/torrent/upload') {
            requests.add('upload');
            expect(request, isA<http.MultipartRequest>());
            final multipart = request as http.MultipartRequest;
            expect(
              multipart.files.single.filename,
              '${stableId(info.hash)}.torrent',
            );
            expect(multipart.fields['save'], 'true');
            uploaded = true;
            return _json([
              {'hash': info.hash},
            ]);
          }
          requests.add('stream');
          expect(request.url.queryParameters['index'], '2');
          return _picture();
        }),
      );
      expect(await artwork.load(tracks().first), isNotNull);
      expect(requests, ['get', 'upload', 'get', 'stream']);
    },
  );

  test(
    'at most two covers transfer concurrently and cancel also completes queued jobs',
    () async {
      await save([
        for (var i = 1; i <= 4; i++) ...[
          ('200$i - Album $i/01.mp3', 100),
          ('200$i - Album $i/cover.png', _image.length),
        ],
      ]);
      final clients = <_Client>[], bodies = <StreamController<List<int>>>[];
      artwork = TorrentArtworkRepository(
        torrents: torrents,
        cache: cache,
        clientFactory: () {
          final client = _Client((request) async {
            if (request.url.path == '/torrents') return _json(_state(info));
            final body = StreamController<List<int>>();
            bodies.add(body);
            return http.StreamedResponse(
              body.stream,
              206,
              contentLength: _image.length,
            );
          });
          clients.add(client);
          return client;
        },
      );
      final loading = Future.wait(tracks().map(artwork.load));
      await _until(() => bodies.length == 2);
      expect(clients, hasLength(2));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(bodies, hasLength(2));
      bodies[0].add(_image);
      await bodies[0].close();
      await _until(() => bodies.length == 3);
      artwork.cancelPending();
      final paths = await loading.timeout(const Duration(seconds: 2));
      expect(paths.whereType<String>(), hasLength(1));
      expect(paths.where((path) => path == null), hasLength(3));
      expect(clients, hasLength(3));
      expect(clients.every((client) => client.closed), isTrue);
      for (final body in bodies.skip(1)) {
        await body.close();
      }
    },
  );

  test(
    'peerless cover timeout aborts request and closes its dedicated client',
    () async {
      await save([
        ('2001 - One/01.mp3', 100),
        ('2001 - One/cover.png', _image.length),
      ]);
      final body = StreamController<List<int>>(), aborted = Completer<void>();
      late _Client client;
      artwork = TorrentArtworkRepository(
        torrents: torrents,
        cache: cache,
        requestTimeout: const Duration(milliseconds: 80),
        clientFactory: () {
          client = _Client((request) async {
            if (request.url.path == '/torrents') return _json(_state(info));
            final imageRequest = request as http.AbortableRequest;
            unawaited(
              imageRequest.abortTrigger!.then((_) => aborted.complete()),
            );
            return http.StreamedResponse(
              body.stream,
              206,
              contentLength: _image.length,
            );
          });
          return client;
        },
      );
      expect(
        await artwork.load(tracks().first).timeout(const Duration(seconds: 2)),
        isNull,
      );
      await aborted.future.timeout(const Duration(seconds: 2));
      expect(client.closed, isTrue);
      expect((await cache.stats()).count, 0);
      await body.close();
    },
  );

  test(
    'cache clear aborts stalled body and old generation cannot repopulate images',
    () async {
      await save([
        ('2001 - One/01.mp3', 100),
        ('2001 - One/cover.png', _image.length),
      ]);
      final body = StreamController<List<int>>(),
          arrived = Completer<void>(),
          aborted = Completer<void>();
      var fresh = false;
      final clients = <_Client>[];
      artwork = TorrentArtworkRepository(
        torrents: torrents,
        cache: cache,
        clientFactory: () {
          final client = _Client((request) async {
            if (request.url.path == '/torrents') return _json(_state(info));
            if (fresh) return _picture();
            unawaited(
              (request as http.AbortableRequest).abortTrigger!.then(
                (_) => aborted.complete(),
              ),
            );
            arrived.complete();
            return http.StreamedResponse(
              body.stream,
              206,
              contentLength: _image.length,
            );
          });
          clients.add(client);
          return client;
        },
      );
      final waiting = artwork.load(tracks().first);
      await arrived.future;
      await cache.clear();
      expect(await waiting.timeout(const Duration(seconds: 2)), isNull);
      await aborted.future.timeout(const Duration(seconds: 2));
      body.add(_image);
      await body.close();
      expect((await cache.stats()).count, 0);
      expect(clients.single.closed, isTrue);
      fresh = true;
      expect(await artwork.load(tracks().first), isNotNull);
    },
  );

  test(
    'dispose cancels active and queued requests and prevents later native startup',
    () async {
      await save([
        for (var i = 1; i <= 3; i++) ...[
          ('200$i - Album $i/01.mp3', 100),
          ('200$i - Album $i/front.png', _image.length),
        ],
      ]);
      final clients = <_Client>[], bodies = <StreamController<List<int>>>[];
      artwork = TorrentArtworkRepository(
        torrents: torrents,
        cache: cache,
        clientFactory: () {
          final client = _Client((request) async {
            if (request.url.path == '/torrents') return _json(_state(info));
            final body = StreamController<List<int>>();
            bodies.add(body);
            return http.StreamedResponse(
              body.stream,
              206,
              contentLength: _image.length,
            );
          });
          clients.add(client);
          return client;
        },
      );
      final waiting = Future.wait(tracks().map(artwork.load));
      await _until(() => bodies.length == 2);
      artwork.dispose();
      expect(
        await waiting.timeout(const Duration(seconds: 2)),
        everyElement(isNull),
      );
      expect(clients, hasLength(2));
      expect(clients.every((client) => client.closed), isTrue);
      final calls = endpointCalls;
      expect(await artwork.load(tracks().first), isNull);
      expect(endpointCalls, calls);
      for (final body in bodies) {
        await body.close();
      }
    },
  );

  test(
    'rejects oversized headers, oversized streamed body and non-image payloads',
    () async {
      await save([
        ('2001 - One/01.mp3', 100),
        ('2001 - One/cover.png', _image.length),
      ]);
      var mode = 0;
      final clients = <_Client>[];
      artwork = TorrentArtworkRepository(
        torrents: torrents,
        cache: cache,
        clientFactory: () {
          final client = _Client((request) async {
            if (request.url.path == '/torrents') return _json(_state(info));
            if (mode == 0) {
              return http.StreamedResponse(
                const Stream.empty(),
                200,
                contentLength: 6 * 1024 * 1024,
              );
            }
            if (mode == 1) {
              return http.StreamedResponse(
                Stream.value(List.filled(_image.length + 1, 1)),
                200,
              );
            }
            return _picture(List.filled(_image.length, 60));
          });
          clients.add(client);
          return client;
        },
      );
      for (mode = 0; mode < 3; mode++) {
        expect(
          await artwork
              .load(tracks().first)
              .timeout(const Duration(seconds: 2)),
          isNull,
        );
      }
      expect((await cache.stats()).count, 0);
      expect(clients.every((client) => client.closed), isTrue);
    },
  );
}
