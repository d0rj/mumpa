import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  test(
    'Jackett download redirect resolves magnet before calling the engine',
    () async {
      final service = IndexerService(
        client: MockClient(
          (request) async => http.Response(
            '',
            302,
            headers: {'location': 'magnet:?xt=urn:btih:abc&dn=Album'},
          ),
        ),
      );
      final source = await service.resolve(
        'http://localhost/download',
        Directory.systemTemp,
      );
      expect(source.file, isFalse);
      expect(source.source, 'magnet:?xt=urn:btih:abc&dn=Album');
      service.dispose();
    },
  );
  test('Jackett downloads metainfo and rejects an HTML response', () async {
    final root = await Directory.systemTemp.createTemp('mumpa-indexer-source-');
    var body = 'd4:name5:Albume';
    final service = IndexerService(
      client: MockClient((request) async => http.Response(body, 200)),
    );
    try {
      final source = await service.resolve('http://localhost/download', root);
      expect(source.file, isTrue);
      expect(await File(source.source).readAsString(), body);
      body = '<html>login</html>';
      await expectLater(
        service.resolve('http://localhost/download', root),
        throwsFormatException,
      );
    } finally {
      service.dispose();
      await root.delete(recursive: true);
    }
  });
  test(
    'Jackett connection verifies caps, rejects dashboard and API errors',
    () async {
      var body =
          '<caps><categories><category id="3000" name="Audio"/></categories></caps>';
      final service = IndexerService(
        client: MockClient((request) async {
          expect(request.url.queryParameters['t'], 'caps');
          return http.Response(body, 200);
        }),
      );
      await service.check('http://localhost/api', 'key');
      body = '<html>dashboard</html>';
      await expectLater(
        service.check('http://localhost/api', 'key'),
        throwsFormatException,
      );
      body = '<error description="Invalid key"/>';
      await expectLater(
        service.check('http://localhost/api', 'key'),
        throwsA(isA<HttpException>()),
      );
      service.dispose();
    },
  );
  test('waits for live files after a cold engine reload', () async {
    var gets = 0;
    final service = TorrentService(
      endpoint: () async => 'http://localhost',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'hash': 'abc',
            'name': 'Album',
            if (++gets > 1)
              'file_stats': [
                {'id': 1, 'path': 'song.flac', 'length': 20},
              ],
          }),
          200,
        ),
      ),
    );
    final uri = await service.resolve(
      const Track(
        id: 'one',
        title: 'Song',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.torrent,
        torrentHash: 'abc',
        torrentIndex: 1,
      ),
    );
    expect(gets, 2);
    expect(uri.queryParameters['link'], 'abc');
    service.dispose();
  });

  test('retains uploaded metainfo and recovers a reset server', () async {
    final root = await Directory.systemTemp.createTemp('mumpa-metainfo-');
    final source = await File(
      '${root.path}/picked.torrent',
    ).writeAsString('fixture');
    var exists = false, uploads = 0;
    final service = TorrentService(
      endpoint: () async => 'http://localhost',
      sources: Directory('${root.path}/sources'),
      client: MockClient((request) async {
        if (request.url.path == '/torrent/upload') {
          exists = true;
          uploads++;
          return http.Response('[{"hash":"abc"}]', 200);
        }
        if (!exists) return http.Response('missing', 404);
        return http.Response(
          jsonEncode({
            'hash': 'abc',
            'name': 'Album',
            'file_stats': [
              {'id': 1, 'path': 'song.flac', 'length': 20},
            ],
          }),
          200,
        );
      }),
    );
    try {
      await service.upload(source.path);
      await source.delete();
      exists = false;
      await service.resolve(
        const Track(
          id: 'one',
          title: 'Song',
          artist: 'Band',
          album: 'Album',
          source: TrackSource.torrent,
          torrentHash: 'abc',
          torrentIndex: 1,
        ),
      );
      expect(uploads, 2);
      expect(await service.sources!.list().length, 1);
    } finally {
      service.dispose();
      await root.delete(recursive: true);
    }
  });
  test(
    'uses sorted server file ids, filters audio, encodes stream params',
    () async {
      var gets = 0;
      final service = TorrentService(
        endpoint: () async => 'http://127.0.0.1:8090',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          if (body['action'] == 'add') {
            return http.Response(
              jsonEncode({'hash': 'abc', 'name': 'Album'}),
              200,
            );
          }
          gets++;
          return http.Response(
            jsonEncode({
              'hash': 'abc',
              'name': 'Album',
              'file_stats': [
                {'id': 7, 'path': 'Album/02 - Song.flac', 'length': 120},
                {'id': 3, 'path': 'Album/cover.jpg', 'length': 20},
              ],
            }),
            200,
          );
        }),
      );
      final info = await service.add('magnet:?xt=urn:btih:abc');
      final tracks = service.tracks(info);
      expect(gets, 1);
      expect(tracks.single.torrentIndex, 7);
      expect(tracks.single.title, 'Song');
      final uri = await service.stream('a+b&c', 7);
      expect(uri.queryParameters['link'], 'a+b&c');
      expect(uri.queryParameters['index'], '7');
      expect(uri.queryParameters.containsKey('play'), isTrue);
      service.dispose();
    },
  );
  test('rejects invalid input and propagates engine failures', () async {
    final service = TorrentService(
      endpoint: () async => 'http://localhost:8090',
      client: MockClient((_) async => http.Response('failure', 503)),
    );
    await expectLater(service.add('file:///music'), throwsFormatException);
    await expectLater(
      service.add('magnet:?xt=urn:btih:abc'),
      throwsA(predicate((e) => e.toString().contains('503'))),
    );
    service.dispose();
  });
  test('Torznab music search parses namespaced release attributes', () async {
    final indexer = IndexerService(
      client: MockClient((request) async {
        expect(request.url.queryParameters['cat'], '3000');
        expect(request.url.queryParameters['q'], 'Artist');
        return http.Response(
          '<rss xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel><item><title>Album</title><link>https://example.com/a.torrent</link><torznab:attr name="magneturl" value="magnet:?xt=urn:btih:abc"/><torznab:attr name="seeders" value="9"/><torznab:attr name="size" value="1234"/></item></channel></rss>',
          200,
        );
      }),
    );
    final items = await indexer.search('http://localhost/api', 'key', 'Artist');
    expect(items.single.seeders, 9);
    expect(items.single.bytes, 1234);
    expect(items.single.link, startsWith('magnet:'));
    indexer.dispose();
  });
}
