import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/deezer_artwork_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_artwork_repository.dart';
import 'package:mumpa/data/torrent_metainfo.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/components.dart';

import 'support.dart';

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

class _ArtworkProbe extends AppController {
  _ArtworkProbe({
    required super.library,
    required super.playback,
    required super.downloads,
    required super.torrents,
    required super.engine,
    required super.metadata,
  });
  int artworkLoads = 0;
  @override
  Future<String?> loadTrackArtwork(Track track) async {
    artworkLoads++;
    return null;
  }
}

class _RaceMetadata extends MusicMetadataRepository {
  _RaceMetadata(DiskMediaCache cache)
    : super(
        cache: cache,
        client: MockClient((_) async => throw StateError('No HTTP.')),
      );

  final answer = Completer<String?>();
  final started = Completer<void>();
  final finished = Completer<void>();

  @override
  Future<String?> cachedCoverForAlbum(
    String artistName,
    String albumTitle,
  ) async => null;

  @override
  Future<String?> coverForAlbum(String artistName, String albumTitle) async {
    final generation = cache.generation;
    started.complete();
    try {
      final path = await answer.future;
      if (path != null) {
        await cache.put(
          'race-metadata',
          _image,
          expectedGeneration: generation,
        );
      }
      return path;
    } finally {
      finished.complete();
    }
  }
}

class _RaceTorrent extends TorrentArtworkRepository {
  _RaceTorrent({required super.torrents, required super.cache});

  final answer = Completer<String?>();
  final started = Completer<void>();
  final finished = Completer<void>();
  bool cancelled = false;

  @override
  Future<String?> cachedCover(Track track) async => null;

  @override
  Future<String?> load(Track track) async {
    final generation = cache.generation;
    started.complete();
    try {
      final path = await answer.future;
      if (path != null) {
        await cache.put('race-torrent', _image, expectedGeneration: generation);
      }
      return path;
    } finally {
      finished.complete();
    }
  }

  @override
  void cancelPending() {
    cancelled = true;
    super.cancelPending();
  }
}

class _RaceApp extends AppController {
  _RaceApp({
    required super.library,
    required super.playback,
    required super.downloads,
    required super.torrents,
    required super.engine,
    required super.metadata,
    required this.artwork,
  });
  final _RaceTorrent artwork;
  @override
  TorrentArtworkRepository get torrentArtwork => artwork;
}

class _Fixture {
  late final Directory root;
  late final LibraryRepository library;
  late final TorrentService torrents;
  late final DiskMediaCache cache;
  late final MusicMetadataRepository metadata;
  late final PlaybackController playback;
  late final DownloadRepository downloads;
  late final AppController app;
  late final Track track;
  late final TorrentInfo info;
  _RaceTorrent? raceTorrent;
  _RaceMetadata? raceMetadata;
  int endpoints = 0, remoteRequests = 0;

