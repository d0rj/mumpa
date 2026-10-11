import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/similar_artists_repository.dart';
import 'package:mumpa/data/source_operation.dart';

const _seed = 'f646239d-504c-479d-a047-8ab4ee22c9f3';
const _otherSeed = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
const _artist = '37920299-9dc8-4038-954a-ad4cb824e812';
const _secondArtist = 'a534449a-b8fe-4667-b712-0f960149fb4f';

Map<String, Object?> _row({
  String id = _artist,
  String name = 'Слава КПСС',
  int score = 17,
  String reference = _seed,
}) => {
  'artist_mbid': id,
  'name': name,
  'score': score,
  'comment': 'Russian rapper',
  'type': 'Person',
  'reference_mbid': reference,
};

http.Response _response(List<Object?> rows) => http.Response(
  jsonEncode(rows),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-similar-artists-');
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'sends only public MBID and algorithm and checks identity and rank',
    () async {
      var calls = 0;
      final repo = SimilarArtistsRepository(
        cache: DiskMediaCache(root),
        requestInterval: Duration.zero,
        client: MockClient((request) async {
          calls++;
          expect(request.url.scheme, 'https');
          expect(request.url.host, 'labs.api.listenbrainz.org');
          expect(request.url.path, '/similar-artists/json');
          expect(request.url.queryParameters, {
            'artist_mbids': _seed,
            'algorithm': SimilarArtistsRepository.algorithm,
          });
          expect(request.headers['User-Agent'], startsWith('Mumpa/'));
          expect(request.headers['Authorization'], isNull);
          return _response([
            _row(id: _secondArtist, name: 'СД', score: 15),
            _row(score: 3),
            _row(),
            _row(id: _seed, name: 'Ежемесячные', score: 100),
            _row(id: 'not-an-mbid'),
            _row(id: _otherSeed, reference: _otherSeed),
            _row(id: _otherSeed, name: ''),
            _row(id: _otherSeed, name: 'bad\u0000name'),
            _row(id: _otherSeed, score: -1),
            {'artist_mbid': _otherSeed, 'name': 10, 'score': 20},
            null,
          ]);
        }),
      );
      addTearDown(repo.dispose);
      final artists = await repo.similarArtists(' ${_seed.toUpperCase()} ');
      expect(artists.map((a) => a.id), [_artist, _secondArtist]);
      expect(artists.map((a) => a.score), [17, 15]);
      expect(artists.first.name, 'Слава КПСС');
      expect(artists.first.disambiguation, 'Russian rapper');
      expect(() => artists.clear(), throwsUnsupportedError);
      expect(calls, 1);
    },
  );

  test(
    'bounds the list without confusing equal scores or malformed names',
    () async {
      final rows = <Object?>[
        for (var i = 1; i <= 25; i++)
          _row(
            id: '${i.toRadixString(16).padLeft(8, '0')}-0000-0000-0000-000000000001',
            name: 'Artist ${i.toString().padLeft(2, '0')}',
            score: i,
          ),
        _row(id: _otherSeed, name: List.filled(257, 'A').join(), score: 1000),
      ];
      final repo = SimilarArtistsRepository(
        cache: DiskMediaCache(root),
        client: MockClient((_) async => _response(rows)),
      );
      addTearDown(repo.dispose);
      final artists = await repo.similarArtists(_seed);
      expect(artists.length, SimilarArtistsRepository.maxResults);
      expect(artists.first.name, 'Artist 25');
      expect(artists.last.score, 14);
    },
  );

  test('cached recommendations survive restart with no network', () async {
    final cache = DiskMediaCache(root);
    var calls = 0;
    final repo = SimilarArtistsRepository(
      cache: cache,
      client: MockClient((_) async {
        calls++;
        return _response([_row()]);
      }),
    );
    await repo.similarArtists(_seed);
    repo.dispose();
    final restarted = SimilarArtistsRepository(
      cache: DiskMediaCache(root),
      client: MockClient((_) async => throw StateError('Network is offline')),
    );
    addTearDown(restarted.dispose);
    expect((await restarted.similarArtists(_seed)).single.name, 'Слава КПСС');
    expect(calls, 1);
    expect((await cache.stats()).count, 1);
  });

  test(
    'positive cache expires after seven days and empty results after one',
    () async {
      var now = DateTime.utc(2026, 10, 11);
      final cache = DiskMediaCache(root, clock: () => now);
      var calls = 0;
      final repo = SimilarArtistsRepository(
        cache: cache,
        requestInterval: Duration.zero,
        client: MockClient((_) async {
          calls++;
          return _response(calls < 3 ? [_row()] : []);
        }),
      );
      addTearDown(repo.dispose);
      await repo.similarArtists(_seed);
      now = now.add(const Duration(days: 6));
      await repo.similarArtists(_seed);
      expect(calls, 1);
      now = now.add(const Duration(days: 1));
      await repo.similarArtists(_seed);
      expect(calls, 2);
      await cache.clear();
      expect(await repo.similarArtists(_seed), isEmpty);
      expect(calls, 3);
      now = now.add(const Duration(hours: 23));
      expect(await repo.similarArtists(_seed), isEmpty);
      expect(calls, 3);
      now = now.add(const Duration(hours: 1));
      expect(await repo.similarArtists(_seed), isEmpty);
      expect(calls, 4);
    },
  );

  test(
    'deduplicates pending requests while cancelling each waiter separately',
    () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      var calls = 0;
      final repo = SimilarArtistsRepository(
        cache: DiskMediaCache(root),
        client: MockClient((_) async {
          calls++;
          started.complete();
          return response.future;
        }),
      );
      addTearDown(repo.dispose);
      final operation = SourceOperation();
      final first = repo.similarArtists(_seed, operation: operation);
      final cancelled = expectLater(first, throwsA(isA<SourceCancelled>()));
      final second = repo.similarArtists(_seed);
      await started.future;
      operation.cancel();
      await cancelled;
      response.complete(_response([_row()]));
      expect((await second).single.name, 'Слава КПСС');
      expect(calls, 1);
    },
  );

  test(
    'clearing during network work prevents late result and stale cache write',
    () async {
      final cache = DiskMediaCache(root);
      final started = Completer<void>();
      final response = Completer<http.Response>();
      var calls = 0;
      final repo = SimilarArtistsRepository(
        cache: cache,
        requestInterval: Duration.zero,
        client: MockClient((_) async {
          calls++;
          if (calls > 1) return _response([_row()]);
          started.complete();
          return response.future;
        }),
      );
      addTearDown(repo.dispose);
      final pending = repo.similarArtists(_seed);
      final cancelled = expectLater(pending, throwsA(isA<SourceCancelled>()));
      await started.future;
      await cache.clear();
      response.complete(_response([_row()]));
      await cancelled;
      expect((await cache.stats()).count, 0);
      expect((await repo.similarArtists(_seed)).single.id, _artist);
      expect(calls, 2);
    },
  );

  test('cancelling the only waiter leaves no result or cache record', () async {
    final cache = DiskMediaCache(root);
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final repo = SimilarArtistsRepository(
      cache: cache,
      client: MockClient((_) async {
        started.complete();
        return response.future;
      }),
    );
    addTearDown(repo.dispose);
    final operation = SourceOperation();
    final pending = repo.similarArtists(_seed, operation: operation);
    final cancelled = expectLater(pending, throwsA(isA<SourceCancelled>()));
    await started.future;
    operation.cancel();
    await cancelled;
    response.complete(_response([_row()]));
    expect((await cache.stats()).count, 0);
  });

  test('dispose cancels work but preserves the shared HTTP client', () async {
    final started = Completer<void>();
    final response = Completer<http.StreamedResponse>();
    final client = _TrackingClient((_) {
      started.complete();
      return response.future;
    });
    final repo = SimilarArtistsRepository(
      cache: DiskMediaCache(root),
      client: client,
    );
    final pending = repo.similarArtists(_seed);
    final cancelled = expectLater(pending, throwsA(isA<SourceCancelled>()));
    await started.future;
    repo.dispose();
    await cancelled;
    expect(client.closed, isFalse);
    response.complete(
      http.StreamedResponse(Stream.value(utf8.encode('[]')), 200),
    );
  });

  test(
    'timeout is bounded and failures do not poison a later request',
    () async {
      final response = Completer<http.Response>();
      var calls = 0;
      final repo = SimilarArtistsRepository(
        cache: DiskMediaCache(root),
        requestInterval: Duration.zero,
        requestTimeout: const Duration(milliseconds: 100),
        client: MockClient((_) async {
          calls++;
          return calls == 1 ? response.future : _response([_row()]);
        }),
      );
      addTearDown(repo.dispose);
      await expectLater(
        repo.similarArtists(_seed),
        throwsA(isA<TimeoutException>()),
      );
      response.complete(_response([]));
      expect((await repo.similarArtists(_seed)).single.id, _artist);
      expect(calls, 2);
    },
  );

  test('HTTP errors and malformed responses are not negative cached', () async {
    final cache = DiskMediaCache(root);
    var calls = 0;
    final repo = SimilarArtistsRepository(
      cache: cache,
      requestInterval: Duration.zero,
      client: MockClient((_) async {
        calls++;
        return switch (calls) {
          1 => http.Response('temporarily unavailable', 429),
          2 => http.Response('{"error":"algorithm changed"}', 200),
          _ => _response([_row()]),
        };
      }),
    );
    addTearDown(repo.dispose);
    await expectLater(
      repo.similarArtists(_seed),
      throwsA(isA<HttpException>()),
    );
    await expectLater(
      repo.similarArtists(_seed),
      throwsA(isA<FormatException>()),
    );
    expect((await cache.stats()).count, 0);
    expect((await repo.similarArtists(_seed)).single.id, _artist);
    expect(calls, 3);
  });

  test('limits streamed bytes before parsing and saving', () async {
    final cache = DiskMediaCache(root);
    final client = _TrackingClient(
      (_) async => http.StreamedResponse(
        Stream.value(List<int>.filled(256 * 1024 + 1, 32)),
        200,
      ),
    );
    final repo = SimilarArtistsRepository(cache: cache, client: client);
    addTearDown(repo.dispose);
    await expectLater(
      repo.similarArtists(_seed),
      throwsA(isA<FormatException>()),
    );
    expect((await cache.stats()).count, 0);
  });

  test(
    'rejects invalid seed and already cancelled request without HTTP',
    () async {
      var calls = 0;
      final repo = SimilarArtistsRepository(
        cache: DiskMediaCache(root),
        client: MockClient((_) async {
          calls++;
          return _response([]);
        }),
      );
      addTearDown(repo.dispose);
      await expectLater(
        repo.similarArtists('artist name'),
        throwsArgumentError,
      );
      final operation = SourceOperation()..cancel();
      await expectLater(
        repo.similarArtists(_seed, operation: operation),
        throwsA(isA<SourceCancelled>()),
      );
      expect(calls, 0);
    },
  );

  test(
    'serializes artist requests with the configured start interval',
    () async {
      final starts = <DateTime>[];
      final repo = SimilarArtistsRepository(
        cache: DiskMediaCache(root),
        requestInterval: const Duration(milliseconds: 40),
        client: MockClient((request) async {
          starts.add(DateTime.now());
          return _response([
            _row(reference: request.url.queryParameters['artist_mbids']!),
          ]);
        }),
      );
      addTearDown(repo.dispose);
      await Future.wait([
        repo.similarArtists(_seed),
        repo.similarArtists(_otherSeed),
      ]);
      expect(starts, hasLength(2));
      expect(
        starts.last.difference(starts.first).inMilliseconds,
        greaterThanOrEqualTo(30),
      );
    },
  );

  test(
    'live ListenBrainz recommendations for Ежемесячные use only public MBID',
    () async {
      final client = http.Client();
      final repo = SimilarArtistsRepository(
        cache: DiskMediaCache(root),
        client: client,
      );
      try {
        final artists = await repo.similarArtists(_seed);
        expect(artists, isNotEmpty);
        expect(
          artists.length,
          lessThanOrEqualTo(SimilarArtistsRepository.maxResults),
        );
        expect(
          artists.every((artist) => artist.id != _seed && artist.score > 0),
          isTrue,
        );
        final offline = SimilarArtistsRepository(
          cache: DiskMediaCache(root),
          client: MockClient(
            (_) async => throw StateError('No second network call'),
          ),
        );
        try {
          expect(
            (await offline.similarArtists(_seed)).map((artist) => artist.id),
            artists.map((artist) => artist.id),
          );
        } finally {
          offline.dispose();
        }
      } finally {
        repo.dispose();
        client.close();
      }
    },
    skip: Platform.environment['MUMPA_LIVE_SIMILAR_ARTISTS'] != '1',
  );
}

class _TrackingClient extends http.BaseClient {
  _TrackingClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);

  @override
  void close() => closed = true;
}
