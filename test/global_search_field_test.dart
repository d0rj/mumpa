import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/rutracker_service.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/player.dart';

import 'support.dart';

const _query = 'Band A';
const _globalKey = ValueKey('music-search');
const _localKey = ValueKey('local-search-library');

http.Client _noHttp() => MockClient((_) async {
  throw StateError('This fixture must not make HTTP requests.');
});

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(
        cache: DiskMediaCache(Directory('${root.path}/metadata')),
        client: _noHttp(),
      );

  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
  @override
  Future<String?> coverForGroup(String id) async => null;
  @override
  Future<String?> coverForReleaseTitle(String title) async => null;
  @override
  Future<MusicArtist?> artist(
    String name, {
    SourceOperation? operation,
  }) async => null;
  @override
  Future<List<MusicRecording>> searchRecordings(
    String query, {
    SourceOperation? operation,
  }) async => const [];
  @override
  Future<List<String>> suggestArtistNames(
    String query, {
    SourceOperation? operation,
  }) async => const [];
}

class _IndexerRequests {
  final queries = <String>[];
  final responses = <Completer<http.Response>>[];

  late final client = MockClient((request) {
    queries.add(request.url.queryParameters['q']!);
    final response = Completer<http.Response>();
    responses.add(response);
    return response.future;
  });

  void complete(int index) => responses[index].complete(
    http.Response(
      '<rss><channel><item><title>Remote album</title>'
      '<link>https://example.invalid/album.torrent</link>'
      '</item></channel></rss>',
      200,
      headers: {'content-type': 'application/xml; charset=utf-8'},
    ),
  );

  void completePending() {
    for (var index = 0; index < responses.length; index++) {
      if (!responses[index].isCompleted) complete(index);
    }
  }
}

class _Fixture {
  _Fixture(this.root, this.app, this.requests);
  final Directory root;
  final AppController app;
  final _IndexerRequests requests;

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    requests.completePending();
    await tester.pump();
    await tester.runAsync(() async {
      await app.shutdown();
      app.library.dispose();
      await root.delete(recursive: true);
    });
  }
}

Future<_Fixture> _fixture(
  WidgetTester tester, {
  bool configured = true,
}) async => (await tester.runAsync(() async {
  final root = await Directory.systemTemp.createTemp('mumpa-global-search-');
  final library = LibraryRepository(root);
  await library.load();
  if (configured) {
    await library.setSetting('indexerUrl', 'http://localhost/torznab');
  }
  final file = await File('${root.path}/fixture.mp3').writeAsBytes([0]);
  await library.upsert([
    Track(
      id: 'local-song',
      title: 'Library song',
      artist: _query,
      album: 'Album A',
      source: TrackSource.local,
      localPath: file.path,
    ),
  ]);
  final torrents = TorrentService(
    endpoint: () async => throw StateError('No torrent engine expected.'),
    client: _noHttp(),
    audioClientFactory: _noHttp,
  );
  final playback = PlaybackController(
    library: library,
    torrents: torrents,
    backend: FakeAudioBackend(),
  );
  await playback.initialize(platformAudio: false);
  final requests = _IndexerRequests();
  final app = AppController(
    library: library,
    playback: playback,
    downloads: DownloadRepository(library, torrents),
    torrents: torrents,
    engine: TorrentEngine(root),
    indexer: IndexerService(client: requests.client),
    catalog: RuTrackerService(
      transport: HttpCatalogTransport(client: _noHttp()),
    ),
    metadata: _Metadata(root),
  );
  app.navigate(AppPage.library);
  return _Fixture(root, app, requests);
}))!;

