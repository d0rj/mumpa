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
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/pages.dart';
import 'package:mumpa/ui/player.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(cache: DiskMediaCache(Directory('${root.path}/metadata')));

  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

class _Fixture {
  _Fixture(this.root, this.app, this.backend, this.collection, this.other);
  final Directory root;
  final AppController app;
  final FakeAudioBackend backend;
  final MusicPlaylist collection, other;
  Track get track => app.library.byId('a1')!;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('mumpa-album-nav-');
    final library = LibraryRepository(root);
    await library.load();
    await library.setSetting('autoCache', false);
    final file = await File('${root.path}/song.wav').writeAsBytes([0]);
    final tracks = [
      for (final (id, album, hash, number) in [
        ('a1', 'Альбом', 'source-a', 1),
        ('a2', 'Альбом', 'source-a', 2),
        ('b1', 'Другой альбом', 'source-a', 1),
        ('c1', 'Альбом', 'source-c', 1),
      ])
        Track(
          id: id,
          title: id == 'c1' ? 'Песня 1' : 'Песня $number',
          artist: 'Группа',
          album: album,
          number: number,
          source: TrackSource.torrent,
          torrentHash: hash,
          torrentIndex: number,
          torrentPath: '$album/$id.flac',
          cachedPath: file.path,
        ),
      Track(
        id: 'local',
        title: 'Локальная песня',
        artist: 'Группа',
        album: 'Альбом',
        source: TrackSource.local,
        localPath: file.path,
      ),
    ];
    await library.upsert(tracks);
    final collection = await library.openSourceCollection(
      hash: 'source-a',
      name: 'Дискография группы',
      tracks: tracks.take(3).toList(),
    );
    final other = await library.openSourceCollection(
      hash: 'source-c',
      name: 'Другая раздача',
      tracks: [tracks[3]],
    );
    final torrents = TorrentService(
      endpoint: () async => throw StateError('Navigation must stay offline'),
    );
    final backend = FakeAudioBackend();
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: backend,
    );
    await playback.initialize(platformAudio: false);
    final app = AppController(
      library: library,
      playback: playback,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
      metadata: _Metadata(root),
    );
    return _Fixture(root, app, backend, collection, other);
  }

  Future<void> close() async {
    await app.shutdown();
    app.library.dispose();
    await root.delete(recursive: true);
  }
}

