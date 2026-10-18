import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/public_music_catalog.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';

void main() {
  const hash = '0123456789012345678901234567890123456789';
  Map<String, dynamic> hit({
    String? name,
    List<int>? categories,
    String? magnet,
  }) => {
    'title': name ?? 'Исполнитель — Альбом',
    'categoryId': categories ?? [1000000, 1001000],
    'hash': hash,
    'magnetUrl': magnet,
    'seeders': 7,
    'bytes': 123456,
    'tracker': 'Example',
    'details': 'https://example.org/album',
  };

  test(
    'automatic source needs no key, sends only music categories and preserves Cyrillic',
    () async {
      final client = MockClient((request) async {
        if (request.url.host == 'rutor.info') {
          expect(request.method, 'GET');
          expect(request.url.pathSegments, contains('Кино'));
          expect(request.headers, isNot(contains('authorization')));
          expect(request.url.queryParameters, isNot(contains('apikey')));
          return http.Response('<div id="index"></div>', 200);
        }
        expect(request.method, 'POST');
        expect(request.url.toString(), PublicMusicCatalog.endpoint);
        expect(request.headers, isNot(contains('authorization')));
        final body = jsonDecode(request.body) as Map;
        expect(body['query'], 'Кино');
        expect(body['categories'], [1001000, 1002000]);
        expect(body['hide_xxx'], isTrue);
        expect(body['hide_unsafe'], isTrue);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'hits': [hit()],
            }),
          ),
          200,
        );
      });
      final indexer = IndexerService(client: client);
      final result = await indexer.search(
        PublicMusicCatalog.endpoint,
        'never-forward-me',
        'Кино',
      );
      expect(result.single.title, 'Исполнитель — Альбом');
      expect(result.single.link, startsWith('magnet:'));
      expect(result.single.rutracker, isFalse);
      final temp = await Directory.systemTemp.createTemp('mumpa-public-');
      try {
        expect((await indexer.resolve(result.single.link, temp)).file, isFalse);
      } finally {
        await temp.delete();
        client.close();
      }
    },
  );

  test('rejects nonmusic, unsafe links and deduplicates content hashes', () {
    final result = PublicMusicCatalog.parse({
      'hits': [
        hit(),
        hit(name: 'duplicate'),
        hit(categories: [2000000]),
        {...hit(), 'hash': null, 'magnetUrl': 'https://bad.example/file.exe'},
        {...hit(), 'hash': null, 'magnetUrl': 'magnet:?xt=not-a-hash'},
      ],
    });
    expect(result.length, 1);
    expect(result.single.bytes, 123456);
  });

  test(
    'empty strict search retries music with an explicit zero risk score',
    () async {
      final filters = <bool>[];
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        filters.add(body['hide_unsafe'] as bool);
        expect(body['query'], 'Ежемесячные');
        expect(body['categories'], [1001000, 1002000]);
        expect(body['hide_xxx'], isTrue);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'hits': body['hide_unsafe'] == true
                  ? []
                  : [
                      {
                        ...hit(name: 'Ежемесячные — Альбом'),
                        'virusDetection': 0.0,
                      },
                      {
                        ...hit(),
                        'hash': '1111111111111111111111111111111111111111',
                        'virusDetection': 0.1,
                      },
                      {
                        ...hit(),
                        'hash': '2222222222222222222222222222222222222222',
                      },
                      {
                        ...hit(categories: [2000000]),
                        'virusDetection': 0,
                      },
                    ],
            }),
          ),
          200,
        );
      });
      try {
        final result = await PublicMusicCatalog.search(client, 'Ежемесячные');
        expect(filters, [true, false]);
        expect(result.single.title, 'Ежемесячные — Альбом');
      } finally {
        client.close();
      }
    },
  );

  test('fresh empty feed does not run a broad second lookup', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect((jsonDecode(request.body) as Map)['hide_unsafe'], isTrue);
      return http.Response('{"hits":[]}', 200);
    });
    try {
      expect(await PublicMusicCatalog.search(client, ''), isEmpty);
      expect(requests, 1);
    } finally {
      client.close();
    }
  });

  test('cancelled searches and rate limits have bounded failures', () async {
    final client = MockClient((_) async => http.Response('wait', 429));
    final operation = SourceOperation()..cancel();
    await expectLater(
      PublicMusicCatalog.search(client, '', operation: operation),
      throwsA(isA<SourceCancelled>()),
    );
    await expectLater(
      PublicMusicCatalog.search(client, ''),
      throwsA(
        isA<HttpException>().having(
          (e) => e.message,
          'message',
          contains('ограничил'),
        ),
      ),
    );
    client.close();
  });
}
