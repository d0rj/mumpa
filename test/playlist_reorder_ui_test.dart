import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
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
import 'package:mumpa/ui/pages.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

// Drop animations invoke callbacks in the widget fake clock. Run the actual
// repository method in the I/O zone captured by tester.runAsync so disk writes
// can also be awaited by restart checks and teardown.
class _UiLibrary extends LibraryRepository {
  _UiLibrary(super.root) : _ioZone = Zone.current;
  final Zone _ioZone;
  @override
  Future<void> movePlaylistTrack(String id, int from, int to) =>
      _ioZone.run(() => super.movePlaylistTrack(id, from, to));
  @override
  Future<void> movePlaylistTrackGroup(
    String id,
    Set<String> moving,
    Set<String> target, {
    required bool after,
  }) => _ioZone.run(
    () => super.movePlaylistTrackGroup(id, moving, target, after: after),
  );
}

class _Audio extends FakeAudioBackend {
  int opens = 0, stops = 0, seeks = 0;
  @override
  Future<void> open(String uri, {bool play = true}) async {
    opens++;
    await super.open(uri, play: play);
  }

  @override
  Future<void> stop() async {
    stops++;
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    seeks++;
    await super.seek(position);
  }
}

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
  _Fixture(this.root, this.app, this.audio, this.playlist);
  final Directory root;
  final AppController app;
  final _Audio audio;
  final MusicPlaylist playlist;
  Iterable<String> get ids => app.playlist!.trackIds;
  static Future<_Fixture> create({bool collection = false}) async {
    final root = await Directory.systemTemp.createTemp(
      'mumpa-playlist-order-ui-',
    );
    final library = _UiLibrary(root);
    await library.load();
    await library.setSetting('autoCache', false);
    final file = await File('${root.path}/song.wav').writeAsBytes([0]);
    final tracks = [
      for (final id in ['a', 'variant', 'b', 'c', 'd'])
        Track(
          id: id,
          title: id == 'variant' ? 'Song a' : 'Song $id',
          artist: 'Band',
          album: id == 'c' || id == 'd' ? 'Second album' : 'First album',
          source: TrackSource.local,
          localPath: file.path,
        ),
    ];
    await library.upsert(tracks);
    final playlist = collection
        ? await library.openSourceCollection(
            hash: 'source',
            name: 'Collection',
            tracks: tracks,
          )
        : await library.createPlaylist('My playlist');
    if (!collection) {
      await library.addToPlaylist(playlist.id, [
        'a',
        'missing',
        'variant',
        'b',
        'c',
        'd',
      ]);
    }
    final torrents = TorrentService(
      endpoint: () async => throw StateError('No engine expected'),
    );
    final audio = _Audio();
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: audio,
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
    app.openPlaylist(playlist);
    await app.playCollection(
      app.playlistTracks,
      index: 2,
      playlistId: playlist.id,
    );
    await playback.seek(const Duration(seconds: 7));
    await playback.pause();
    await library.flush();
    return _Fixture(root, app, audio, playlist);
  }
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<_Fixture> _mount(
  WidgetTester tester,
  double width, {
  bool collection = false,
}) async {
  final fixture = (await tester.runAsync(
    () => _Fixture.create(collection: collection),
  ))!;
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await fixture.app.shutdown();
      fixture.app.library.dispose();
      await fixture.root.delete(recursive: true);
    });
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: mumpaTheme(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: fixture.app,
          builder: (_, _) => ContentPage(app: fixture.app),
        ),
      ),
    ),
  );
  await _pump(tester);
  return fixture;
}

Finder _row(String id) => find.byKey(ValueKey('track-row-$id'));
Finder _handle(String id) => find.byKey(ValueKey('playlist-drag-$id'));
Finder _item(String value) => find.byWidgetPredicate(
  (w) => w is PopupMenuItem<String> && w.value == value,
);

