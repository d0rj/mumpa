import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
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

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(cache: DiskMediaCache(Directory('${root.path}/metadata')));
  @override
  Future<String?> coverForReleaseTitle(String title) async => null;
  @override
  Future<String?> cachedCoverForAlbum(
    String artistName,
    String albumTitle,
  ) async => null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

void main() {
  for (final width in [320.0, 1200.0]) {
    testWidgets('home shelves, system playlist and storage usage at $width', (
      tester,
    ) async {
      final font = FontLoader('Manrope')
        ..addFont(rootBundle.load('assets/fonts/Manrope.ttf'));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late AppController app;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('mumpa-home-listening-');
        final library = LibraryRepository(root);
        await library.load();
        await library.downloads.create();
        final cached = await File(
          '${library.downloads.path}/download.wav',
        ).writeAsBytes(List.filled(1024 * 1024, 0));
        final imported = await File(
          '${root.path}/imported.wav',
        ).writeAsBytes(List.filled(2 * 1024 * 1024, 0));
        await library.upsert([
          Track(
            id: 'download',
            title: 'Скачанный трек',
            artist: 'Исполнитель',
            album: 'Альбом',
            source: TrackSource.torrent,
            cachedPath: cached.path,
            bytes: 1,
          ),
          Track(
            id: 'import',
            title: 'Музыка с диска',
            artist: 'Исполнитель',
            album: 'Альбом',
            source: TrackSource.local,
            localPath: imported.path,
          ),
        ]);
        await library.setSetting('cacheLimitMb', 64);
        await library.setSetting('autoCache', false);
        final playlist = await library.createPlaylist(
          'Плейлист для долгих прогулок',
        );
        await library.addToPlaylist(playlist.id, ['download', 'import']);
        await library.recordListen('download', playlistId: playlist.id);
        final torrents = TorrentService(
          endpoint: () async => throw StateError('No network'),
        );
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
          metadata: _Metadata(root),
        );
        app.sourceFeed = [
          for (var i = 0; i < 12; i++)
            SearchRelease(
              title:
                  'Исполнитель $i — Альбом для вечерних прогулок (2026) [FLAC]',
              link: 'magnet:?xt=urn:btih:${i.toString().padLeft(40, '0')}',
              bytes: 100 * 1024 * 1024,
            ),
        ];
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await app.shutdown();
          app.library.dispose();
          await root.delete(recursive: true);
        });
      });
      final boundary = GlobalKey();
      Future<void> screenshot(String name) async {
        if (width != 1200) {
          return;
        }
        await tester.runAsync(() async {
          final pixels =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final png = await pixels.toByteData(format: ui.ImageByteFormat.png);
          await Directory('test-output').create();
          await File(
            'test-output/$name.png',
          ).writeAsBytes(png!.buffer.asUint8List());
          pixels.dispose();
        });
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: mumpaTheme(),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundary,
              child: ListenableBuilder(
                listenable: app,
                builder: (_, _) => ContentPage(app: app),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-top-50')), findsOneWidget);
      expect(find.text('Часто слушаешь'), findsOneWidget);
      await screenshot('home-listening');
      final shelf = find.byKey(const ValueKey('home-release-shelf'));
      await tester.ensureVisible(shelf);
      await tester.pumpAndSettle();
      final horizontal = find.descendant(
        of: shelf,
        matching: find.byType(ListView),
      );
      expect(
        tester.widget<ListView>(horizontal).scrollDirection,
        Axis.horizontal,
      );
      await tester.drag(horizontal, const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListView>(horizontal).controller!.offset,
        greaterThan(0),
      );
      expect(tester.takeException(), isNull);
      await screenshot('home-listening-catalog');
      app.openPlaylist(app.library.topTracksPlaylist);
      await tester.pumpAndSettle();
      expect(find.text('Топ-50 на этом устройстве'), findsOneWidget);
      expect(find.byKey(const ValueKey('play-collection')), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is ReorderableDragStartListener),
        findsNothing,
      );
      final actions = tester.widget<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );
      final values = actions
          .itemBuilder(tester.element(find.byType(PopupMenuButton<String>)))
          .whereType<PopupMenuItem<String>>()
          .map((item) => item.value);
      expect(values, isNot(contains('rename')));
      expect(values, isNot(contains('delete')));
      expect(values, isNot(contains('removePlaylist')));
      app.navigate(AppPage.settings);
      app.setSettingsSection('downloads');
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) =>
                    w is IconButton && w.tooltip == 'Обновить размер загрузок',
              ),
            )
            .onPressed!();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      final usage = find.byKey(const ValueKey('offline-storage-usage'));
      await tester.ensureVisible(usage);
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pumpAndSettle();
        if (tester.widget<Text>(usage).data!.startsWith('Скачанные треки:')) {
          break;
        }
      }
      expect(
        tester.widget<Text>(usage).data,
        'Скачанные треки: 1.0 МБ из 64.0 МБ · 1.6%',
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        closeTo(1 / 64, .00001),
      );
      expect(tester.takeException(), isNull);
      await screenshot('offline-storage-usage');
      await tester.runAsync(() => app.library.setSetting('cacheLimitMb', 1));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(usage).data, contains('100.0%'));
      await tester.runAsync(() async {
        await app.downloads.removeOffline(
          app.library.byId('download')!,
          userRequested: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pumpAndSettle();
        if (tester.widget<Text>(usage).data!.contains('0 КБ из')) break;
      }
      expect(tester.widget<Text>(usage).data, contains('0 КБ из'));
      expect(tester.takeException(), isNull);
    });
  }
}
