import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'support.dart';

void main() {
  late Directory root;
  late AppController app;
  late IndexerService indexer;
  final queries = <String>[];
  final responses = <String, Completer<http.Response>>{};
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-source-flow-');
    final library = LibraryRepository(root);
    await library.load();
    await library.setSetting('indexerUrl', 'http://localhost/api');
    queries.clear();
    responses.clear();
    indexer = IndexerService(
      client: MockClient((request) async {
        final query = request.url.queryParameters['q'] ?? '';
        queries.add(query);
        return (responses[query] ??= Completer<http.Response>()).future;
      }),
    );
    final torrents = TorrentService(endpoint: () async => 'http://localhost:1');
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    await playback.initialize(platformAudio: false);
    app = AppController(
      library: library,
      playback: playback,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
      indexer: indexer,
    );
  });
  tearDown(() async {
    app.dispose();
    app.downloads.dispose();
    await app.playback.close();
    app.torrents.dispose();
    await app.library.flush();
    app.library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('typing searches remotely and discards obsolete responses', (
    tester,
  ) async {
    app.navigate(AppPage.search);
    await tester.pumpWidget(MumpaApp(controller: app));
    await tester.enterText(find.byKey(const ValueKey('music-search')), 'Еже');
    await tester.pump(const Duration(milliseconds: 500));
    expect(queries, isEmpty);
    expect(app.searching, isTrue);
    expect(app.searchCompleted, isFalse);
    await tester.pump(const Duration(milliseconds: 120));
    expect(queries, ['Еже']);
    await tester.enterText(
      find.byKey(const ValueKey('music-search')),
      'Ежемесячные',
    );
    await tester.pump(const Duration(milliseconds: 610));
    expect(queries, ['Еже', 'Ежемесячные']);
    responses['Ежемесячные']!.complete(
      http.Response(
        '<rss><channel><item><title>Новый альбом</title><link>https://example.com/new.torrent</link></item></channel></rss>',
        200,
        headers: {'content-type': 'application/xml; charset=utf-8'},
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(app.releases.single.title, 'Новый альбом');
    responses['Еже']!.complete(http.Response('<rss><channel/></rss>', 200));
    await tester.pump();
    expect(app.releases.single.title, 'Новый альбом');
    expect(app.searchCompleted, isTrue);
    expect(app.searching, isFalse);
  });

  test(
    'cancelling an album request clears busy and rejects late results',
    () async {
      final pending = app.inspectRelease(
        const SearchRelease(
          title: 'Album',
          link: 'https://example.com/album.torrent',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(app.busy, isNotNull);
      app.cancelOpening();
      expect(await pending.timeout(const Duration(seconds: 1)), isNull);
      expect(app.busy, isNull);
      expect(app.canCancelOpening, isFalse);
      expect(app.error, isNull);
      expect(app.message, contains('отменено'));
      responses['']!.complete(http.Response('<html>late failure</html>', 200));
      await Future<void>.delayed(Duration.zero);
      expect(app.library.tracks, isEmpty);
      expect(app.error, isNull);
    },
  );

  test(
    'metadata wait is bounded and can be cancelled during an unresponsive get',
    () async {
      final source = SourceOperation();
      final requested = Completer<void>();
      final stalled = Completer<http.Response>();
      final torrents = TorrentService(
        endpoint: () async => 'http://localhost',
        client: MockClient((request) async {
          if ((jsonDecode(request.body) as Map)['action'] == 'add') {
            return http.Response('{"hash":"abc"}', 200);
          }
          requested.complete();
          return stalled.future;
        }),
      );
      final pending = torrents.add(
        'magnet:?xt=urn:btih:abc',
        operation: source,
      );
      await requested.future;
      source.cancel();
      await expectLater(pending, throwsA(isA<SourceCancelled>()));
      stalled.complete(http.Response('{"hash":"abc"}', 200));
      torrents.dispose();
      final bounded = TorrentService(
        endpoint: () async => 'http://localhost',
        metadataTimeout: const Duration(milliseconds: 5),
        client: MockClient((_) async => http.Response('{"hash":"abc"}', 200)),
      );
      await expectLater(
        bounded.add('magnet:?xt=urn:btih:abc'),
        throwsA(isA<HttpException>()),
      );
      bounded.dispose();
    },
  );
}
