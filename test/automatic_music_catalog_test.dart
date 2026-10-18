import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/automatic_music_catalog.dart';
import 'package:mumpa/data/rutor_music_catalog.dart';
import 'package:mumpa/data/source_operation.dart';

const hash = '0123456789012345678901234567890123456789';
const rutor =
    '''<html><div id="index"><table><tr><td>date</td><td>
<a class="downgif" href="//d.rutor.info/download/123"></a>
<a href="magnet:?xt=urn:btih:$hash&amp;dn=test"></a>
<a href="/torrent/123/test">Кино — Альбом (2026) FLAC</a></td>
<td>1,50&nbsp;GB</td><td><span class="green">&nbsp;12</span></td>
</tr></table></div></html>''';

void main() {
  test(
    'public music page parses a validated magnet, size and metainfo URL',
    () {
      final item = RutorMusicCatalog.parse(
        rutor,
        Uri.parse('https://rutor.info'),
      ).single;
      expect(item.title, 'Кино — Альбом (2026) FLAC');
      expect(item.bytes, (1.5 * 1024 * 1024 * 1024).round());
      expect(item.seeders, 12);
      expect(item.seedersKnown, isTrue);
      expect(item.link, 'https://d.rutor.info/download/123');
      expect(item.magnetLink, contains(hash));
      expect(item.detailsUrl, 'https://rutor.info/torrent/123/test');
    },
  );

  test(
    'untrusted downloads fall back to magnet and invalid hashes are rejected',
    () {
      final page = rutor.replaceAll(
        '//d.rutor.info/download/123',
        'https://bad.example/file.exe',
      );
      expect(
        RutorMusicCatalog.parse(
          page,
          Uri.parse('https://rutor.info'),
        ).single.link,
        startsWith('magnet:'),
      );
      expect(
        RutorMusicCatalog.parse(
          rutor.replaceAll(hash, 'bad'),
          Uri.parse('https://rutor.info'),
        ),
        isEmpty,
      );
      expect(
        () => RutorMusicCatalog.parse(
          '<html>challenge</html>',
          Uri.parse('https://rutor.info'),
        ),
        throwsFormatException,
      );
    },
  );

  test('music-category concert videos are not offered as audio albums', () {
    final video = rutor.replaceAll(
      'Кино — Альбом (2026) FLAC',
      'Кино — Концерт (2026) WEBRip 1080p',
    );
    expect(
      RutorMusicCatalog.parse(video, Uri.parse('https://rutor.info')),
      isEmpty,
    );
  });

  test(
    'Russian MP3 lettering is accepted without matching inside other words',
    () {
      final russian = rutor.replaceAll('FLAC', 'МР3');
      expect(
        RutorMusicCatalog.parse(russian, Uri.parse('https://rutor.info')),
        hasLength(1),
      );
      final unrelated = rutor.replaceAll('FLAC', 'notmp3');
      expect(
        RutorMusicCatalog.parse(unrelated, Uri.parse('https://rutor.info')),
        isEmpty,
      );
    },
  );

  test(
    'request preserves Russian, uses only music, and switches mirror on failure',
    () async {
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        expect(request.method, 'GET');
        expect(request.url.pathSegments, [
          'search',
          '0',
          '2',
          '100',
          '2',
          'Кино / альбом',
          '',
        ]);
        expect(request.url.queryParameters, isEmpty);
        return request.url.host == 'rutor.info'
            ? http.Response('unavailable', 503)
            : http.Response.bytes(utf8.encode(rutor), 200);
      });
      try {
        expect(
          (await RutorMusicCatalog.search(
            client,
            'Кино / альбом',
          )).single.indexerName,
          'RuTor',
        );
        expect(hosts, ['rutor.info', 'rutor.is']);
      } finally {
        client.close();
      }
    },
  );

  test(
    'aggregation deduplicates infohash and prefers direct torrent metainfo',
    () async {
      final client = MockClient(
        (request) async => request.url.host == 'api.knaben.org'
            ? http.Response(
                jsonEncode({
                  'hits': [
                    {
                      'title': 'Knaben duplicate',
                      'hash': hash,
                      'categoryId': [1001000],
                      'seeders': 15,
                    },
                  ],
                }),
                200,
              )
            : http.Response.bytes(utf8.encode(rutor), 200),
      );
      try {
        final found = await AutomaticMusicCatalog.search(client, 'Кино');
        expect(found.single.link, 'https://d.rutor.info/download/123');
      } finally {
        client.close();
      }
    },
  );

  test(
    'healthy Russian source remains usable when the other catalog fails',
    () async {
      final client = MockClient(
        (request) async => request.url.host == 'api.knaben.org'
            ? http.Response('unavailable', 503)
            : http.Response.bytes(utf8.encode(rutor), 200),
      );
      try {
        expect(
          (await AutomaticMusicCatalog.search(
            client,
            'Кино',
          )).single.indexerName,
          'RuTor',
        );
      } finally {
        client.close();
      }
    },
  );

  test(
    'unavailable catalogs do not silently report a missing artist',
    () async {
      final client = MockClient(
        (request) async => request.url.host == 'api.knaben.org'
            ? http.Response('{"hits":[]}', 200)
            : http.Response('unavailable', 503),
      );
      try {
        await expectLater(
          AutomaticMusicCatalog.search(client, 'Запрос'),
          throwsA(isA<HttpException>()),
        );
      } finally {
        client.close();
      }
    },
  );

  test('cancellation interrupts both pending source lookups', () async {
    final operation = SourceOperation();
    final pending = Completer<http.Response>();
    final client = MockClient((_) => pending.future);
    try {
      final search = AutomaticMusicCatalog.search(
        client,
        'Кино',
        operation: operation,
      );
      operation.cancel();
      await expectLater(search, throwsA(isA<SourceCancelled>()));
    } finally {
      pending.complete(http.Response('{"hits":[]}', 200));
      client.close();
    }
  });
}