  Future<void> initialize({bool probe = false, bool race = false}) async {
    root = await Directory.systemTemp.createTemp('mumpa-cover-controller-');
    library = LibraryRepository(root);
    await library.load();
    final sources = await Directory('${root.path}/sources').create();
    final bytes = Uint8List.fromList(
      _encode({
        'info': <String, Object>{
          'name': 'Band - Discography',
          'piece length': 16384,
          'pieces': Uint8List(20),
          'files': [
            <String, Object>{
              'length': 100,
              'path': ['2001 - Album', '01.mp3'],
            },
            <String, Object>{
              'length': _image.length,
              'path': ['2001 - Album', 'cover.png'],
            },
          ],
        },
      }),
    );
    info = readTorrentMetainfo(bytes);
    await File(
      '${sources.path}/${stableId(info.hash)}.torrent',
    ).writeAsBytes(bytes);
    torrents = TorrentService(
      sources: sources,
      endpoint: () async {
        endpoints++;
        throw StateError('No torrent engine should be started by a disk hit.');
      },
    );
    track = torrents.tracks(info, artist: 'Band').single;
    cache = DiskMediaCache(Directory('${root.path}/metadata'));
    metadata = race
        ? (raceMetadata = _RaceMetadata(cache))
        : MusicMetadataRepository(
            cache: cache,
            requestInterval: Duration.zero,
            client: MockClient((_) async {
              remoteRequests++;
              throw StateError(
                'No metadata HTTP is allowed in an offline disk hit.',
              );
            }),
          );
    playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    await playback.initialize(platformAudio: false);
    downloads = DownloadRepository(library, torrents);
    final engine = TorrentEngine(root);
    app = race
        ? _RaceApp(
            library: library,
            playback: playback,
            downloads: downloads,
            torrents: torrents,
            engine: engine,
            metadata: metadata,
            artwork: raceTorrent = _RaceTorrent(
              torrents: torrents,
              cache: cache,
            ),
          )
        : probe
        ? _ArtworkProbe(
            library: library,
            playback: playback,
            downloads: downloads,
            torrents: torrents,
            engine: engine,
            metadata: metadata,
          )
        : AppController(
            library: library,
            playback: playback,
            downloads: downloads,
            torrents: torrents,
            engine: engine,
            metadata: metadata,
          );
  }

  Future<String?> saveFallback() => cache.put(
    'deezer-cover:${normalizeMusicName(track.artist)}:${artworkAlbumIdentity(track.album)}',
    _image,
    extension: 'png',
  );

  Future<String?> saveTorrent() => cache.put(
    'torrent-cover:${info.hash}:${selectTorrentArtwork(info, track)!.index}',
    _image,
    extension: 'png',
  );