void _viewport(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

TextFormField _field(WidgetTester tester) =>
    tester.widget<TextFormField>(find.byKey(_globalKey));

TextField _input(WidgetTester tester) => tester.widget<TextField>(
  find.descendant(of: find.byKey(_globalKey), matching: find.byType(TextField)),
);

Future<void> _ctrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Manrope',
    )..addFont(rootBundle.load('assets/fonts/Manrope.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final width in [320.0, 1200.0]) {
    testWidgets('global field retains focus and editing state at $width', (
      tester,
    ) async {
      _viewport(tester, width);
      final fixture = await _fixture(tester);
      try {
        await tester.pumpWidget(MumpaApp(controller: fixture.app));
        await tester.pumpAndSettle();
        final controller = _field(tester).controller!;
        final focus = _input(tester).focusNode!;
        final element = tester.element(find.byKey(_globalKey));
        await tester.tap(find.byKey(_globalKey));
        await tester.pump();
        expect(fixture.app.page, AppPage.library);
        expect(focus.hasFocus, isTrue);
        expect(fixture.requests.queries, isEmpty);

        await tester.tap(find.byKey(_localKey));
        await tester.pump();
        expect(focus.hasFocus, isFalse);
        await _ctrlK(tester);
        expect(fixture.app.page, AppPage.library);
        expect(focus.hasFocus, isTrue);
        expect(fixture.requests.queries, isEmpty);

        await tester.enterText(find.byKey(_globalKey), _query);
        await tester.pump();
        expect(fixture.app.page, AppPage.search);
        expect(find.byKey(_globalKey), findsOneWidget);
        expect(find.byType(TextFormField), findsOneWidget);
        expect(_field(tester).controller, same(controller));
        expect(_input(tester).focusNode, same(focus));
        expect(tester.element(find.byKey(_globalKey)), same(element));
        expect(focus.hasFocus, isTrue);
        const editing = TextEditingValue(
          text: _query,
          selection: TextSelection(baseOffset: 1, extentOffset: 4),
          composing: TextRange(start: 1, end: 4),
        );
        tester.testTextInput.updateEditingValue(editing);
        await tester.pump();
        fixture.app.setSort(LibrarySort.artist);
        fixture.app.setLocalQuery('liked', 'independent local query');
        await tester.pump();
        expect(controller.value, editing);
        expect(_field(tester).controller, same(controller));
        expect(focus.hasFocus, isTrue);
        expect(fixture.requests.queries, isEmpty);
        tester.view.physicalSize = Size(width == 320 ? 1200 : 320, 1000);
        await tester.pump();
        expect(_field(tester).controller, same(controller));
        expect(_input(tester).focusNode, same(focus));
        expect(controller.value, editing);
        expect(focus.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    });

    testWidgets('Enter submits once before debounce at $width', (tester) async {
      _viewport(tester, width);
      final fixture = await _fixture(tester);
      try {
        await tester.pumpWidget(MumpaApp(controller: fixture.app));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(_globalKey), _query);
        await tester.pump(const Duration(milliseconds: 500));
        expect(fixture.requests.queries, isEmpty);
        await _submit(tester);
        expect(fixture.requests.queries, [_query]);
        expect(fixture.app.page, AppPage.search);
        expect(_input(tester).focusNode!.hasFocus, isFalse);
        await tester.pump(const Duration(milliseconds: 700));
        expect(fixture.requests.queries, [_query]);
        fixture.requests.complete(0);
        await tester.pumpAndSettle();
        expect(fixture.app.searchCompleted, isTrue);
        expect(fixture.app.releases.single.title, 'Remote album');
        expect(fixture.requests.queries, [_query]);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    });

    testWidgets(
      'Back ignores a late response and retains local query at $width',
      (tester) async {
        _viewport(tester, width);
        final fixture = await _fixture(tester);
        try {
          await tester.pumpWidget(MumpaApp(controller: fixture.app));
          await tester.pumpAndSettle();
          await tester.enterText(find.byKey(_localKey), 'Album A');
          await tester.pump();
          expect(fixture.app.localQuery('library'), 'Album A');
          expect(fixture.app.query, isEmpty);
          final controller = _field(tester).controller!;
          await tester.enterText(find.byKey(_globalKey), _query);
          await _submit(tester);
          expect(fixture.requests.queries, [_query]);
          expect(fixture.app.searching, isTrue);
          await tester.tap(find.byKey(const ValueKey('navigation-back')));
          await tester.pump();
          expect(fixture.app.page, AppPage.library);
          expect(fixture.app.query, isEmpty);
          expect(controller.text, isEmpty);
          expect(fixture.app.localQuery('library'), 'Album A');
          expect(
            tester.widget<TextField>(find.byKey(_localKey)).controller!.text,
            'Album A',
          );
          fixture.requests.complete(0);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 700));
          expect(fixture.app.page, AppPage.library);
          expect(fixture.app.searching, isFalse);
          expect(fixture.app.releases, isEmpty);
          expect(fixture.app.query, isEmpty);
          expect(_field(tester).controller, same(controller));
          expect(fixture.requests.queries, [_query]);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );

    testWidgets('empty Enter and missing Jackett stay on page at $width', (
      tester,
    ) async {
      _viewport(tester, width);
      final fixture = await _fixture(tester, configured: false);
      try {
        // An explicitly selected custom source still requires its endpoint.
        // Fresh installs now use the ready public catalogue instead.
        await tester.runAsync(
          () => fixture.app.library.setSetting('searchProvider', 'torznab'),
        );
        await tester.pumpWidget(MumpaApp(controller: fixture.app));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(_globalKey));
        await _submit(tester);
        expect(fixture.app.page, AppPage.library);
        expect(fixture.requests.queries, isEmpty);
        await tester.tap(find.byKey(_globalKey));
        await tester.pump();
        await tester.enterText(find.byKey(_globalKey), _query);
        await tester.pump(const Duration(milliseconds: 650));
        expect(fixture.app.page, AppPage.search);
        expect(fixture.requests.queries, isEmpty);
        await _submit(tester);
        expect(fixture.app.page, AppPage.search);
        expect(find.byKey(const ValueKey('settings')), findsNothing);
        expect(fixture.app.query, _query);
        expect(fixture.app.searching, isFalse);
        expect(fixture.app.searchCompleted, isTrue);
        expect(fixture.app.message, isNotNull);
        expect(fixture.requests.queries, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    });
  }

  for (final width in [800.0, 1280.0]) {
    for (final local in [false, true]) {
      testWidgets(
        'tablet search stays dismissed across routes and rebuilds ($width, local=$local)',
        (tester) async {
          _viewport(tester, width);
          final fixture = await _fixture(tester);
          try {
            final app = fixture.app;
            await tester.pumpWidget(MumpaApp(controller: app));
            await tester.pumpAndSettle();
            final field = find.byKey(local ? _localKey : _globalKey);
            TextField input() =>
                local ? tester.widget<TextField>(field) : _input(tester);
            await tester.tap(field);
            await tester.enterText(field, _query);
            await tester.pump();
            await tester.testTextInput.receiveAction(TextInputAction.search);
            await tester.pump();
            if (!local) {
              fixture.requests.complete(0);
              await tester.pumpAndSettle();
            }
            final node = input().focusNode!;
            expect(node.hasFocus, isFalse);
            expect(tester.testTextInput.isVisible, isFalse);
            await tester.tap(field);
            await tester.pump();
            expect(node.hasFocus, isTrue);
            unawaited(
              showDialog<void>(
                context: tester.element(field),
                builder: (context) => AlertDialog(
                  title: const Text('Проверка возврата фокуса'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Закрыть окно'),
                    ),
                  ],
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(node.hasFocus, isFalse);
            app.setSort(LibrarySort.artist);
            app.setLocalQuery('liked', 'background update');
            await tester.pump();
            await tester.tap(find.text('Закрыть окно'));
            await tester.pumpAndSettle();
            expect(
              node.hasFocus,
              isFalse,
              reason: 'A route must not restore the remembered search',
            );
            expect(tester.testTextInput.isVisible, isFalse);
            expect(input().controller!.text, _query);
            await tester.tap(field);
            await tester.pump();
            unawaited(showNowPlaying(tester.element(field), app));
            await tester.pumpAndSettle();
            await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
            await tester.pumpAndSettle();
            expect(node.hasFocus, isFalse);
            expect(tester.testTextInput.isVisible, isFalse);
            tester.view.physicalSize = Size(width == 800 ? 1280 : 800, 1000);
            await tester.pumpAndSettle();
            expect(node.hasFocus, isFalse);
            expect(tester.testTextInput.isVisible, isFalse);
            await tester.tap(
              find.byKey(
                local
                    ? const ValueKey('local-search-library-clear')
                    : const ValueKey('global-search-clear'),
              ),
            );
            await tester.pumpAndSettle();
            expect(input().controller!.text, isEmpty);
            expect(
              node.hasFocus,
              isFalse,
              reason: 'Clearing a blurred field must not reopen the keyboard',
            );
            await tester.tap(field);
            await tester.pump();
            expect(node.hasFocus, isTrue);
            expect(tester.testTextInput.isVisible, isTrue);
            expect(tester.takeException(), isNull);
          } finally {
            await fixture.close(tester);
          }
        },
      );
    }
  }
}
