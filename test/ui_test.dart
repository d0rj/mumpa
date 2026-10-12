import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/dialogs.dart';
import 'support.dart';

class UiLibraryRepository extends LibraryRepository {
  UiLibraryRepository(super.root);
  @override
  Future<void> markPlayed(String id) async {}
  @override
  Future<void> setSetting(String key, dynamic value) async {}
}

class WaitingTorrentService extends TorrentService {
  WaitingTorrentService() : super(endpoint: () async => 'http://localhost');
  final ready = Completer<Uri>();
  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) =>
      ready.future;
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
  late Directory root;
  late AppController app;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-ui-');
    final library = UiLibraryRepository(root);
    await library.load();
    final file = File('${root.path}/demo.wav');
    await file.writeAsBytes([1, 2, 3]);
    await library.upsert(
      List.generate(
        12,
        (i) => Track(
          id: '$i',
          title: ['First light', 'Slow orbit', 'After hours'][i % 3],
          artist: 'Mumpa Sessions',
          album: [
            'First light · Демо',
            'Slow orbit · Демо',
            'After hours · Демо',
            'Home recordings · Демо',
          ][i ~/ 3],
          source: TrackSource.demo,
          localPath: file.path,
          durationMs: 24000,
          number: i % 3 + 1,
        ),
      ),
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
  testWidgets(
    'desktop and phone pages render, album plays, search finds tracks',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [
        const Size(1380, 860),
        const Size(850, 700),
        const Size(390, 844),
        const Size(320, 568),
      ]) {
        tester.view.physicalSize = size;
        app.navigate(AppPage.home);
        await tester.pumpWidget(MumpaApp(controller: app));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'home $size');
        for (final page in [
          AppPage.library,
          AppPage.search,
          AppPage.liked,
          AppPage.downloads,
          AppPage.settings,
        ]) {
          app.navigate(page);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$page $size');
        }
        app.openAlbum(app.albums.first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'album $size');
      }
      await tester.scrollUntilVisible(
        find.byKey(const Key('play-album')),
        150,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('play-album')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 250));
      expect(app.playback.current, isNotNull);
      // Matching rows also highlight another known copy of the active song.
      // Pause its continuous wave before waiting for search to settle.
      await tester.runAsync(app.playback.pause);
      app.navigate(AppPage.search);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('music-search')), 'orbit');
      await tester.pumpAndSettle();
      expect(app.searchTracks.length, 6);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('add music dialog and responsive screenshots', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const boundaryKey = Key('capture');
    for (final entry in [
      ('windows', const Size(1380, 860)),
      ('android', const Size(390, 844)),
    ]) {
      tester.view.physicalSize = entry.$2;
      app.navigate(AppPage.home);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MumpaApp(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('test-output/${entry.$1}.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      final context = tester.element(find.byType(AppScreen));
      showAddMusic(context, app);
      await tester.pumpAndSettle();
      expect(find.text('Добавить музыку'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('loading indicators stay circular in liked tracks and players', (
    tester,
  ) async {
    final torrents = WaitingTorrentService();
    final playback = PlaybackController(
      library: app.library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    final pendingApp = AppController(
      library: app.library,
      playback: playback,
      downloads: DownloadRepository(app.library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
    );
    const track = Track(
      id: 'liked-torrent',
      title: 'Liked torrent',
      artist: 'Artist',
      album: 'Album',
      source: TrackSource.torrent,
      torrentHash: 'hash',
      torrentIndex: 1,
    );
    await tester.runAsync(() async {
      await app.library.upsert([track]);
      await app.library.toggleLike(track.id);
    });
    pendingApp.navigate(AppPage.liked);
    late Future<void> opening;
    await tester.runAsync(() async {
      opening = playback.playTracks([track]);
      await Future<void>.delayed(Duration.zero);
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    try {
      for (final size in [const Size(1380, 860), const Size(390, 844)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('loading-capture'),
            child: MumpaApp(controller: pendingApp),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        for (final element
            in find.byType(CircularProgressIndicator).evaluate()) {
          final bounds = tester.getSize(
            find.byElementPredicate((e) => e == element),
          );
          expect(bounds.width, bounds.height, reason: 'circular at $size');
        }
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('loading-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final target = File(
            'test-output/liked-loading-${size.width.toInt()}.png',
          );
          await target.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await playback.stop();
        torrents.ready.complete(Uri.parse('http://localhost/obsolete'));
        await opening;
        pendingApp.dispose();
        pendingApp.downloads.dispose();
        await playback.close();
        torrents.dispose();
      });
    }
  });
}
