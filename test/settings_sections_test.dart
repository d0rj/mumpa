import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/data/windows_player_service.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/pages.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

class _SettingsApp extends AppController {
  _SettingsApp({
    required super.library,
    required super.playback,
    required super.downloads,
    required super.torrents,
    required super.engine,
    required super.metadata,
    required super.indexer,
  });

  int cacheReads = 0, networkReads = 0;

  @override
  Future<void> refreshMetadataCache() async {
    cacheReads++;
  }

  @override
  Future<void> refreshTorrentNetworks() async {
    networkReads++;
  }

  void unrelatedNotification() => notifyListeners();
}

class _Fixture {
  _Fixture(this.root, this.app);
  final Directory root;
  final _SettingsApp app;
  int httpRequests = 0, engineStarts = 0;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('mumpa-settings-ui-');
    final library = LibraryRepository(root);
    await library.load();
    await library.setSetting('indexerUrl', 'http://library.example');
    await library.setSetting('serverUrl', 'http://torrent.example');
    await library.setSetting('torrentInterface', 'Wi-Fi');
    late _Fixture fixture;
    final offline = MockClient((_) async {
      fixture.httpRequests++;
      throw StateError('Changing settings sections must not send HTTP');
    });
    final torrents = TorrentService(
      client: offline,
      endpoint: () async {
        fixture.engineStarts++;
        throw StateError('Changing settings sections must not start torrents');
      },
    );
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    await playback.initialize(platformAudio: false);
    final app = _SettingsApp(
      library: library,
      playback: playback,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
      metadata: MusicMetadataRepository(
        cache: DiskMediaCache(Directory('${root.path}/metadata')),
        client: offline,
      ),
      indexer: IndexerService(client: offline),
    );
    // Include the Windows category without invoking any native plugin.
    app.windowsPlayer = WindowsPlayerService(
      playback: playback,
      onQuit: () async {},
      enabled: false,
    );
    fixture = _Fixture(root, app);
    app.navigate(AppPage.settings);
    return fixture;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await app.shutdown();
      app.library.dispose();
      await root.delete(recursive: true);
    });
  }
}

Future<_Fixture> _fixture(WidgetTester tester) async =>
    (await tester.runAsync(_Fixture.create))!;

Future<void> _mount(WidgetTester tester, _SettingsApp app, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: mumpaTheme(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: app,
          builder: (_, _) => ContentPage(app: app),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _sectionIds = [
  'sources',
  'torrent',
  'downloads',
  'metadata',
  'windowsPlayer',
  'about',
];

void main() {
  testWidgets('overview builds no settings forms and does not scan anything', (
    tester,
  ) async {
    final fixture = await _fixture(tester);
    addTearDown(() => fixture.close(tester));
    await _mount(tester, fixture.app, const Size(1200, 850));

    for (final id in _sectionIds) {
      expect(find.byKey(ValueKey('settings-section-$id')), findsOneWidget);
    }
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('clear-metadata-cache')), findsNothing);
    expect(fixture.app.cacheReads, 0);
    expect(fixture.app.networkReads, 0);
    expect(fixture.httpRequests, 0);
    expect(fixture.engineStarts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop sections are lazy and drafts survive back navigation', (
    tester,
  ) async {
    final fixture = await _fixture(tester);
    addTearDown(() => fixture.close(tester));
    final app = fixture.app;
    await _mount(tester, app, const Size(1200, 850));
    await tester.tap(find.byKey(const ValueKey('settings-section-sources')));
    await tester.pumpAndSettle();

    expect(app.settingsSection, 'sources');
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.byKey(const ValueKey('clear-metadata-cache')), findsNothing);
    expect(fixture.app.cacheReads, 0);
    expect(fixture.app.networkReads, 0);
    final sourceField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Адрес Jackett или URL Torznab API',
    );
    await tester.enterText(sourceField, 'http://draft.example');
    await tester.tap(find.byKey(const ValueKey('settings-nav-metadata')));
    await tester.pumpAndSettle();

    expect(app.settingsSection, 'metadata');
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('clear-metadata-cache')), findsOneWidget);
    expect(app.cacheReads, 1);
    app.unrelatedNotification();
    app.unrelatedNotification();
    await tester.pumpAndSettle();
    expect(app.cacheReads, 1, reason: 'Player notifications must not rescan');
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();
    expect(app.settingsSection, 'sources');
    expect(
      tester.widget<TextField>(sourceField).controller!.text,
      'http://draft.example',
    );
    await tester.tap(find.byKey(const ValueKey('settings-nav-metadata')));
    await tester.pumpAndSettle();
    expect(app.cacheReads, 2, reason: 'Reentering cache refreshes its size');
    app.back();
    await tester.pumpAndSettle();
    expect(app.library.settings['indexerUrl'], 'http://library.example');
    expect(app.library.settings['torrentInterface'], 'Wi-Fi');
    expect(fixture.httpRequests, 0);
    expect(fixture.engineStarts, 0);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 568), const Size(1200, 850)]) {
    testWidgets(
      'all sections fit $size and back restores the selected section',
      (tester) async {
        final fixture = await _fixture(tester);
        addTearDown(() => fixture.close(tester));
        final app = fixture.app;
        await _mount(tester, app, size);
        for (final id in _sectionIds) {
          app.setSettingsSection(id);
          await tester.pumpAndSettle();
          expect(app.settingsSection, id);
          expect(tester.takeException(), isNull, reason: '$id at $size');
          expect(find.byKey(const ValueKey('settings-back')), findsOneWidget);
        }

        app.navigate(AppPage.library);
        await tester.pumpAndSettle();
        app.back();
        await tester.pumpAndSettle();
        expect(app.page, AppPage.settings);
        expect(app.settingsSection, 'about');
        expect(find.text('Лицензии компонентов'), findsOneWidget);
        expect(fixture.httpRequests, 0);
        expect(fixture.engineStarts, 0);
        expect(app.library.settings['torrentInterface'], 'Wi-Fi');

        app.navigate(AppPage.library);
        app.navigate(AppPage.settings);
        await tester.pumpAndSettle();
        expect(app.settingsSection, isNull);
        expect(find.byType(TextField), findsNothing);
        expect(
          find.byKey(const ValueKey('settings-section-sources')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('download settings remain usable inside their own subpage', (
    tester,
  ) async {
    final fixture = await _fixture(tester);
    addTearDown(() => fixture.close(tester));
    final app = fixture.app;
    await _mount(tester, app, const Size(1200, 850));
    app.setSettingsSection('downloads');
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.text('Лимит офлайн-загрузок, МБ'), findsOneWidget);
    expect(find.byKey(const ValueKey('clear-metadata-cache')), findsNothing);
    final dropdown = tester.widget<DropdownButtonFormField<int>>(
      find.byType(DropdownButtonFormField<int>),
    );
    // This callback performs disk I/O. Start it in the real async zone so
    // filesystem completions are not stranded in the widget fake clock.
    await tester.runAsync(() async {
      dropdown.onChanged!(6);
      await app.library.flush();
      while (app.busy != null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(app.downloads.maxConcurrentDownloads, 6);
    expect(app.library.settings['downloadConcurrency'], 6);
    expect(app.cacheReads, 0);
    expect(app.networkReads, 0);
    expect(fixture.httpRequests, 0);
    expect(fixture.engineStarts, 0);
    expect(tester.takeException(), isNull);
  });
}
