import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/public_music_catalog.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'support.dart';

void main() {
  late Directory root;
  late AppController app;
  final requests = <http.Request>[];
  Completer<http.Response>? oldFeed;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-automatic-');
    final library = LibraryRepository(root);
    await library.load();
    final torrents = TorrentService(
      endpoint: () async => throw StateError('Unexpected engine start'),
    );
    final player = PlaybackController(
      library: library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    await player.initialize(platformAudio: false);
    requests.clear();
    oldFeed = null;
    app = AppController(
      library: library,
      playback: player,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
      indexer: IndexerService(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'rutor.info') {
            return http.Response('<div id="index"></div>', 200);
          }
          if (request.url.toString() == PublicMusicCatalog.endpoint) {
            return http.Response(
              jsonEncode({
                'hits': [
                  {
                    'title': 'Artist — Ready',
                    'categoryId': [1001000],
                    'seeders': 3,
                    'hash': '0123456789012345678901234567890123456789',
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.url.queryParameters['t'] == 'indexers') {
            return http.Response('<indexers/>', 200);
          }
          if (oldFeed != null) return oldFeed!.future;
          return http.Response('<rss><channel/></rss>', 200);
        }),
      ),
    );
  });
  tearDown(() async {
    await app.shutdown();
    app.library.dispose();
    await root.delete(recursive: true);
  });

  test(
    'fresh profile has a feed and searches without starting helpers or saving keys',
    () async {
      expect(app.usesAutomaticSource, isTrue);
      await app.initializeSources();
      expect(app.indexerError, isNull);
      expect(app.sourceFeed.single.title, 'Artist — Ready');
      app.query = 'Artist';
      await app.searchSources();
      expect(app.releases.single.title, 'Artist — Ready');
      expect(
        requests
            .where((r) => r.url.host == 'api.knaben.org')
            .every((r) => r.method == 'POST'),
        isTrue,
      );
      expect(
        requests.any((r) => r.url.host == 'rutor.info' && r.method == 'GET'),
        isTrue,
      );
      expect(
        requests.every(
          (r) =>
              !r.url.queryParameters.containsKey('apikey') &&
              !r.headers.containsKey('authorization'),
        ),
        isTrue,
      );
      expect(app.library.settings.containsKey('indexerKey'), isFalse);
      expect(app.jackettConnection, isNull);
      expect(await Directory('${root.path}/jackett').exists(), isFalse);
    },
  );

  test(
    'automatic choice preserves custom server settings and rejects stale feed',
    () async {
      await app.library.setSetting('indexerUrl', 'https://custom.example/api');
      await app.library.setSetting('indexerKey', 'keep-local');
      expect(app.searchProvider, 'torznab');
      oldFeed = Completer<http.Response>();
      final pending = app.refreshSourceFeed();
      while (requests.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      await app.setSearchProvider('automatic');
      expect(app.indexerError, isNull);
      expect(app.sourceFeed.single.title, 'Artist — Ready');
      oldFeed!.complete(http.Response('<rss><channel/></rss>', 200));
      await pending;
      expect(app.sourceFeed.single.title, 'Artist — Ready');
      expect(app.library.settings['indexerKey'], 'keep-local');
      expect(app.library.settings['indexerUrl'], 'https://custom.example/api');
      expect(app.indexerLoading, isFalse);
      final restored = LibraryRepository(root);
      await restored.load();
      expect(restored.settings['searchProvider'], 'automatic');
      restored.dispose();
    },
  );
}
