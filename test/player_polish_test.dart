import 'dart:async';
import 'dart:convert';
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
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/player.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

class _UiLibrary extends LibraryRepository {
  _UiLibrary(super.root) : _ioZone = Zone.current;
  final Zone _ioZone;
  @override
  Future<void> recordListen(String id, {String? playlistId}) =>
      _ioZone.run(() => super.recordListen(id, playlistId: playlistId));
  @override
  Future<void> toggleLike(String id) => _ioZone.run(() => super.toggleLike(id));
  @override
  Future<void> addToPlaylist(String id, Iterable<String> tracks) =>
      _ioZone.run(() => super.addToPlaylist(id, tracks));
  @override
  Future<void> setSetting(String key, dynamic value) =>
      _ioZone.run(() => super.setSetting(key, value));
}

class _LongAudioBackend extends FakeAudioBackend {
  @override
  Duration get duration => const Duration(minutes: 4, seconds: 12);
}

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(cache: DiskMediaCache(Directory('${root.path}/metadata')));

  final requests = <({String artist, String album})>[];
  Completer<String?>? pending;

  @override
  Future<String?> cachedCoverForAlbum(
    String artistName,
    String albumTitle,
  ) async => null;

  @override
  Future<String?> coverForAlbum(String artistName, String albumTitle) {
    requests.add((artist: artistName, album: albumTitle));
    return pending?.future ?? Future<String?>.value(null);
  }
}

class _Downloads extends DownloadRepository {
  _Downloads(super.library, super.torrents) : _ioZone = Zone.current;
  final Zone _ioZone;
  List<DownloadJob> statuses = [];

  @override
  List<DownloadJob> get jobs => List.unmodifiable(statuses);

  @override
  Future<void> removeOffline(Track track, {bool userRequested = false}) =>
      _ioZone.run(
        () => super.removeOffline(track, userRequested: userRequested),
      );

  void update(List<DownloadJob> jobs) {
    statuses = jobs;
    notifyListeners();
  }
}

class _Fixture {
  _Fixture({
    required this.root,
    required this.library,
    required this.playback,
    required this.downloads,
    required this.torrents,
    required this.metadata,
    required this.app,
    required this.audioPath,
    required this.artPath,
  });

  final Directory root;
  final LibraryRepository library;
  final PlaybackController playback;
  final _Downloads downloads;
  final TorrentService torrents;
  final _Metadata metadata;
  final AppController app;
  final String audioPath, artPath;

  Track track(String id, {String? lyrics, bool offline = false}) => Track(
    id: id,
    title: 'Track $id',
    artist: 'Track Artist',
    albumArtist: 'Album Artist',
    album: 'Actual Album',
    source: offline ? TrackSource.local : TrackSource.torrent,
    localPath: offline ? audioPath : null,
    torrentPath: offline ? null : '01 - Track $id.flac',
    lyrics: lyrics,
  );

  Future<void> select(Track track) async {
    await library.upsert([track]);
    playback.enqueue(track);
    await library.flush();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      app.dispose();
      downloads.dispose();
      await playback.close();
      torrents.dispose();
      await library.flush();
      library.dispose();
      await root.delete(recursive: true);
    });
  }
}

Future<_Fixture> _fixture(
  WidgetTester tester, {
  AudioBackend? backend,
}) async => (await tester.runAsync(() async {
  final root = await Directory.systemTemp.createTemp('mumpa-player-polish-');
  final library = _UiLibrary(root);
  await library.load();
  final audio = await File('${root.path}/track.mp3').writeAsBytes([1]);
  final art = await File('${root.path}/cover.png').writeAsBytes(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+nmC8AAAAASUVORK5CYII=',
    ),
  );
  final torrents = TorrentService(endpoint: () async => 'http://localhost');
  final playback = PlaybackController(
    library: library,
    torrents: torrents,
    backend: backend ?? FakeAudioBackend(),
  );
  await playback.initialize(platformAudio: false);
  final downloads = _Downloads(library, torrents);
  final metadata = _Metadata(root);
  final app = AppController(
    library: library,
    playback: playback,
    downloads: downloads,
    torrents: torrents,
    engine: TorrentEngine(root),
    metadata: metadata,
  );
  return _Fixture(
    root: root,
    library: library,
    playback: playback,
    downloads: downloads,
    torrents: torrents,
    metadata: metadata,
    app: app,
    audioPath: audio.path,
    artPath: art.path,
  );
}))!;

