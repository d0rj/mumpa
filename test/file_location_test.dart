import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/file_location_service.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/pages.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

const _channel = MethodChannel('app.mumpa/windows_player');

Track _track(String id, {String? cachedPath, String? localPath}) => Track(
  id: id,
  title: 'Track $id',
  artist: 'Artist $id',
  album: 'Album $id',
  source: localPath == null ? TrackSource.torrent : TrackSource.local,
  cachedPath: cachedPath,
  localPath: localPath,
  torrentHash: 'same-file-hash',
  torrentPath: '$id.flac',
);

class _NoCovers extends MusicMetadataRepository {
  _NoCovers(Directory root, MockClient client)
    : super(
        cache: DiskMediaCache(Directory('${root.path}/metadata')),
        client: client,
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
}

Future<AppController> _app(LibraryRepository library) async {
  await library.setSetting('autoCache', false);
  MockClient client() =>
      MockClient((_) async => throw StateError('No network'));
  final torrents = TorrentService(
    client: client(),
    endpoint: () async => throw StateError('No engine'),
  );
  final playback = PlaybackController(
    library: library,
    torrents: torrents,
    backend: FakeAudioBackend(),
  );
  await playback.initialize(platformAudio: false);
  return AppController(
    library: library,
    playback: playback,
    downloads: DownloadRepository(library, torrents),
    torrents: torrents,
    engine: TorrentEngine(library.root),
    indexer: IndexerService(client: client()),
    metadata: _NoCovers(library.root, client()),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) return;
  late LibraryRepository library;
  late File saved;
  final calls = <MethodCall>[];

  setUp(() async {
    final root = await Directory.systemTemp.createTemp('mumpa-reveal-');
    library = LibraryRepository(root);
    await library.load();
    saved = await File(
      '${library.downloads.path}/Песня & live, 01.flac',
    ).create(recursive: true);
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    library.dispose();
    await library.root.delete(recursive: true);
  });

  test(
    'reveals the existing downloaded file with its exact Unicode path',
    () async {
      await FileLocationService.revealTrack(
        library,
        _track('saved', cachedPath: saved.path),
      );
      expect(calls.single.method, 'revealFile');
      expect(calls.single.arguments, saved.absolute.path);
    },
  );

  test('reveals an imported original in its own folder', () async {
    final original = await File(
      '${library.root.path}/Моя музыка/local.wav',
    ).create(recursive: true);
    await FileLocationService.revealTrack(
      library,
      _track('local', localPath: original.path),
    );
    expect(calls.single.arguments, original.absolute.path);
  });

  test(
    'uses the latest record and a shared copy from another playlist',
    () async {
      final stale = _track('shared', cachedPath: '${saved.path}.missing');
      await library.upsert([_track('shared', cachedPath: saved.path)]);
      await FileLocationService.revealTrack(library, stale);
      expect(calls.single.arguments, saved.absolute.path);
      calls.clear();
      final remote = _track('shared');
      // Same hash/path but a different library occurrence.
      final alias = Track(
        id: 'alias',
        title: 'Alias',
        artist: 'Other',
        album: 'Other',
        source: TrackSource.torrent,
        torrentHash: remote.torrentHash,
        torrentPath: remote.torrentPath,
      );
      await FileLocationService.revealTrack(library, alias);
      expect(calls.single.arguments, saved.absolute.path);
    },
  );

  test(
    'missing completed file and partial downloads never open Explorer',
    () async {
      final missing = _track('missing', cachedPath: '${saved.path}.missing');
      await expectLater(
        FileLocationService.revealTrack(library, missing),
        throwsA(isA<FileSystemException>()),
      );
      await File('${library.downloads.path}/partial.flac.part').create();
      final partial = _track('partial');
      expect(FileLocationService.canReveal(library, partial), isFalse);
      await expectLater(
        FileLocationService.revealTrack(library, partial),
        throwsA(isA<FileSystemException>()),
      );
      expect(calls, isEmpty);
    },
  );

  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'file location actions work without starting playback at $width px',
      (tester) async {
        final app = (await tester.runAsync(() async {
          await library.upsert([
            _track('saved', cachedPath: saved.path),
            _track('remote'),
          ]);
          await library.toggleLike('saved');
          await library.toggleLike('remote');
          return _app(library);
        }))!..navigate(AppPage.liked);
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(app.shutdown);
        });
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
        expect(
          find.byKey(const ValueKey('track-reveal-saved')),
          width > 450 ? findsOneWidget : findsNothing,
        );
        expect(find.byKey(const ValueKey('track-reveal-remote')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('track-actions-remote')));
        await tester.pumpAndSettle();
        expect(find.text('Показать в проводнике'), findsNothing);
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('track-actions-saved')));
        await tester.pumpAndSettle();
        expect(find.text('Показать в проводнике'), findsOneWidget);
        final menu = tester.widget<PopupMenuButton<String>>(
          find.byKey(const ValueKey('track-actions-saved')),
        );
        // Run the async action in the real IO zone; gesture/route tests use
        // fake time, which cannot complete File.exists reliably.
        await tester.runAsync(() async {
          await (menu.onSelected! as dynamic)('revealFile');
        });
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(calls.single.arguments, saved.absolute.path);
        expect(app.playback.current, isNull);
        expect(app.downloads.jobs, isEmpty);
        app.navigate(AppPage.downloads);
        await tester.pumpAndSettle();
        expect(
          find.text('Папка загрузок: ${library.downloads.path}'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Explorer failure appears in the app without changing playback', (
    tester,
  ) async {
    final app = (await tester.runAsync(() async {
      await library.upsert([_track('saved', cachedPath: saved.path)]);
      return _app(library);
    }))!..navigate(AppPage.downloads);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: mumpaTheme(),
        home: Scaffold(body: ContentPage(app: app)),
      ),
    );
    await tester.pumpAndSettle();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _channel,
          (_) async => throw PlatformException(code: 'reveal-failed'),
        );
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('track-reveal-saved')),
    );
    await tester.runAsync(() async {
      await (button.onPressed! as dynamic)();
    });
    await tester.pumpAndSettle();
    expect(app.error, 'Не удалось открыть расположение трека в проводнике.');
    expect(app.playback.current, isNull);
    expect(tester.takeException(), isNull);
  });
}
