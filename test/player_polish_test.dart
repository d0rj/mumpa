import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
  _Downloads(super.library, super.torrents);
  List<DownloadJob> statuses = [];

  @override
  List<DownloadJob> get jobs => List.unmodifiable(statuses);

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
  WidgetTester tester,
) async => (await tester.runAsync(() async {
  final root = await Directory.systemTemp.createTemp('mumpa-player-polish-');
  final library = LibraryRepository(root);
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
    backend: FakeAudioBackend(),
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
  theme: mumpaTheme(),
  home: Scaffold(body: body),
);

void _viewport(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
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
        expect(button.onPressed != null, lyrics?.trim().isNotEmpty == true);
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    });
  }

  testWidgets('lyrics tabs update while paused and cannot open empty text', (
    tester,
  ) async {
    final f = await _fixture(tester);
    _viewport(tester, 1200);
    try {
      final track = f.track('one');
      await tester.runAsync(() => f.select(track));
      await tester.pumpWidget(_host(PlayerBar(app: f.app, compact: false)));
      await tester.pumpAndSettle();
      showNowPlaying(tester.element(find.byType(PlayerBar)), f.app, tab: 2);
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).tabs, hasLength(2));
      expect(
        tester.widget<TabBarView>(find.byType(TabBarView)).children,
        hasLength(2),
      );
      expect(find.text('Текст'), findsNothing);
      await tester.drag(find.byType(TabBarView), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(find.text('Текст'), findsNothing);

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
      expect(tabs.tabs, hasLength(2));
      expect(tabs.controller!.index, 0);
      expect(find.text('Текст'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.close(tester);
    }
  });

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
        await tester.tap(find.byKey(const ValueKey('track-row-matching')));
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