  Future<void> close() async {
    app.dispose();
    await downloads.close();
    await playback.close();
    torrents.dispose();
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fast public cover does not wait for a stalled torrent cover', () async {
    final f = _Fixture();
    await f.initialize(race: true);
    try {
      expect(f.raceTorrent!.requestTimeout, const Duration(seconds: 45));
      final pending = f.app.loadTrackArtwork(f.track);
      await Future.wait([
        f.raceTorrent!.started.future,
        f.raceMetadata!.started.future,
      ]);
      f.raceMetadata!.answer.complete('/public-cover.png');
      expect(
        await pending.timeout(const Duration(seconds: 1)),
        '/public-cover.png',
      );
      expect(f.raceTorrent!.finished.isCompleted, isFalse);
      // A late successful torrent still saves its bounded result normally.
      f.raceTorrent!.answer.complete('/torrent-cover.png');
      await f.raceTorrent!.finished.future;
      expect(await f.cache.pathFor('race-torrent'), isNotNull);
    } finally {
      await f.close();
    }
  });

  for (final firstSource in ['torrent', 'metadata']) {
    test(
      'a null $firstSource cover waits for the other successful source',
      () async {
        final f = _Fixture();
        await f.initialize(race: true);
        try {
          var completed = false;
          final pending = f.app.loadTrackArtwork(f.track).then((path) {
            completed = true;
            return path;
          });
          await Future.wait([
            f.raceTorrent!.started.future,
            f.raceMetadata!.started.future,
          ]);
          final first = firstSource == 'torrent'
              ? f.raceTorrent!.answer
              : f.raceMetadata!.answer;
          final firstDone = firstSource == 'torrent'
              ? f.raceTorrent!.finished
              : f.raceMetadata!.finished;
          final second = firstSource == 'torrent'
              ? f.raceMetadata!.answer
              : f.raceTorrent!.answer;
          first.complete(null);
          await firstDone.future;
          await Future<void>.delayed(Duration.zero);
          expect(completed, isFalse);
          second.complete('/second-cover.png');
          expect(await pending, '/second-cover.png');
        } finally {
          await f.close();
        }
      },
    );
  }

  test('an optional source exception still allows the other cover', () async {
    final f = _Fixture();
    await f.initialize(race: true);
    try {
      final pending = f.app.loadTrackArtwork(f.track);
      await Future.wait([
        f.raceTorrent!.started.future,
        f.raceMetadata!.started.future,
      ]);
      f.raceMetadata!.answer.completeError(
        StateError('Optional artwork failed.'),
      );
      await f.raceMetadata!.finished.future;
      f.raceTorrent!.answer.complete('/torrent-cover.png');
      expect(await pending, '/torrent-cover.png');
    } finally {
      await f.close();
    }
  });

  test(
    'clear during the artwork race rejects stale paths and late cache writes',
    () async {
      final f = _Fixture();
      await f.initialize(race: true);
      try {
        final stale = await f.cache.put('old-cover', _image, extension: 'png');
        final pending = f.app.loadTrackArtwork(f.track);
        await Future.wait([
          f.raceTorrent!.started.future,
          f.raceMetadata!.started.future,
        ]);
        await f.app.clearMetadataCache();
        expect(f.raceTorrent!.cancelled, isTrue);
        f.raceMetadata!.answer.complete(stale);
        f.raceTorrent!.answer.complete(stale);
        expect(await pending, isNull);
        await Future.wait([
          f.raceTorrent!.finished.future,
          f.raceMetadata!.finished.future,
        ]);
        expect((await f.cache.stats()).count, 0);
        expect(await File(stale!).exists(), isFalse);
      } finally {
        await f.close();
      }
    },
  );

  test('cached artwork lookup reads exact CAA identity without HTTP', () async {
    final root = await Directory.systemTemp.createTemp('mumpa-cached-cover-');
    final cache = DiskMediaCache(root);
    var requests = 0;
    final repo = MusicMetadataRepository(
      cache: cache,
      client: MockClient((_) async {
        requests++;
        throw StateError('Disk lookup must not request HTTP.');
      }),
    );
    const id = '48117b90-a16e-34ca-a514-19c702df1158';
    final uri = Uri.https('musicbrainz.org', '/ws/2/release-group', {
      'fmt': 'json',
      'query': 'artist:"Band" AND releasegroup:"Album"',
      'limit': '5',
    });
    try {
      await cache.put(
        'mb:$uri',
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'release-groups': [
                {
                  'id': id,
                  'title': 'Album',
                  'artist-credit': [
                    {'name': 'Band'},
                  ],
                },
              ],
            }),
          ),
        ),
        extension: 'json',
      );
      final cover = await cache.put('cover:$id', _image, extension: 'png');
      expect(await repo.cachedCoverForAlbum('Band', 'Album'), cover);
      expect(await repo.cachedCoverForAlbum('Another Band', 'Album'), isNull);
      await cache.clear();
      expect(await repo.cachedCoverForAlbum('Band', 'Album'), isNull);
      expect(requests, 0);
    } finally {
      repo.dispose();
      await root.delete(recursive: true);
    }
  });

  test(
    'ready fallback artwork skips torrent engine on repeated views',
    () async {
      final f = _Fixture();
      await f.initialize();
      try {
        final cover = await f.saveFallback();
        expect(await f.app.loadTrackArtwork(f.track), cover);
        expect(await f.app.loadTrackArtwork(f.track), cover);
        expect(
          await f.app.loadReleaseGroupArtwork(
            MusicReleaseGroup(
              id: '48117b90-a16e-34ca-a514-19c702df1158',
              artist: f.track.artist,
              title: f.track.album,
            ),
          ),
          cover,
        );
        expect(f.endpoints, 0);
        expect(f.remoteRequests, 0);
        await f.cache.clear();
        expect(
          await f.metadata.cachedCoverForAlbum(f.track.artist, f.track.album),
          isNull,
        );
        expect(f.remoteRequests, 0);
      } finally {
        await f.close();
      }
    },
  );

  test('cached torrent artwork wins over cached public metadata', () async {
    final f = _Fixture();
    await f.initialize();
    try {
      final fallback = await f.saveFallback();
      final cover = await f.saveTorrent();
      expect(cover, isNot(fallback));
      expect(await f.app.loadTrackArtwork(f.track), cover);
      expect(f.endpoints, 0);
      expect(f.remoteRequests, 0);
    } finally {
      await f.close();
    }
  });

  test('cached torrent cover remains usable without artist metadata', () async {
    final f = _Fixture();
    await f.initialize();
    try {
      final cover = await f.saveTorrent();
      for (final artist in ['', 'Неизвестный исполнитель']) {
        expect(
          await f.app.loadTrackArtwork(
            f.track.copyWith(artist: artist, albumArtist: ''),
          ),
          cover,
        );
      }
      expect(f.endpoints, 0);
      expect(f.remoteRequests, 0);
    } finally {
      await f.close();
    }
  });

  testWidgets('track and album widgets request covers for unknown artists', (
    tester,
  ) async {
    final f = _Fixture();
    await tester.runAsync(() => f.initialize(probe: true));
    try {
      final track = f.track.copyWith(
        artist: 'Неизвестный исполнитель',
        albumArtist: '',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              TrackArtwork(app: f.app, track: track),
              AlbumArtwork(app: f.app, album: Album([track])),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect((f.app as _ArtworkProbe).artworkLoads, 2);
      expect(f.endpoints, 0);
      expect(f.remoteRequests, 0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    }
  });

  test(
    'separate album identity preserves meaningful suffixes and survives offline restart',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-album-cover-');
      const liveId = '48117b90-a16e-34ca-a514-19c702df1158';
      var metadataRequests = 0, coverRequests = 0;
      final repo = MusicMetadataRepository(
        cache: DiskMediaCache(root),
        requestInterval: Duration.zero,
        client: MockClient((request) async {
          if (request.url.host == 'musicbrainz.org') {
            metadataRequests++;
            return http.Response(
              jsonEncode({
                'release-groups': [
                  for (final (title, id) in [
                    ('Album', 'wrong-id'),
                    ('Album (Live)', liveId),
                  ])
                    {
                      'id': id,
                      'title': title,
                      'artist-credit': [
                        {'name': 'Band'},
                      ],
                    },
                ],
              }),
              200,
            );
          }
          coverRequests++;
          expect(request.url.path, contains(liveId));
          return http.Response.bytes(
            [255, 216, 255, 217],
            200,
            headers: {'content-type': 'image/jpeg'},
          );
        }),
      );
      try {
        final results = await Future.wait([
          repo.coverForAlbum('Band', 'Album (Live)'),
          repo.coverForAlbum('Band', 'Album (Live)'),
        ]);
        expect(results.first, isNotNull);
        expect(results.last, results.first);
        expect(metadataRequests, 1);
        expect(coverRequests, 1);
        final restarted = MusicMetadataRepository(
          cache: DiskMediaCache(root),
          requestInterval: Duration.zero,
          client: MockClient((_) async => throw StateError('offline')),
        );
        try {
          expect(
            await restarted.coverForAlbum('Band', 'Album (Live)'),
            results.first,
          );
        } finally {
          restarted.dispose();
        }
      } finally {
        repo.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test('same album title by another artist does not provide a cover', () async {
    final root = await Directory.systemTemp.createTemp(
      'mumpa-ambiguous-cover-',
    );
    var images = 0;
    final repo = MusicMetadataRepository(
      cache: DiskMediaCache(root),
      requestInterval: Duration.zero,
      client: MockClient((request) async {
        if (request.url.host != 'musicbrainz.org') {
          if (request.url.host != 'api.deezer.com') images++;
          return http.Response('missing', 404);
        }
        return http.Response(
          '{"release-groups":[{"id":"48117b90-a16e-34ca-a514-19c702df1158","title":"Album","artist-credit":[{"name":"Another artist"}]}]}',
          200,
        );
      }),
    );
    try {
      expect(await repo.coverForAlbum('Band', 'Album'), isNull);
      expect(images, 0);
    } finally {
      repo.dispose();
      await root.delete(recursive: true);
    }
  });
}
