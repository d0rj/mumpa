import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_metainfo.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/data/track_search_service.dart';
import 'package:mumpa/domain/music_metadata.dart';

Uint8List encode(Object value) {
  if (value is int) return Uint8List.fromList(ascii.encode('i${value}e'));
  if (value is String) {
    final bytes = utf8.encode(value);
    return Uint8List.fromList([...ascii.encode('${bytes.length}:'), ...bytes]);
  }
  if (value is Uint8List) {
    return Uint8List.fromList([...ascii.encode('${value.length}:'), ...value]);
  }
  if (value is List) {
    return Uint8List.fromList([
      108,
      ...value.expand((v) => encode(v as Object)),
      101,
    ]);
  }
  final map = value as Map<String, Object>;
  final keys = map.keys.toList()..sort();
  return Uint8List.fromList([
    100,
    ...keys.expand((key) => [...encode(key), ...encode(map[key]!)]),
    101,
  ]);
}

Uint8List metainfo(String filename) => encode(<String, Object>{
  'info': <String, Object>{
    'name': 'Band - Album',
    'piece length': 16384,
    'pieces': Uint8List(20),
    'files': [
      <String, Object>{
        'length': 1234,
        'path': [filename],
      },
    ],
  },
});

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-metadata-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'parses exact info hash and UTF8 files using TorrServer IDs without starting engine',
    () {
      final info = <String, Object>{
        'name': 'Ежемесячные',
        'piece length': 16384,
        'pieces': Uint8List(20),
        'files': [
          <String, Object>{
            'length': 55,
            'path': ['cover.jpg'],
          },
          <String, Object>{
            'length': 123,
            'path': ['11 - Роженица в метро.flac'],
          },
        ],
      };
      final torrent = readTorrentMetainfo(
        encode(<String, Object>{'info': info}),
      );
      expect(torrent.hash, sha1.convert(encode(info)).toString());
      expect(torrent.files.last.index, 2);
      expect(torrent.files.last.path, 'Ежемесячные/11 - Роженица в метро.flac');
      expect(
        () => readTorrentMetainfo(
          Uint8List.fromList(ascii.encode('d4:infodeeEXTRA')),
        ),
        throwsFormatException,
      );
      final unsafe = <String, Object>{...info, 'name': '..'};
      expect(
        () => readTorrentMetainfo(encode(<String, Object>{'info': unsafe})),
        throwsFormatException,
      );
    },
  );

  test(
    'matches Unicode artist names and tracks conservatively and preserves version labels',
    () {
      const song = MusicRecording(
        id: 'song',
        title: 'Роженица в метро',
        artist: 'Ежемесячные',
      );
      expect(
        matchesRecordingFilename(
          'folder/11. Роженица в метро (Explicit).flac',
          song,
        ),
        isTrue,
      );
      expect(
        matchesRecordingFilename(
          'folder/11. Роженица в метро Remix.flac',
          song,
        ),
        isFalse,
      );
      expect(normalizeMusicName('Ёлка — 01'), 'елка 01');
      expect(
        parseReleaseIdentity(
          '(Rap) Ежемесячные - Альбом (2019), MP3, 320 kbps',
        ),
        (artist: 'Ежемесячные', album: 'Альбом'),
      );
      expect(describeEdition('FLAC'), 'Цензура не указана');
      expect(describeEdition('Song Uncensored FLAC'), contains('Без цензуры'));
    },
  );

  test(
    'artist aliases and discography survive disk cache restart without HTTP',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.headers['user-agent'], contains('Mumpa/1.2.0'));
        final path = request.url.path;
        final Map<String, Object> data;
        if (path.endsWith('/artist')) {
          expect(request.url.queryParameters['query'], contains('alias:'));
          data = {
            'artists': [
              <String, Object>{
                'id': 'band-id',
                'name': 'Band',
                'aliases': [
                  <String, Object>{'name': 'Группа'},
                ],
              },
            ],
          };
        } else if (path.endsWith('/artist/band-id')) {
          data = {
            'id': 'band-id',
            'name': 'Band',
            'type': 'Group',
            'country': 'RU',
            'aliases': [
              <String, Object>{'name': 'Группа'},
            ],
          };
        } else if (path.endsWith('/release-group')) {
          data = {
            'release-groups': [
              <String, Object>{
                'id': 'album-id',
                'title': 'Album',
                'primary-type': 'Album',
                'first-release-date': '2001-02-03',
              },
            ],
          };
        } else {
          expect(request.url.queryParameters['inc'], 'artist-credits');
          data = {
            'recordings': [
              <String, Object>{
                'id': 'song-id',
                'title': 'Song',
                'length': 120000,
                'releases': [
                  <String, Object>{'title': 'Album'},
                ],
              },
            ],
          };
        }
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final repository = MusicMetadataRepository(
        cache: DiskMediaCache(root),
        client: client,
        requestInterval: Duration.zero,
      );
      final artist = await repository.artist('Группа');
      expect(artist!.matches('Группа'), isTrue);
      expect(artist.albums.single.year, '2001');
      expect(artist.recordings.single.albumTitles, ['Album']);
      expect(requests, 4);
      repository.dispose();
      final offline = MusicMetadataRepository(
        cache: DiskMediaCache(root),
        client: MockClient(
          (_) async => throw StateError('HTTP must not repeat'),
        ),
      );
      expect((await offline.artist('Группа'))!.id, 'band-id');
      offline.dispose();
      final unrelated = MusicMetadataRepository(
        cache: DiskMediaCache(root),
        requestInterval: Duration.zero,
        client: MockClient(
          (_) async => http.Response(
            '{"artists":[{"id":"other","name":"Other Band"}]}',
            200,
          ),
        ),
      );
      expect(await unrelated.artist('Unrelated Band'), isNull);
      unrelated.dispose();
    },
  );

  test(
    'cancelled metadata search releases the queue for the newest query',
    () async {
      final started = Completer<void>(), old = Completer<http.Response>();
      final cache = DiskMediaCache(root);
      final repo = MusicMetadataRepository(
        cache: cache,
        requestInterval: Duration.zero,
        client: MockClient((request) {
          if (request.url.queryParameters['query'] == 'old') {
            started.complete();
            return old.future;
          }
          return Future.value(
            http.Response(
              '{"recordings":[{"id":"new-id","title":"New song","artist-credit":[{"name":"Band","artist":{"id":"band","name":"Band"}}]}]}',
              200,
            ),
          );
        }),
      );
      final operation = SourceOperation();
      final pending = repo.searchRecordings('old', operation: operation);
      final rejected = expectLater(pending, throwsA(isA<SourceCancelled>()));
      await started.future;
      operation.cancel();
      expect((await repo.searchRecordings('new')).single.title, 'New song');
      await rejected;
      old.complete(http.Response('{"recordings":[]}', 200));
      expect((await cache.stats()).count, 1);
      repo.dispose();
    },
  );

  test(
    'cover is coalesced and reused across restart; clearing allows a fresh fetch',
    () async {
      const id = '48117b90-a16e-34ca-a514-19c702df1158';
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response.bytes(
          [255, 216, 255, 217],
          200,
          headers: {'content-type': 'image/jpeg'},
        );
      });
      final cache = DiskMediaCache(root);
      final repo = MusicMetadataRepository(cache: cache, client: client);
      final result = await Future.wait([
        repo.coverForGroup(id),
        repo.coverForGroup(id),
      ]);
      expect(result.first, result.last);
      expect(requests, 1);
      final restart = MusicMetadataRepository(
        cache: DiskMediaCache(root),
        client: MockClient((_) async => throw StateError('offline')),
      );
      expect(await restart.coverForGroup(id), result.first);
      restart.dispose();
      await cache.clear();
      expect(await repo.coverForGroup(id), isNotNull);
      expect(requests, 2);
      repo.dispose();
    },
  );

  test('clearing during a cover request prevents stale disk writes', () async {
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    final cache = DiskMediaCache(root);
    final repo = MusicMetadataRepository(
      cache: cache,
      client: MockClient((_) {
        started.complete();
        return pending.future;
      }),
    );
    final result = repo.coverForGroup('48117b90-a16e-34ca-a514-19c702df1158');
    await started.future;
    await cache.clear();
    pending.complete(
      http.Response.bytes(
        [1, 2, 3],
        200,
        headers: {'content-type': 'image/jpeg'},
      ),
    );
    expect(await result, isNull);
    expect((await cache.stats()).count, 0);
    repo.dispose();
  });

  test(
    'clearing during release matching prevents the old chain from starting a cover fetch',
    () async {
      final delayed = Completer<http.Response>();
      final started = Completer<void>();
      var metadataRequests = 0, coverRequests = 0;
      final data = jsonEncode({
        'release-groups': [
          {
            'id': '48117b90-a16e-34ca-a514-19c702df1158',
            'title': 'Album',
            'artist-credit': [
              {
                'name': 'Band',
                'artist': {'id': 'band-id', 'name': 'Band'},
              },
            ],
          },
        ],
      });
      final cache = DiskMediaCache(root);
      final repo = MusicMetadataRepository(
        cache: cache,
        requestInterval: Duration.zero,
        client: MockClient((request) {
          if (request.url.host == 'musicbrainz.org') {
            metadataRequests++;
            if (metadataRequests == 1) {
              started.complete();
              return delayed.future;
            }
            return Future.value(http.Response(data, 200));
          }
          coverRequests++;
          return Future.value(
            http.Response.bytes(
              [255, 216, 255, 217],
              200,
              headers: {'content-type': 'image/jpeg'},
            ),
          );
        }),
      );
      final old = repo.coverForReleaseTitle('Band - Album');
      await started.future;
      await cache.clear();
      delayed.complete(http.Response(data, 200));
      expect(await old, isNull);
      expect(coverRequests, 0);
      expect((await cache.stats()).count, 0);

      // Clearing invalidates only old work; a fresh request may populate cache.
      expect(await repo.coverForReleaseTitle('Band - Album'), isNotNull);
      expect(metadataRequests, 2);
      expect(coverRequests, 1);
      expect((await cache.stats()).count, 2);
      repo.dispose();
    },
  );

  test(
    'clearing interrupts old artist lookup before its discography requests',
    () async {
      final delayed = Completer<http.Response>();
      final started = Completer<void>();
      var requests = 0;
      final cache = DiskMediaCache(root);
      final repo = MusicMetadataRepository(
        cache: cache,
        requestInterval: Duration.zero,
        client: MockClient((_) {
          requests++;
          if (requests == 1) {
            started.complete();
            return delayed.future;
          }
          throw StateError('Old workflow must not start a second API request');
        }),
      );
      final old = repo.artist('Band');
      final rejected = expectLater(old, throwsA(isA<SourceCancelled>()));
      await started.future;
      await cache.clear();
      delayed.complete(
        http.Response('{"artists":[{"id":"band-id","name":"Band"}]}', 200),
      );
      await rejected;
      expect(requests, 1);
      expect((await cache.stats()).count, 0);
      repo.dispose();
    },
  );

  test(
    'finds MP3 and FLAC from real metainfo filenames, not release titles; reuses metadata cache',
    () async {
      var torrentRequests = 0, engineRequests = 0;
      final indexer = IndexerService(
        client: MockClient((request) async {
          if (request.url.path == '/api') {
            return http.Response(
              '<rss><channel>'
              '<item><title>Band - Album MP3 Clean</title><link>http://localhost/mp3.torrent</link></item>'
              '<item><title>Band - Album FLAC Uncensored</title><link>http://localhost/flac.torrent</link></item>'
              '<item><title>Band - Album FLAC</title><link>http://localhost/false.torrent</link></item>'
              '</channel></rss>',
              200,
            );
          }
          torrentRequests++;
          final filename = switch (request.url.path) {
            '/mp3.torrent' => '01 - Song (Clean).mp3',
            '/flac.torrent' => '01 - Song (Explicit).flac',
            _ => '01 - Different Song.flac',
          };
          return http.Response.bytes(metainfo(filename), 200);
        }),
      );
      final torrents = TorrentService(
        endpoint: () async {
          engineRequests++;
          throw StateError('No engine during search');
        },
      );
      final service = TrackSearchService(
        indexer: indexer,
        torrents: torrents,
        cache: DiskMediaCache(Directory('${root.path}/cache')),
        workDirectory: Directory('${root.path}/work'),
      );
      const recording = MusicRecording(
        id: 'song',
        title: 'Song',
        artist: 'Band',
        albumTitles: ['Album'],
      );
      final results = await service.find(
        recording,
        endpoint: 'http://localhost/api',
        key: '',
        operation: SourceOperation(),
      );
      expect(results.map((v) => v.format).toSet(), {'MP3', 'FLAC'});
      expect(
        results
            .map((v) => v.edition)
            .any((label) => label.contains('Без цензуры')),
        isTrue,
      );
      expect(engineRequests, 0);
      expect(torrentRequests, 3);
      expect(
        (await service.find(
          recording,
          endpoint: 'http://localhost/api',
          key: '',
          operation: SourceOperation(),
        )).length,
        2,
      );
      expect(torrentRequests, 3);
      indexer.dispose();
      torrents.dispose();
    },
  );
}
