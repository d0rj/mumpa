import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root, MockClient client)
    : super(
        cache: DiskMediaCache(Directory('${root.path}/metadata')),
        client: client,
      );
  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

class MatchingFixture {
  MatchingFixture(
    this.root,
    this.app,
    this.backend,
    this.playlist,
    this.tracks,
    this.networkRequests,
  );
  final Directory root;
  final AppController app;
  final FakeAudioBackend backend;
  final MusicPlaylist playlist;
  final List<Track> tracks;
  final List<String> networkRequests;

  static Future<MatchingFixture> create() async {
    final root = await Directory.systemTemp.createTemp('mumpa-matching-ui-');
    final library = LibraryRepository(root);
    await library.load();
    await library.setSetting('autoCache', false);
    final requests = <String>[];
    final client = MockClient((_) async {
      requests.add('HTTP');
      throw StateError('No matching network request is allowed');
    });
    final torrents = TorrentService(
      client: client,
      endpoint: () async {
        requests.add('engine');
        throw StateError('Known offline versions must not start the engine');
      },
    );
    final tracks = <Track>[];
    for (final (id, title, album, extension, duration) in [
      ('mp3', 'Песня (Clean)', 'Первый альбом', 'mp3', 178000),
      ('flac', 'Песня [Explicit]', 'Другой сборник', 'flac', 190000),
      ('next', 'Следующая песня', 'Первый альбом', 'wav', 200000),
      ('live', 'Песня (Live)', 'Концерт', 'wav', 190000),
    ]) {
      final file = await File('${root.path}/$id.$extension').writeAsBytes([0]);
      tracks.add(
        Track(
          id: id,
          title: title,
          artist: 'Группа',
          album: album,
          source: TrackSource.local,
          localPath: file.path,
          durationMs: duration,
        ),
      );
    }
    await library.upsert(tracks);
    final playlist = await library.createPlaylist('Любимая коллекция');
    await library.addToPlaylist(playlist.id, ['mp3', 'next']);
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
      metadata: _Metadata(root, client),
      indexer: IndexerService(client: client),
    );
    return MatchingFixture(root, app, backend, playlist, tracks, requests);
  }

  Future<void> close() async {
    await app.shutdown();
    app.library.dispose();
    await root.delete(recursive: true);
  }
}