Widget _host(Widget body) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: mumpaTheme(),
  home: Scaffold(body: body),
);

void _viewport(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _allControlsVisible(WidgetTester tester) {
  final viewport = find.byKey(const ValueKey('now-playing-viewport'));
  final bounds = tester.getRect(viewport);
  expect(
    find.descendant(of: viewport, matching: find.byType(Scrollable)),
    findsNothing,
  );
  final controls = [
    find.byKey(const ValueKey('now-playing-artist')),
    find.byKey(const ValueKey('now-playing-album')),
    find.byKey(const ValueKey('now-playing-seek')),
    find.byKey(const ValueKey('now-playing-volume')),
    find.byKey(const ValueKey('now-playing-actions')),
    find.byKey(const Key('transport-toggle')).last,
    find.byTooltip('Предыдущий трек').last,
    find.byTooltip('Следующий трек').last,
    find.byTooltip('Перемешать').last,
    find.byTooltip('Повтор выключен').last,
    find.byTooltip('Таймер сна'),
    find.byTooltip('Без звука').last,
  ];
  for (final control in controls) {
    final rect = tester.getRect(control);
    expect(
      rect.left,
      greaterThanOrEqualTo(bounds.left - .1),
      reason: '$control',
    );
    expect(rect.top, greaterThanOrEqualTo(bounds.top - .1), reason: '$control');
    expect(
      rect.right,
      lessThanOrEqualTo(bounds.right + .1),
      reason: '$control',
    );
    expect(
      rect.bottom,
      lessThanOrEqualTo(bounds.bottom + .1),
      reason: '$control',
    );
    expect(control.hitTestable(), findsOneWidget, reason: '$control');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final compact in [false, true]) {
    testWidgets(
      'position updates timeline without rebuilding player artwork ($compact)',
      (tester) async {
        final f = await _fixture(tester);
        _viewport(tester, compact ? 400 : 1200);
        try {
          final track = f.track('timeline', offline: true);
          await tester.runAsync(() => f.library.upsert([track]));
          await tester.runAsync(() => f.playback.playTracks([track]));
          await tester.pumpWidget(
            _host(PlayerBar(app: f.app, compact: compact)),
          );
          await tester.pump();
          final artwork = tester.widget<TrackArtwork>(
            find.byType(TrackArtwork),
          );
          var controlUpdates = 0;
          void changed() => controlUpdates++;
          f.playback.controlsState.addListener(changed);
          await f.playback.backend.seek(const Duration(seconds: 12));
          await tester.pump();
          expect(
            tester.widget<TrackArtwork>(find.byType(TrackArtwork)),
            same(artwork),
          );
          expect(controlUpdates, 0);
          if (compact) {
            expect(
              tester
                  .widget<LinearProgressIndicator>(
                    find.byType(LinearProgressIndicator),
                  )
                  .value,
              .5,
            );
          } else {
            expect(find.text('0:12'), findsOneWidget);
          }
          await f.playback.backend.setVolume(.3);
          await tester.pump();
          expect(controlUpdates, 1);
          await f.playback.backend.pause();
          await tester.pump();
          expect(controlUpdates, 2);
          expect(find.byTooltip('Слушать'), findsOneWidget);
          f.playback.controlsState.removeListener(changed);
        } finally {
          await f.close(tester);
        }
      },
    );
  }

  for (final lyrics in <String?>[null, '', ' \n\t ', 'Real song words']) {
    testWidgets('desktop lyrics availability follows $lyrics', (tester) async {
      final f = await _fixture(tester);
      _viewport(tester, 1200);
      try {
        await tester.runAsync(() => f.select(f.track('one', lyrics: lyrics)));
        await tester.pumpWidget(_host(PlayerBar(app: f.app, compact: false)));
        await tester.pumpAndSettle();
        final button = tester.widget<IconButton>(
          find.byKey(const ValueKey('desktop-lyrics')),
        );
        expect(
          button.onPressed,
          isNotNull,
        ); // Empty tags can now load LRC/LRCLIB.
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    });
  }

  testWidgets(
    'lyrics tabs update while paused and offer lookup for empty tags',
    (tester) async {
      final f = await _fixture(tester);
      _viewport(tester, 1200);
      try {
        final track = f.track('one');
        await tester.runAsync(() => f.select(track));
        await tester.pumpWidget(_host(PlayerBar(app: f.app, compact: false)));
        await tester.pumpAndSettle();
        showNowPlaying(tester.element(find.byType(PlayerBar)), f.app, tab: 2);
        await tester.pumpAndSettle();
        expect(tester.widget<TabBar>(find.byType(TabBar)).tabs, hasLength(3));
        expect(
          tester.widget<TabBarView>(find.byType(TabBarView)).children,
          hasLength(3),
        );
        expect(find.text('Текст'), findsOneWidget);
        await tester.drag(find.byType(TabBarView), const Offset(-700, 0));
        await tester.pumpAndSettle();
        expect(find.text('Текст'), findsOneWidget);

        await tester.runAsync(
          () => f.library.upsert([
            track.copyWith(lyrics: 'Now the tags contain lyrics'),
          ]),
        );
        await tester.pumpAndSettle();
        expect(f.playback.playing, isFalse);
        expect(tester.widget<TabBar>(find.byType(TabBar)).tabs, hasLength(3));
        await tester.tap(find.text('Текст'));
        await tester.pumpAndSettle();
        expect(find.text('Now the tags contain lyrics'), findsOneWidget);

        await tester.runAsync(
          () => f.library.upsert([track.copyWith(lyrics: ' \n ')]),
        );
        await tester.pumpAndSettle();
        final tabs = tester.widget<TabBar>(find.byType(TabBar));
        expect(tabs.tabs, hasLength(3));
        expect(find.text('Текст'), findsOneWidget);
        expect(find.text('Найти текст'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    },
  );

  for (final width in [850.0, 900.0, 1200.0]) {
    testWidgets('desktop volume has a long slider at width $width', (
      tester,
    ) async {
      final f = await _fixture(tester);
      _viewport(tester, width);
      try {
        await tester.runAsync(() => f.select(f.track('one')));
        await tester.pumpWidget(_host(PlayerBar(app: f.app, compact: false)));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const ValueKey('desktop-volume'))).width,
          152,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    });
  }

  testWidgets('mobile now-playing includes volume and fits 320px', (
    tester,
  ) async {
    final f = await _fixture(tester);
    _viewport(tester, 320);
    try {
      await tester.runAsync(() => f.select(f.track('one')));
      await tester.pumpWidget(_host(PlayerBar(app: f.app, compact: true)));
      await tester.pumpAndSettle();
      showNowPlaying(tester.element(find.byType(PlayerBar)), f.app);
      await tester.pumpAndSettle();
      final volume = find.byKey(const ValueKey('now-playing-volume'));
      await tester.ensureVisible(volume);
      await tester.pumpAndSettle();
      expect(tester.getSize(volume).width, greaterThanOrEqualTo(200));
      expect(tester.takeException(), isNull);
    } finally {
      await f.close(tester);
    }
  });

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(600, 960),
    const Size(800, 1280),
    const Size(1280, 800),
    const Size(844, 390),
    const Size(1200, 600),
    const Size(1200, 500),
    const Size(1000, 420),
    const Size(800, 500),
    const Size(700, 400),
    const Size(600, 360),
    const Size(560, 600),
    const Size(320, 480),
  ]) {
    testWidgets('now-playing uses the viewport and readable controls at $size', (
      tester,
    ) async {
      final f = await _fixture(tester, backend: _LongAudioBackend());
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await (FontLoader(
          'Manrope',
        )..addFont(rootBundle.load('assets/fonts/Manrope.ttf'))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        await tester.runAsync(() async {
          final track = f
              .track('portrait', offline: true)
              .copyWith(
                title: 'Свет в окнах',
                artist: 'Северный ветер и гости',
                album: 'Вечерние истории',
              );
          await f.library.upsert([track]);
          await f.playback.playTracks([track]);
          await f.playback.pause();
          await f.playback.seek(const Duration(seconds: 36));
        });
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: _host(PlayerBar(app: f.app, compact: size.width < 850)),
          ),
        );
        await tester.pumpAndSettle();
        unawaited(
          showNowPlaying(tester.element(find.byType(PlayerBar)), f.app),
        );
        await tester.pumpAndSettle();
        final cover = find.byKey(const ValueKey('now-playing-cover'));
        final artist = find.byKey(const ValueKey('now-playing-artist'));
        final album = find.byKey(const ValueKey('now-playing-album'));
        final viewport = find.byKey(const ValueKey('now-playing-viewport'));
        _allControlsVisible(tester);
        expect(
          tester.getSize(cover).width,
          closeTo(tester.getSize(cover).height, .1),
        );
        for (final link in [artist, album]) {
          expect(tester.getSize(link).height, greaterThanOrEqualTo(48));
        }
        expect(
          find.byKey(const ValueKey('now-playing-album-disc')),
          findsOneWidget,
        );
        final seek = find.byKey(const ValueKey('now-playing-seek'));
        final volume = find.byKey(const ValueKey('now-playing-volume'));
        final seekTheme = tester
            .widget<SliderTheme>(
              find.ancestor(of: seek, matching: find.byType(SliderTheme)).first,
            )
            .data;
        final volumeTheme = tester
            .widget<SliderTheme>(
              find
                  .ancestor(of: volume, matching: find.byType(SliderTheme))
                  .first,
            )
            .data;
        expect(seekTheme.activeTrackColor, isNot(volumeTheme.activeTrackColor));
        expect(seekTheme.inactiveTrackColor, isNot(seekTheme.activeTrackColor));
        expect(
          volumeTheme.inactiveTrackColor,
          isNot(volumeTheme.activeTrackColor),
        );
        if (size.height >= 960 && size.width < size.height) {
          final bottomGap =
              tester.getRect(viewport).bottom -
              tester
                  .getRect(find.byKey(const ValueKey('now-playing-status')))
                  .bottom;
          expect(bottomGap, inInclusiveRange(0, 28));
        }
        if (size == const Size(800, 1280)) {
          expect(tester.getSize(cover).width, greaterThan(440));
        }
        expect(tester.takeException(), isNull);
        if (size.width == 390 ||
            size.width == 800 ||
            size.width == 1280 ||
            size == const Size(1200, 500)) {
          await tester.runAsync(() async {
            final pixels =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final png = await pixels.toByteData(format: ui.ImageByteFormat.png);
            await Directory('test-output').create();
            await File(
              'test-output/now-playing-${size.width.toInt()}x${size.height.toInt()}.png',
            ).writeAsBytes(png!.buffer.asUint8List());
            pixels.dispose();
          });
        }
        await tester.runAsync(() async {
          tester.widget<Slider>(volume).onChanged!(.3);
          await f.library.flush();
        });
        await tester.pumpAndSettle();
        expect(f.playback.volume, .3);
        expect(f.playback.position, const Duration(seconds: 36));
        expect(find.text('30%'), findsOneWidget);
        tester.widget<Slider>(seek).onChanged!(60000);
        await tester.pump();
        await tester.runAsync(() async {
          tester.widget<Slider>(seek).onChangeEnd!(60000);
          await f.library.flush();
        });
        await tester.pumpAndSettle();
        expect(f.playback.position, const Duration(minutes: 1));
        expect(f.playback.volume, .3);
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    });
  }

  testWidgets(
    'now-playing menu saves a track without replacing the playing queue',
    (tester) async {
      final f = await _fixture(tester);
      _viewport(tester, 800);
      try {
        late MusicPlaylist target;
        late Track track;
        await tester.runAsync(() async {
          track = f.track('actions', offline: true);
          await f.library.upsert([track, f.track('next', offline: true)]);
          target = await f.library.createPlaylist('Для прогулок');
          await f.playback.playTracks(f.library.tracks);
          await f.playback.pause();
        });
        final queue = f.playback.queue.map((t) => t.id).toList();
        final opened = (f.playback.backend as FakeAudioBackend).opened;
        await tester.pumpWidget(_host(PlayerBar(app: f.app, compact: true)));
        await tester.pumpAndSettle();
        unawaited(
          showNowPlaying(tester.element(find.byType(PlayerBar)), f.app),
        );
        await tester.pumpAndSettle();
        Future<void> menu() async {
          final actions = find.byKey(const ValueKey('now-playing-actions'));
          await tester.tap(actions);
          await tester.pumpAndSettle();
        }

        await menu();
        await tester.tap(find.text('Добавить в плейлист'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(target.name));
        await tester.pumpAndSettle();
        await tester.runAsync(f.library.flush);
        await tester.pumpAndSettle();
        expect(f.library.playlistById(target.id)!.trackIds, [track.id]);
        expect(find.byType(TabBar), findsOneWidget);
        await menu();
        await tester.tap(find.text('В любимое'));
        await tester.pumpAndSettle();
        await tester.runAsync(f.library.flush);
        expect(f.library.isTrackLiked(track.id), isTrue);
        expect(f.playback.queue.map((t) => t.id), queue);
        expect((f.playback.backend as FakeAudioBackend).opened, opened);
        await menu();
        await tester.tap(find.text('В конец очереди'));
        await tester.pumpAndSettle();
        await tester.runAsync(f.library.flush);
        queue.add(track.id);
        expect(f.playback.queue.map((t) => t.id), queue);
        expect(f.playback.current!.id, track.id);
        await menu();
        await tester.tap(find.text('Перейти к альбому'));
        await tester.pumpAndSettle();
        expect(f.app.page, AppPage.album);
        expect(find.byType(TabBar), findsNothing);
        expect(f.playback.queue.map((t) => t.id), queue);
        expect((f.playback.backend as FakeAudioBackend).opened, opened);
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    },
  );

  testWidgets(
    'resizing the open player keeps controls visible with large text and system insets',
    (tester) async {
      final f = await _fixture(tester, backend: _LongAudioBackend());
      _viewport(tester, 1000);
      try {
        await tester.runAsync(() async {
          await f.select(
            f
                .track('resizing', offline: true)
                .copyWith(
                  title:
                      'Очень длинное название для проверки изменения размера окна',
                  artist:
                      'Исполнитель с длинным именем и приглашённые участники',
                  album: 'Альбом с дополнительным длинным описанием',
                  lyrics: 'Текст песни',
                ),
          );
          await f.playback.playTracks(f.library.tracks);
          await f.playback.pause();
          await f.playback.seek(const Duration(seconds: 36));
        });
        final opened = (f.playback.backend as FakeAudioBackend).opened;
        await tester.pumpWidget(
          MaterialApp(
            theme: mumpaTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.8),
                padding: const EdgeInsets.only(top: 24, bottom: 24),
              ),
              child: child!,
            ),
            home: Scaffold(body: PlayerBar(app: f.app, compact: true)),
          ),
        );
        await tester.pumpAndSettle();
        unawaited(
          showNowPlaying(tester.element(find.byType(PlayerBar)), f.app),
        );
        await tester.pumpAndSettle();
        for (final size in [
          const Size(1000, 700),
          const Size(1000, 420),
          const Size(800, 1280),
          const Size(600, 360),
          const Size(390, 568),
          const Size(320, 568),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          _allControlsVisible(tester);
          expect(f.playback.position, const Duration(seconds: 36));
          expect((f.playback.backend as FakeAudioBackend).opened, opened);
          expect(tester.takeException(), isNull, reason: '$size');
        }
      } finally {
        await f.close(tester);
      }
    },
  );

  testWidgets(
    'now-playing fits long metadata at large text size without scrolling',
    (tester) async {
      final f = await _fixture(tester);
      _viewport(tester, 390);
      try {
        await tester.runAsync(
          () => f.select(
            f
                .track('large-text')
                .copyWith(
                  title:
                      'Очень длинное название трека с дополнительным описанием',
                  artist: 'Первый исполнитель и вторая музыкальная группа',
                  album: 'Большой сборник песен с очень длинным названием',
                ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: mumpaTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.8)),
              child: child!,
            ),
            home: Scaffold(body: PlayerBar(app: f.app, compact: true)),
          ),
        );
        await tester.pumpAndSettle();
        unawaited(
          showNowPlaying(tester.element(find.byType(PlayerBar)), f.app),
        );
        await tester.pumpAndSettle();
        _allControlsVisible(tester);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('now-playing-artist')))
              .height,
          greaterThanOrEqualTo(48),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    },
  );

  testWidgets('album columns keep their position across download states', (
    tester,
  ) async {
    final f = await _fixture(tester);
    _viewport(tester, 1100);
    try {
      final tracks = [
        f.track('online'),
        f.track('offline', offline: true),
        f.track('loading'),
      ];
      await tester.runAsync(() => f.library.upsert(tracks));
      final downloading =
          DownloadJob(tracks.last, state: DownloadState.downloading)
            ..total = 1000
            ..received = 500;
      f.downloads.update([downloading]);
      await tester.pumpWidget(
        _host(
          CustomScrollView(
            slivers: [TrackList(app: f.app, tracks: tracks)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      double albumX(String id) =>
          tester.getTopLeft(find.byKey(ValueKey('track-album-$id'))).dx;
      final before = albumX('online');
      expect(albumX('offline'), before);
      expect(albumX('loading'), before);
      for (final track in tracks) {
        expect(
          tester
              .getSize(find.byKey(ValueKey('track-status-${track.id}')))
              .width,
          28,
        );
      }
      await tester.runAsync(
        () =>
            f.library.upsert([tracks.first.copyWith(cachedPath: f.audioPath)]),
      );
      f.downloads.update([]);
      await tester.pumpAndSettle();
      expect(albumX('online'), before);
      expect(albumX('loading'), before);
      expect(tester.takeException(), isNull);
    } finally {
      await f.close(tester);
    }
  });

  testWidgets('canonical artwork requests survive rebuilds and cache clear', (
    tester,
  ) async {
    final f = await _fixture(tester);
    try {
      final track = f.track('one');
      f.metadata.pending = Completer<String?>();
      Widget artwork() => _host(
        Center(
          child: TrackArtwork(app: f.app, track: track, size: 60),
        ),
      );
      await tester.pumpWidget(artwork());
      await tester.pumpWidget(artwork());
      await tester.pump();
      expect(f.metadata.requests, [
        (artist: 'Album Artist', album: 'Actual Album'),
      ]);
      f.metadata.pending!.complete(null);
      await tester.pumpAndSettle();
      await tester.pumpWidget(artwork());
      expect(f.metadata.requests, hasLength(1));
      f.metadata.pending = null;
      await tester.runAsync(() => f.metadata.cache.clear());
      await tester.pumpWidget(artwork());
      await tester.pumpAndSettle();
      expect(f.metadata.requests, hasLength(2));
      expect(tester.takeException(), isNull);
    } finally {
      await f.close(tester);
    }
  });

  testWidgets('completed sibling artwork updates the paused player locally', (
    tester,
  ) async {
    final f = await _fixture(tester);
    _viewport(tester, 1200);
    try {
      final current = f.track('current');
      final sibling = f.track('sibling');
      await tester.runAsync(() async {
        await f.select(current);
        await f.library.upsert([sibling]);
      });
      await tester.pumpWidget(_host(PlayerBar(app: f.app, compact: false)));
      await tester.pumpAndSettle();
      expect(f.metadata.requests, hasLength(1));
      await tester.runAsync(
        () => f.library.upsert([
          sibling.copyWith(cachedPath: f.audioPath, artPath: f.artPath),
        ]),
      );
      await tester.pumpAndSettle();
      expect(f.playback.playing, isFalse);
      expect(tester.widget<CoverArt>(find.byType(CoverArt)).path, f.artPath);
      expect(f.metadata.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    } finally {
      await f.close(tester);
    }
  });

  testWidgets('album subsets reuse embedded artwork from the full library', (
    tester,
  ) async {
    final f = await _fixture(tester);
    try {
      final visible = f.track('in-playlist');
      final sibling = f.track('outside-playlist').copyWith(artPath: f.artPath);
      await tester.runAsync(() => f.library.upsert([visible, sibling]));
      final subset = Album([visible]);
      expect(subset.artPath, isNull);
      await tester.pumpWidget(
        _host(
          Center(
            child: AlbumArtwork(app: f.app, album: subset),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<CoverArt>(find.byType(CoverArt)).path, f.artPath);
      expect(f.metadata.requests, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await f.close(tester);
    }
  });

  testWidgets('filtered track rows play the complete collection order', (
    tester,
  ) async {
    final f = await _fixture(tester);
    _viewport(tester, 1100);
    try {
      final tracks = [
        f.track('first', offline: true),
        f.track('matching', offline: true),
        f.track('last', offline: true),
      ];
      await tester.runAsync(() => f.library.upsert(tracks));
      await tester.pumpWidget(
        _host(
          CustomScrollView(
            slivers: [
              TrackList(app: f.app, tracks: [tracks[1]], queueTracks: tracks),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('track-title-matching')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 200));
      expect(f.playback.queue.map((track) => track.id), [
        'first',
        'matching',
        'last',
      ]);
      expect(f.playback.current?.id, 'matching');
      expect(tester.takeException(), isNull);
    } finally {
      await f.close(tester);
    }
  });
}
