import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/catalog_repository.dart';
import 'package:mumpa/data/deezer_catalog_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/domain/models.dart';

Map<String, dynamic> row() => {
  'id': 123,
  'title': 'Роженица в метро',
  'duration': 240,
  'isrc': 'FR2X42545138',
  'explicit_lyrics': true,
  'artist': {'id': 5, 'name': 'Ежемесячные'},
  'album': {'title': 'Альбом'},
  'contributors': [
    {'id': 5, 'name': 'Ежемесячные'},
    {'id': 6, 'name': 'Блёв Мс'},
  ],
  'preview': 'https://example.invalid/never-request-audio.mp3',
};
http.Response json(Object data, [int code = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), code);

void main() {
  late Directory root;
  late DiskMediaCache cache;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-catalog-http-');
    cache = DiskMediaCache(root);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'Deezer parses all artists and ISRC, caches metadata and never requests preview',
    () async {
      final requests = <Uri>[];
      final client = MockClient((r) async {
        requests.add(r.url);
        return json(
          r.url.path == '/search'
              ? {
                  'data': [row()],
                }
              : row(),
        );
      });
      final repo = DeezerCatalogRepository(
        cache: cache,
        client: client,
        interval: Duration.zero,
      );
      try {
        final found = (await repo.search(
          'Ежемесячные Роженица в метро',
        )).single;
        expect(found.artists.map((a) => a.name), ['Ежемесячные', 'Блёв Мс']);
        expect(found.isrcs, ['FR2X42545138']);
        expect(found.durationMs, 240000);
        await repo.recording(found.id);
        final offline = DeezerCatalogRepository(
          cache: cache,
          client: MockClient((_) async => throw StateError('offline')),
        );
        try {
          expect(
            (await offline.search('Ежемесячные Роженица в метро')).single.key,
            'deezer:123',
          );
        } finally {
          offline.dispose();
        }
        expect(requests.map((u) => u.host).toSet(), {'api.deezer.com'});
        expect(requests.map((u) => u.path), ['/search', '/track/123']);
      } finally {
        repo.dispose();
        client.close();
      }
    },
  );

  test('HTTP 200 API errors are not cached as empty search results', () async {
    var calls = 0;
    final client = MockClient(
      (_) async => json(
        ++calls == 1
            ? {
                'error': {'code': 4, 'message': 'quota'},
              }
            : {
                'data': [row()],
              },
      ),
    );
    final repo = DeezerCatalogRepository(
      cache: cache,
      client: client,
      interval: Duration.zero,
    );
    try {
      await expectLater(repo.search('song'), throwsA(isA<HttpException>()));
      expect(await repo.search('song'), hasLength(1));
      expect(calls, 2);
    } finally {
      repo.dispose();
      client.close();
    }
  });

  test(
    'rate limit prevents subsequent network requests before Retry-After',
    () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('', 429, headers: {'retry-after': '60'});
      });
      final repo = DeezerCatalogRepository(
        cache: cache,
        client: client,
        interval: Duration.zero,
      );
      try {
        await expectLater(repo.search('one'), throwsA(isA<HttpException>()));
        await expectLater(repo.search('two'), throwsA(isA<HttpException>()));
        expect(calls, 1);
      } finally {
        repo.dispose();
        client.close();
      }
    },
  );

  test('cache clear discards a late HTTP result', () async {
    final started = Completer<void>(), response = Completer<http.Response>();
    final client = MockClient((_) {
      started.complete();
      return response.future;
    });
    final repo = DeezerCatalogRepository(
      cache: cache,
      client: client,
      interval: Duration.zero,
    );
    try {
      final pending = repo.search('old');
      final expectation = expectLater(pending, throwsA(isA<SourceCancelled>()));
      await started.future;
      await cache.clear();
      response.complete(
        json({
          'data': [row()],
        }),
      );
      await expectation;
    } finally {
      repo.dispose();
      client.close();
    }
  });

  test(
    'one failing provider preserves other results and reports the outage',
    () async {
      final client = MockClient(
        (r) async => r.url.host == 'musicbrainz.org'
            ? http.Response('', 500)
            : json({
                'data': [row()],
              }),
      );
      final mb = MusicMetadataRepository(
        cache: cache,
        client: client,
        requestInterval: Duration.zero,
      );
      final repo = CatalogRepository(
        musicBrainz: mb,
        deezer: DeezerCatalogRepository(
          cache: cache,
          client: client,
          interval: Duration.zero,
        ),
      );
      try {
        final result = await repo.search('Роженица в метро');
        expect(result.recordings.single.key, 'deezer:123');
        expect(result.unavailableProviders, ['MusicBrainz']);
      } finally {
        repo.dispose();
        mb.dispose();
      }
    },
  );

  test(
    'typed matching searches a primary artist and checks every supplied collaborator',
    () async {
      final queries = <String>[];
      final client = MockClient((r) async {
        if (r.url.host == 'musicbrainz.org') {
          queries.add(r.url.queryParameters['query']!);
          return json({'recordings': []});
        }
        queries.add(r.url.queryParameters['q'] ?? r.url.path);
        return json(
          r.url.path == '/search'
              ? {
                  'data': [row()],
                }
              : row(),
        );
      });
      final mb = MusicMetadataRepository(
        cache: cache,
        client: client,
        requestInterval: Duration.zero,
      );
      final repo = CatalogRepository(
        musicBrainz: mb,
        deezer: DeezerCatalogRepository(
          cache: cache,
          client: client,
          interval: Duration.zero,
        ),
      );
      try {
        const track = Track(
          id: 'test',
          title: 'Роженица в метро',
          artist: 'Ежемесячные feat. Блёв Мс',
          album: 'Альбом',
          durationMs: 240483,
          source: TrackSource.local,
        );
        final result = await repo.match(track);
        expect(result.automatic?.recording.key, 'deezer:123');
        expect(queries.where((q) => q.contains('Блёв')), isEmpty);
        expect(queries, contains('/track/123'));
      } finally {
        repo.dispose();
        mb.dispose();
      }
    },
  );

  test('homonymous MusicBrainz artists require an explicit ID', () async {
    final client = MockClient(
      (_) async => json({
        'artists': [
          {'id': 'one', 'name': 'Кино'},
          {'id': 'two', 'name': 'Кино'},
        ],
      }),
    );
    final mb = MusicMetadataRepository(
      cache: cache,
      client: client,
      requestInterval: Duration.zero,
    );
    try {
      expect(await mb.artist('Кино'), isNull);
    } finally {
      mb.dispose();
    }
  });
}
