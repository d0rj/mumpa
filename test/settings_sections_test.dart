import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/profile_transfer.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/data/windows_player_service.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/pages.dart';
import 'package:mumpa/ui/app_screen.dart';
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
  ProfileTransfer? transferToPick;
  bool mockProfilePicker = false;

  @override
  Future<ProfileTransfer?> pickProfile() =>
      mockProfilePicker ? Future.value(transferToPick) : super.pickProfile();

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

final class _ProfileFile extends PlatformFile {
  _ProfileFile(this.data);
  final Uint8List data;
  @override
  String get name => 'mumpa-profile.json';
  @override
  Uri get uri => Uri.parse('content://documents/profile');
  @override
  Future<int?> length() async => null;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(data);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProfilePicker extends FilePickerPlatform {
  Uint8List? saved;
  PlatformFile? selected;
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    saved = bytes;
    return Uri.parse('content://documents/saved');
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => selected;
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
  'playback',
  'language',
  'sources',
  'torrent',
  'downloads',
  'metadata',
  'profile',
  'windowsPlayer',
  'about',
];

void main() {
  for (final size in [const Size(320, 568), const Size(1200, 850)]) {
    testWidgets(
      'audio controls and immediate English switch persist at $size',
      (tester) async {
        final fixture = await _fixture(tester);
        addTearDown(() => fixture.close(tester));
        final app = fixture.app;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(MumpaApp(controller: app));
        app.setSettingsSection('playback');
        await tester.pumpAndSettle();
        Slider band() => tester.widget<Slider>(
          find.byKey(const ValueKey('equalizer-band-0')),
        );
        expect(band().onChanged, isNull);
        await tester.runAsync(() async {
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('equalizer-enabled')),
              )
              .onChanged!(true);
          await app.library.flush();
        });
        await tester.pumpAndSettle();
        expect(band().onChanged, isNotNull);
        await tester.runAsync(() async {
          band().onChanged!(6);
          await app.library.flush();
        });
        await tester.pumpAndSettle();
        expect(band().value, 6);
        await tester.runAsync(() async {
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('equalizer-enabled')),
              )
              .onChanged!(false);
          tester
              .widget<SwitchListTile>(find.byKey(const ValueKey('mono-audio')))
              .onChanged!(true);
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('normalize-volume')),
              )
              .onChanged!(true);
          await app.library.flush();
        });
        await tester.pumpAndSettle();
        expect(band().onChanged, isNull);
        expect(band().value, 6);
        app.setSettingsSection('language');
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          tester
              .widget<DropdownButtonFormField<String>>(
                find.byKey(const ValueKey('app-language-ru')),
              )
              .onChanged!('en');
          await app.library.flush();
        });
        await tester.pumpAndSettle();
        expect(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
          const Locale('en'),
        );
        expect(find.text('Interface language'), findsOneWidget);
        for (final section in _sectionIds) {
          app.setSettingsSection(section);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'English $section $size',
          );
        }
        app.setSettingsSection('playback');
        await tester.pumpAndSettle();
        expect(find.text('Equalizer'), findsOneWidget);
        expect(find.text('Mono audio'), findsOneWidget);
        expect(app.library.settings['monoAudio'], isTrue);
        expect(app.library.settings['normalizeVolume'], isTrue);
        expect(fixture.engineStarts, 0);
        expect(fixture.httpRequests, 0);
        final restored = LibraryRepository(app.library.root);
        await tester.runAsync(() async {
          await app.library.flush();
          await restored.load();
        });
        expect(restored.settings['language'], 'en');
        expect(restored.settings['equalizerGains'], [
          6.0,
          0.0,
          0.0,
          0.0,
          0.0,
          0.0,
        ]);
        restored.dispose();
      },
    );
  }
  testWidgets(
    'profile picker saves bytes and reads content URIs, cancellation and errors',
    (tester) async {
      final fixture = await _fixture(tester);
      addTearDown(() => fixture.close(tester));
      final picker = _ProfilePicker();
      final originalPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = originalPicker);
      final app = fixture.app;
      await tester.runAsync(() async {
        await app.library.upsert([
          const Track(
            id: 'transfer',
            title: 'Трек',
            artist: 'Автор',
            album: 'Альбом',
            source: TrackSource.local,
          ),
        ]);
        await app.library.toggleLike('transfer');
        await app.exportProfile();
        expect(app.error, isNull);
        expect(
          ProfileTransfer.decode(utf8.decode(picker.saved!)).favoriteCount,
          1,
        );
        expect(await app.pickProfile(), isNull);
        expect(app.error, isNull);
        picker.selected = _ProfileFile(picker.saved!);
        final transfer = await app.pickProfile();
        expect(transfer!.favoriteCount, 1);
        await app.library.toggleLike('transfer');
        await app.importProfile(transfer);
        expect(app.library.isTrackLiked('transfer'), isTrue);
        expect(app.error, isNull);
        picker.selected = _ProfileFile(
          Uint8List.fromList(utf8.encode('{broken')),
        );
        expect(await app.pickProfile(), isNull);
        expect(app.error, isNotNull);
        expect(app.library.isTrackLiked('transfer'), isTrue);
        expect(fixture.httpRequests, 0);
        expect(fixture.engineStarts, 0);
      });
    },
  );

  testWidgets(
    'profile import preview can cancel and confirm without starting audio',
    (tester) async {
      final fixture = await _fixture(tester);
      addTearDown(() => fixture.close(tester));
      final app = fixture.app;
      app.mockProfilePicker = true;
      await tester.runAsync(() async {
        final donor = LibraryRepository(
          Directory('${fixture.root.path}/donor'),
        );
        await donor.load();
        await donor.upsert([
          const Track(
            id: 'saved-track',
            title: 'Песня',
            artist: 'Автор',
            album: 'Альбом',
            source: TrackSource.local,
          ),
        ]);
        await donor.toggleLike('saved-track');
        app.transferToPick = ProfileTransfer.decode(
          await donor.exportProfile(),
        );
        donor.dispose();
      });
      await _mount(tester, app, const Size(320, 568));
      app.setSettingsSection('profile');
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('import-profile'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(button));
      await tester.pumpAndSettle();
      expect(find.text('Импортировать профиль?'), findsOneWidget);
      expect(find.textContaining('Любимых треков: 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(app.library.favoriteTracks, isEmpty);
      await tester.runAsync(() => tester.tap(button));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Импортировать'));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (app.busy != null) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('Profile import stalled');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(app.library.favoriteTracks.single.id, 'saved-track');
      expect(app.error, isNull);
      expect(app.playback.queue, isEmpty);
      expect(fixture.httpRequests, 0);
      expect(fixture.engineStarts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(320, 568), const Size(1200, 850)]) {
    testWidgets(
      'radio opt-in persists and fits $size without background work',
      (tester) async {
        final fixture = await _fixture(tester);
        addTearDown(() => fixture.close(tester));
        await _mount(tester, fixture.app, size);
        fixture.app.setSettingsSection('playback');
        await tester.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('radio-autoplay'));
        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(toggle);
          await fixture.app.library.flush();
        });
        await tester.pumpAndSettle();
        expect(fixture.app.library.settings['autoplayRadio'], isTrue);
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
        expect(fixture.httpRequests, 0);
        expect(fixture.engineStarts, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
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
    expect(find.text('Автоматически'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Дополнительно: свой Jackett / Prowlarr'));
    await tester.pumpAndSettle();
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
      find.byKey(const ValueKey('download-concurrency-3')),
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
    final prefetch = tester.widget<DropdownButtonFormField<int>>(
      find.byKey(const ValueKey('prefetch-tracks-3')),
    );
    await tester.runAsync(() async {
      prefetch.onChanged!(5);
      await app.library.flush();
    });
    await tester.pumpAndSettle();
    expect(app.prefetch.count, 5);
    expect(app.library.settings['prefetchTracks'], 5);
    expect(app.cacheReads, 0);
    expect(app.networkReads, 0);
    expect(fixture.httpRequests, 0);
    expect(fixture.engineStarts, 0);
    expect(tester.takeException(), isNull);
  });
}