Future<void> matchingFrame(WidgetTester tester) async {
  // Finish route transitions, then let file I/O complete outside the fake
  // clock. A playing row intentionally has a continuous wave animation.
  await tester.pump(const Duration(milliseconds: 350));
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> closeMatchingFixture(
  WidgetTester tester,
  MatchingFixture fixture,
) async {
  var done = false;
  late Future<void> closing;
  await tester.runAsync(() async {
    closing = fixture.close().whenComplete(() => done = true);
  });
  for (var i = 0; i < 20 && !done; i++) {
    await matchingFrame(tester);
  }
  expect(done, isTrue, reason: 'Shutdown must finish pending UI-zone writes');
  await tester.runAsync(() => closing);
}

void runMatchingUiTests() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final width in [320.0, 800.0, 1280.0]) {
      testWidgets('cover control stays centered on $platform at $width px', (
        tester,
      ) async {
        final f = (await tester.runAsync(MatchingFixture.create))!;
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await closeMatchingFixture(tester, f);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: mumpaTheme().copyWith(platform: platform),
            home: Scaffold(
              body: CustomScrollView(
                slivers: [TrackList(app: f.app, tracks: f.tracks)],
              ),
            ),
          ),
        );
        await matchingFrame(tester);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        for (final id in ['mp3', 'next']) {
          final stack = find.byKey(ValueKey('track-cover-stack-$id'));
          final artwork = find.descendant(
            of: stack,
            matching: find.byType(TrackArtwork),
          );
          final cover = find.byKey(ValueKey('track-cover-play-$id'));
          await mouse.moveTo(tester.getCenter(artwork));
          await matchingFrame(tester);
          final icon = find.byKey(ValueKey('track-cover-icon-$id'));
          expect(icon, findsOneWidget);
          expect(
            (tester.getCenter(icon) - tester.getCenter(artwork)).distance,
            lessThan(.01),
            reason: 'The icon must share the front artwork center',
          );
          expect(tester.getSize(cover).shortestSide, greaterThanOrEqualTo(48));
        }
        await mouse.removePointer();
        expect(tester.takeException(), isNull);
      });
    }

    for (final grouped in [false, true]) {
      testWidgets('cover resumes the same file on $platform grouped=$grouped', (
        tester,
      ) async {
        final f = (await tester.runAsync(MatchingFixture.create))!;
        tester.view.physicalSize = const Size(800, 1280);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await closeMatchingFixture(tester, f);
        });
        final anchor = f.tracks[grouped ? 0 : 2];
        final selected = f.tracks[grouped ? 1 : 2];
        final collection = [anchor, f.tracks[3]];
        await tester.pumpWidget(
          MaterialApp(
            theme: mumpaTheme().copyWith(platform: platform),
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  TrackList(
                    app: f.app,
                    tracks: collection,
                    playlistId: f.playlist.id,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          await f.app.playCollection(
            collection,
            playlistId: f.playlist.id,
            selectedVariant: selected,
          );
          await f.app.playback.seek(const Duration(seconds: 13));
        });
        await matchingFrame(tester);
        final player = f.app.playback;
        final queue = player.queue.map((track) => track.id).toList();
        final revision = player.queueRevision;
        final cover = find.byKey(ValueKey('track-cover-play-${anchor.id}'));
        for (final playing in [false, true, false, true]) {
          await tester.runAsync(() async {
            await tester.tap(cover);
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          await matchingFrame(tester);
          expect(player.playing, playing);
          expect(player.current?.id, selected.id);
          expect(player.position, const Duration(seconds: 13));
          expect(player.queue.map((track) => track.id), queue);
          expect(player.queueRevision, revision);
          expect(player.contextPlaylistId, f.playlist.id);
        }
        expect(find.text('Выбрать версию'), findsNothing);
        expect(f.networkRequests, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'offline deletion requires confirmation and preserves the heart',
    (tester) async {
      final f = (await tester.runAsync(MatchingFixture.create))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await closeMatchingFixture(tester, f);
      });
      late Track saved;
      late File file;
      await tester.runAsync(() async {
        await f.app.library.downloads.create(recursive: true);
        file = await File(
          '${f.app.library.downloads.path}/saved.wav',
        ).writeAsBytes([1, 2, 3]);
        saved = Track(
          id: 'saved',
          title: 'Saved song',
          artist: 'Saved artist',
          album: 'Saved album',
          source: TrackSource.torrent,
          torrentHash: 'saved-source',
          torrentPath: 'saved.wav',
          cachedPath: file.path,
          bytes: 3,
        );
        await f.app.library.upsert([saved]);
        await f.app.library.toggleLike(saved.id);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: mumpaTheme(),
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                TrackList(app: f.app, tracks: [saved]),
              ],
            ),
          ),
        ),
      );
      await matchingFrame(tester);
      await tester.tap(find.byKey(const ValueKey('track-actions-saved')));
      await matchingFrame(tester);
      await tester.tap(find.text('Удалить офлайн-копию'));
      await matchingFrame(tester);
      expect(find.text('Удалить офлайн-копию?'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await matchingFrame(tester);
      expect(await tester.runAsync(file.exists), isTrue);
      expect(f.app.library.byId(saved.id)!.cachedPath, file.path);
      await tester.tap(find.byKey(const ValueKey('track-actions-saved')));
      await matchingFrame(tester);
      await tester.tap(find.text('Удалить офлайн-копию'));
      await matchingFrame(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Удалить копию'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await matchingFrame(tester);
      expect(await tester.runAsync(file.exists), isFalse);
      expect(f.app.library.byId(saved.id)!.cachedPath, isNull);
      expect(f.app.library.isTrackLiked(saved.id), isTrue);
      expect(f.networkRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'known variants, cover play and full filtered queue at $width px',
      (tester) async {
        final f = (await tester.runAsync(MatchingFixture.create))!;
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await closeMatchingFixture(tester, f);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: mumpaTheme(),
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  TrackList(
                    app: f.app,
                    tracks: [f.tracks[0]],
                    queueTracks: [f.tracks[0], f.tracks[2]],
                    playlistId: f.playlist.id,
                  ),
                ],
              ),
            ),
          ),
        );
        await matchingFrame(tester);
        final cover = find.byKey(const ValueKey('track-cover-play-mp3'));
        final icon = find.byKey(const ValueKey('track-cover-icon-mp3'));
        expect(icon, findsNothing);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(0, 0));
        await mouse.moveTo(tester.getCenter(cover));
        await matchingFrame(tester);
        expect(icon, findsOneWidget);
        await mouse.moveTo(const Offset(0, 0));
        await matchingFrame(tester);
        expect(icon, findsNothing);
        expect(
          find.byKey(const ValueKey('track-cover-layer-flac')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('track-row-flac')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('track-versions-mp3')));
        await matchingFrame(tester);
        expect(find.text('Выбрать версию'), findsOneWidget);
        expect(find.textContaining('FLAC · lossless'), findsOneWidget);
        expect(find.textContaining('MP3 · lossy'), findsOneWidget);
        expect(find.textContaining('3:10'), findsOneWidget);
        expect(find.text('MP3 · lossy · 2:58'), findsOneWidget);
        expect(find.byKey(const ValueKey('known-version-live')), findsNothing);
        expect(f.app.playback.current, isNull);
        await tester.ensureVisible(
          find.byKey(const ValueKey('play-known-version-flac')),
        );
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('play-known-version-flac')),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await matchingFrame(tester);
        expect(f.app.playback.current?.id, 'flac');
        expect(
          f.backend.opened,
          Uri.file(f.tracks[1].localPath!).toString(),
          reason: f.app.playback.error,
        );
        expect(f.app.playback.queue.map((track) => track.id), ['flac', 'next']);
        expect(f.app.playback.contextPlaylistId, f.playlist.id);
        expect(f.app.library.playlists.single.trackIds, ['mp3', 'next']);
        expect(icon, findsOneWidget);
        expect(
          find.descendant(
            of: cover,
            matching: find.byIcon(Icons.pause_rounded),
          ),
          findsOneWidget,
        );
        var pauseDone = false;
        late Future<void> paused;
        await tester.runAsync(() async {
          paused = f.app.playback.pause().whenComplete(() => pauseDone = true);
        });
        for (var i = 0; i < 20 && !pauseDone; i++) {
          await matchingFrame(tester);
        }
        expect(pauseDone, isTrue);
        await tester.runAsync(() => paused);
        await matchingFrame(tester);
        expect(icon, findsNothing);
        await mouse.removePointer();

        // The small cover resumes the selected alternative without a picker.
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('track-cover-play-mp3')));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await matchingFrame(tester);
        expect(find.text('Выбрать версию'), findsNothing);
        expect(f.app.playback.current?.id, 'flac');
        expect(f.app.playback.playing, isTrue);
        expect(f.networkRequests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('default survives replay; wrong match separates and can rejoin', (
    tester,
  ) async {
    final f = (await tester.runAsync(MatchingFixture.create))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await closeMatchingFixture(tester, f);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: mumpaTheme(),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [TrackList(app: f.app, tracks: f.tracks)],
          ),
        ),
      ),
    );
    await matchingFrame(tester);
    expect(find.byKey(const ValueKey('track-row-flac')), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('track-title-mp3')),
      warnIfMissed: false,
    );
    await matchingFrame(tester);
    expect(find.text('Выбрать версию'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('prefer-version-flac')),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('prefer-version-flac')));
    });
    await matchingFrame(tester);
    expect(f.app.library.isPreferredVariant('flac'), isTrue);
    await tester.tap(find.byKey(const ValueKey('track-versions-close')));
    await matchingFrame(tester);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('track-cover-play-mp3')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await matchingFrame(tester);
    expect(f.app.playback.current?.id, 'flac');
    expect(f.app.playback.queue.map((track) => track.id), [
      'flac',
      'next',
      'live',
    ]);
    await tester.tap(find.byKey(const ValueKey('track-versions-mp3')));
    await matchingFrame(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('separate-version-flac')),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('separate-version-flac')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await matchingFrame(tester);
    expect(find.byKey(const ValueKey('track-row-flac')), findsOneWidget);
    expect(find.byKey(const ValueKey('track-versions-mp3')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('track-actions-flac')));
    await matchingFrame(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('Снова объединять похожие версии'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await matchingFrame(tester);
    expect(find.byKey(const ValueKey('track-row-flac')), findsNothing);
    expect(f.networkRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

void main() => runMatchingUiTests();