Future<void> _drag(
  WidgetTester tester,
  String id,
  Offset target,
  PointerDeviceKind kind,
) async {
  final origin = tester.getCenter(_handle(id));
  final gesture = await tester.startGesture(origin, kind: kind);
  await tester.pump();
  final lift = origin + Offset(0, target.dy > origin.dy ? 24 : -24);
  await gesture.moveTo(lift);
  await tester.pump(const Duration(milliseconds: 100));
  for (var step = 1; step <= 8; step++) {
    await gesture.moveTo(Offset.lerp(lift, target, step / 8)!);
    await tester.pump(const Duration(milliseconds: 60));
  }
  await tester.runAsync(() async {
    await gesture.up();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await _pump(tester);
}

Future<void> _choose(WidgetTester tester, String value) async {
  await tester.runAsync(() async {
    await tester.tap(_item(value));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await _pump(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final width in [320.0, 1200.0]) {
    final kind = width == 320
        ? PointerDeviceKind.touch
        : PointerDeviceKind.mouse;
    testWidgets(
      'playlist drag persists both directions without interrupting audio at $width',
      (tester) async {
        final f = await _mount(tester, width);
        final player = f.app.playback;
        final queue = player.queue.map((t) => t.id).toList();
        final counters = (f.audio.opens, f.audio.stops, f.audio.seeks);
        expect(find.byKey(const ValueKey('playlist-edit-order')), findsNothing);
        expect(_row('variant'), findsNothing);
        expect(find.byKey(const ValueKey('track-versions-a')), findsOneWidget);
        expect(find.byKey(const ValueKey('collection-search')), findsOneWidget);
        expect(tester.getSize(_handle('d')), const Size(48, 48));
        await tester.ensureVisible(_row('d'));
        final first = tester.getRect(_row('a'));
        await _drag(
          tester,
          'd',
          Offset(tester.getCenter(_handle('d')).dx, first.top + 2),
          kind,
        );
        expect(f.ids, ['d', 'a', 'missing', 'variant', 'b', 'c']);
        final last = tester.getRect(_row('c'));
        await _drag(
          tester,
          'd',
          Offset(tester.getCenter(_handle('d')).dx, last.bottom - 2),
          kind,
        );
        expect(f.ids, ['a', 'missing', 'variant', 'b', 'c', 'd']);
        final next = tester.getRect(_row('b'));
        await _drag(
          tester,
          'a',
          Offset(tester.getCenter(_handle('a')).dx, next.bottom - 2),
          kind,
        );
        expect(f.ids, ['missing', 'b', 'a', 'variant', 'c', 'd']);
        expect(_row('variant'), findsNothing);
        expect(find.byKey(const ValueKey('track-versions-a')), findsOneWidget);
        expect(player.queue.map((t) => t.id), queue);
        expect(player.current!.id, 'b');
        expect(player.position, const Duration(seconds: 7));
        expect(player.playing, isFalse);
        expect((f.audio.opens, f.audio.stops, f.audio.seeks), counters);
        await tester.runAsync(() async {
          await f.app.library.flush();
          final restored = LibraryRepository(f.root);
          await restored.load();
          expect(restored.playlists.single.trackIds, f.ids);
          restored.dispose();
        });
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'playlist direct drag and menus preserve filtered and hidden tracks at $width',
      (tester) async {
        final f = await _mount(tester, width);
        final field = find.byKey(const ValueKey('collection-search'));
        await tester.ensureVisible(field);
        await tester.enterText(field, 'Second album');
        await _pump(tester);
        expect(_row('a'), findsNothing);
        expect(_handle('c'), findsOneWidget);
        await tester.ensureVisible(_row('d'));
        final first = tester.getRect(_row('c'));
        await _drag(
          tester,
          'd',
          Offset(tester.getCenter(_handle('d')).dx, first.top + 2),
          kind,
        );
        expect(f.ids, ['a', 'missing', 'variant', 'b', 'd', 'c']);
        expect(
          tester.widget<TextField>(field).controller!.text,
          'Second album',
        );
        await tester.tap(find.byKey(const ValueKey('track-actions-d')));
        await _pump(tester);
        expect(
          tester.widget<PopupMenuItem<String>>(_item('moveUp')).enabled,
          isFalse,
        );
        await _choose(tester, 'moveDown');
        expect(f.ids, ['a', 'missing', 'variant', 'b', 'c', 'd']);
        await tester.ensureVisible(_row('d'));
        await tester.tap(find.byKey(const ValueKey('track-actions-d')));
        await _pump(tester);
        await _choose(tester, 'moveUp');
        expect(f.ids, ['a', 'missing', 'variant', 'b', 'd', 'c']);
        expect(
          tester.widget<TextField>(field).controller!.text,
          'Second album',
        );
        expect(_row('c'), findsOneWidget);
        expect(_handle('c'), findsOneWidget);
        expect(_row('a'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('collection-search-clear')));
        await _pump(tester);
        await tester.ensureVisible(
          find.byKey(const ValueKey('play-collection')),
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('play-collection')));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await _pump(tester);
        expect(f.app.playback.queue.map((t) => t.id), ['a', 'b', 'd', 'c']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'collection track view has direct handles and preserves album view',
    (tester) async {
      final f = await _mount(tester, 1200, collection: true);
      expect(
        find.byKey(const ValueKey('collection-albums-view')),
        findsOneWidget,
      );
      expect(_row('a'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('collection-tracks-view')));
      await _pump(tester);
      expect(_row('a'), findsOneWidget);
      expect(_row('variant'), findsNothing);
      expect(_handle('a'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('track-actions-d')));
      await _pump(tester);
      expect(
        tester.widget<PopupMenuItem<String>>(_item('moveDown')).enabled,
        isFalse,
      );
      await _choose(tester, 'moveUp');
      expect(f.ids, ['a', 'variant', 'b', 'd', 'c']);
      await tester.ensureVisible(
        find.byKey(const ValueKey('collection-albums-view')),
      );
      await tester.tap(find.byKey(const ValueKey('collection-albums-view')));
      await _pump(tester);
      expect(_row('a'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