Future<void> _paint(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(tester.takeException(), isNull);
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

  test(
    'track album keeps source siblings and resolves its collection',
    () async {
      final f = await _Fixture.create();
      try {
        final playlist = await f.app.library.createPlaylist('Мой плейлист');
        await f.app.library.addToPlaylist(playlist.id, [f.track.id]);
        f.app.openPlaylist(playlist);
        f.app.openTrackAlbum(f.track);
        expect(f.app.album!.tracks.map((t) => t.id), ['a1', 'a2']);
        expect(f.app.albumPlaylistId, f.collection.id);
        expect(f.app.albumCollections.map((p) => p.id), [f.collection.id]);
        expect(f.backend.opened, isNull);
        f.app.openPlaylist(f.app.albumCollections.single);
        expect(f.app.playlist!.id, f.collection.id);
        f.app.back();
        expect(f.app.page, AppPage.album);
        expect(f.app.album!.tracks.map((t) => t.id), ['a1', 'a2']);
        f.app.back();
        expect(f.app.playlist!.id, playlist.id);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'local album has no parent and source collections can disappear',
    () async {
      final f = await _Fixture.create();
      try {
        f.app.openTrackAlbum(f.app.library.byId('local')!);
        expect(f.app.album!.tracks.single.id, 'local');
        expect(f.app.albumCollections, isEmpty);
        f.app.openTrackAlbum(f.track);
        await f.app.library.deletePlaylist(f.collection.id);
        expect(f.app.albumCollections, isEmpty);
        expect(f.app.album!.tracks.length, 2);
      } finally {
        await f.close();
      }
    },
  );

  for (final playing in [false, true]) {
    testWidgets(
      'album link follows the ${playing ? 'playing' : 'preferred'} version',
      (tester) async {
        final f = (await tester.runAsync(_Fixture.create))!;
        try {
          await tester.runAsync(() async {
            if (playing) {
              await f.app.playCollection([
                f.track,
              ], selectedVariant: f.app.library.byId('c1'));
            } else {
              await f.app.library.preferTrackVariant('c1');
            }
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: mumpaTheme(),
              home: Scaffold(
                body: CustomScrollView(
                  slivers: [
                    TrackList(app: f.app, tracks: [f.track]),
                  ],
                ),
              ),
            ),
          );
          await _paint(tester);
          final opened = f.backend.opened;
          await tester.tap(find.byKey(const ValueKey('track-album-a1')));
          await _paint(tester);
          expect(f.app.album!.tracks.single.id, 'c1');
          expect(f.app.albumCollections.single.id, f.other.id);
          expect(f.backend.opened, opened);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(f.close);
        }
      },
    );
  }

  test(
    'library album exposes each actual source and refreshes track metadata',
    () async {
      final f = await _Fixture.create();
      try {
        f.app.openAlbum(f.app.library.albumById(f.track.albumKey)!);
        expect(f.app.albumCollections.map((p) => p.id).toSet(), {
          f.collection.id,
          f.other.id,
        });
        final stale = f.track;
        await f.app.library.upsert([stale.copyWith(album: 'Новое название')]);
        f.app.openTrackAlbum(stale);
        expect(f.app.album!.title, 'Новое название');
        expect(f.app.albumCollections.single.id, f.collection.id);
      } finally {
        await f.close();
      }
    },
  );

  for (final width in [1200.0, 390.0, 320.0]) {
    testWidgets('track to album to collection and Back at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = (await tester.runAsync(_Fixture.create))!;
      try {
        f.app.navigate(AppPage.downloads);
        await tester.pumpWidget(
          MaterialApp(
            theme: mumpaTheme(),
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  TrackList(app: f.app, tracks: [f.track]),
                ],
              ),
            ),
          ),
        );
        await _paint(tester);
        if (width > 700) {
          await tester.tap(find.byKey(const ValueKey('track-album-a1')));
        } else {
          await tester.tap(find.byKey(const ValueKey('track-actions-a1')));
          await _paint(tester);
          await tester.tap(find.text('Перейти к альбому'));
        }
        await _paint(tester);
        expect(f.app.page, AppPage.album);
        expect(f.backend.opened, isNull);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('navigation-preview'),
            child: MumpaApp(controller: f.app),
          ),
        );
        await _paint(tester);
        final parent = find.byKey(
          ValueKey('album-collection-${f.collection.id}'),
        );
        expect(find.text('Поиск в альбоме'), findsOneWidget);
        await tester.ensureVisible(parent);
        await _paint(tester);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('navigation-preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('test-output').create(recursive: true);
          await File('test-output/album-navigation-$width.png').writeAsBytes(
            bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          );
          image.dispose();
        });
        await tester.tap(parent);
        await _paint(tester);
        expect(f.app.playlist!.id, f.collection.id);
        expect(find.text('Дискография группы'), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('navigation-back')));
        await _paint(tester);
        expect(f.app.page, AppPage.album);
        await tester.tap(find.byKey(const ValueKey('navigation-back')));
        await _paint(tester);
        expect(f.app.page, AppPage.downloads);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(f.close);
      }
    });

    for (final entry in ['bar', 'sheet', 'queue']) {
      testWidgets(
        'player $entry opens album without changing playback at $width',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final f = (await tester.runAsync(_Fixture.create))!;
          try {
            await tester.runAsync(
              () => f.app.playCollection([
                f.track,
                f.app.library.byId('a2')!,
              ], playlistId: f.collection.id),
            );
            f.app.navigate(AppPage.library);
            await tester.pumpWidget(MumpaApp(controller: f.app));
            await _paint(tester);
            final opened = f.backend.opened;
            final queue = f.app.playback.queue.map((t) => t.id).toList();
            if (entry != 'bar') {
              final context = tester.element(find.byType(PlayerBar));
              showNowPlaying(context, f.app, tab: entry == 'queue' ? 1 : 0);
              await _paint(tester);
            }
            final link = entry == 'bar'
                ? find.byKey(const ValueKey('player-album'))
                : entry == 'sheet'
                ? find.byKey(const ValueKey('now-playing-album'))
                : find
                      .byWidgetPredicate(
                        (widget) =>
                            widget is AlbumLink &&
                            widget.key.toString().contains('queue-album-'),
                      )
                      .first;
            await tester.ensureVisible(link);
            await tester.tap(link);
            await _paint(tester);
            expect(f.app.page, AppPage.album);
            expect(find.byType(TabBar), findsNothing);
            expect(f.app.album!.tracks.map((t) => t.id), ['a1', 'a2']);
            expect(f.app.playback.current!.id, 'a1');
            expect(f.app.playback.playing, isTrue);
            expect(f.backend.opened, opened);
            expect(f.app.playback.queue.map((t) => t.id), queue);
            expect(find.byType(ContentPage), findsOneWidget);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(f.close);
          }
        },
      );
    }
  }
}
