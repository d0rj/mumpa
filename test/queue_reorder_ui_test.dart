import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/player.dart';

import 'support.dart';

const _position = Duration(seconds: 7, milliseconds: 350);
const _playlistContext = 'isolated-queue-context';

class _Audio extends FakeAudioBackend {
  int opens = 0;
  int stops = 0;
  int seeks = 0;

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

// Queue persistence has separate controller tests. Avoid unrelated disk writes
// inside the widget fake clock while exercising the production queue methods.
class _UiPlayback extends PlaybackController {
  _UiPlayback({
    required super.library,
    required super.torrents,
    required super.backend,
  });

  @override
  Future<void> saveSession() async {}
}

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
  @override
  Future<String?> coverForGroup(String id) async => null;
  @override
  Future<String?> coverForReleaseTitle(String title) async => null;
}

class _Fixture {
  _Fixture(
    this.root,
    this.app,
    this.audio,
    this.originalKeys,
    this.initialOpens,
    this.initialStops,
    this.initialSeeks,
  );

  final Directory root;
  final AppController app;
  final _Audio audio;
  final List<int> originalKeys;
  final int initialOpens, initialStops, initialSeeks;
  int unexpectedHttp = 0;
  int engineStarts = 0;
  PlaybackController get player => app.playback;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'mumpa-queue-reorder-ui-',
    );
    final library = LibraryRepository(root);
    await library.load();
    await library.setSetting('autoCache', false);
    final tracks = <Track>[];
    for (final id in ['a', 'b', 'c', 'd']) {
      final file = await File('${root.path}/$id.wav').writeAsBytes([0]);
      tracks.add(
        Track(
          id: id,
          title: 'Track ${id.toUpperCase()}',
          artist: 'Queue Artist',
          album: 'Queue Album',
          source: TrackSource.local,
          localPath: file.path,
        ),
      );
    }
    await library.upsert(tracks);
    late _Fixture fixture;
    MockClient offlineClient() => MockClient((_) async {
      fixture.unexpectedHttp++;
      throw StateError('Queue interaction must never send HTTP');
    });
    final torrents = TorrentService(
      client: offlineClient(),
      endpoint: () async {
        fixture.engineStarts++;
        throw StateError('Queue interaction must never start a torrent engine');
      },
    );
    final audio = _Audio();
    final player = _UiPlayback(
      library: library,
      torrents: torrents,
      backend: audio,
    );
    await player.initialize(platformAudio: false);
    final app = AppController(
      library: library,
      playback: player,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
      indexer: IndexerService(client: offlineClient()),
      metadata: _Metadata(root, offlineClient()),
    );
    // Track A occurs twice; these are two independently movable queue entries.
    await player.playTracks(
      [tracks[0], tracks[1], tracks[2], tracks[0], tracks[3]],
      index: 1,
      contextPlaylistId: _playlistContext,
    );
    await player.seek(_position);
    await library.flush();
    fixture = _Fixture(
      root,
      app,
      audio,
      List.of(player.queueEntryKeys),
      audio.opens,
      audio.stops,
      audio.seeks,
    );
    app.navigate(AppPage.library);
    return fixture;
  }

  void expectUninterrupted({required int selectedIndex}) {
    expect(player.current!.id, 'b');
    expect(player.index, selectedIndex);
    expect(player.position, _position);
    expect(player.playing, isTrue);
    expect(player.contextPlaylistId, _playlistContext);
    expect(
      audio.opens,
      initialOpens,
      reason: 'Reordering must not reopen audio',
    );
    expect(audio.stops, initialStops, reason: 'Reordering must not stop audio');
    expect(
      audio.seeks,
      initialSeeks,
      reason: 'Reordering must not reset position',
    );
    expect(unexpectedHttp, 0);
    expect(engineStarts, 0);
  }
}

Finder _queue() => find.byKey(const ValueKey('playback-queue'));
Finder _row(int key) => find.byKey(ValueKey('queue-entry-$key'));
Finder _handle(int key) => find.byKey(ValueKey('queue-drag-$key'));
Finder _actions(int key) => find.byKey(ValueKey('queue-actions-$key'));

// Actual playback decorations can animate indefinitely. Pump the meaningful
// modal, drag and popup transitions without waiting for all tickers to stop.
Future<void> _settleTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<_Fixture> _mount(WidgetTester tester, double width) async {
  final fixture = (await tester.runAsync(_Fixture.create))!;
  tester.view.physicalSize = Size(width, 900);
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
  await tester.pumpWidget(MumpaApp(controller: fixture.app));
  await _settleTransition(tester);
  unawaited(
    showNowPlaying(tester.element(find.byType(PlayerBar)), fixture.app, tab: 1),
  );
  await _settleTransition(tester);
  expect(_queue(), findsOneWidget);
  expect(fixture.originalKeys, hasLength(5));
  expect(fixture.originalKeys.toSet(), hasLength(5));
  for (final key in fixture.originalKeys) {
    expect(_row(key), findsOneWidget);
    expect(
      tester.widget<ReorderableDragStartListener>(_handle(key)).index,
      fixture.originalKeys.indexOf(key),
    );
    final size = tester.getSize(_handle(key));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  }
  fixture.expectUninterrupted(selectedIndex: 1);
  expect(tester.takeException(), isNull);
  return fixture;
}

Future<void> _dragTo(
  WidgetTester tester,
  int key,
  Offset destination,
  PointerDeviceKind kind,
) async {
  final origin = tester.getCenter(_handle(key));
  final gesture = await tester.startGesture(origin, kind: kind);
  await tester.pump();
  final direction = destination.dy > origin.dy ? 1.0 : -1.0;
  final lift = origin + Offset(0, 24 * direction);
  await gesture.moveTo(lift);
  await tester.pump(const Duration(milliseconds: 100));
  for (var step = 1; step <= 8; step++) {
    await gesture.moveTo(Offset.lerp(lift, destination, step / 8)!);
    await tester.pump(const Duration(milliseconds: 60));
  }
  await tester.pump(const Duration(milliseconds: 200));
  await gesture.up();
  await _settleTransition(tester);
}

Future<void> _menu(WidgetTester tester, int key) async {
  await tester.tap(_actions(key));
  await _settleTransition(tester);
}

Finder _menuItem(String value) => find.byWidgetPredicate(
  (widget) => widget is PopupMenuItem<String> && widget.value == value,
);

Future<void> _choose(WidgetTester tester, int key, String value) async {
  await _menu(tester, key);
  expect(
    tester.widget<PopupMenuItem<String>>(_menuItem(value)).enabled,
    isTrue,
  );
  await tester.tap(_menuItem(value));
  await _settleTransition(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final width in [320.0, 1200.0]) {
    final kind = width == 320
        ? PointerDeviceKind.touch
        : PointerDeviceKind.mouse;
    testWidgets('queue drag moves a future occurrence upward at $width px', (
      tester,
    ) async {
      final fixture = await _mount(tester, width);
      final keys = fixture.originalKeys;
      final destination = tester.getRect(_row(keys[2]));
      await _dragTo(
        tester,
        keys[4],
        Offset(
          tester.getCenter(_handle(keys[4])).dx,
          destination.center.dy + 6,
        ),
        kind,
      );
      expect(fixture.player.queueEntryKeys, [
        keys[0],
        keys[1],
        keys[4],
        keys[2],
        keys[3],
      ]);
      expect(fixture.player.queue.map((track) => track.id), [
        'a',
        'b',
        'd',
        'c',
        'a',
      ]);
      fixture.expectUninterrupted(selectedIndex: 1);
      for (final key in keys) {
        expect(_row(key), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'queue drag moves current occurrence to the final slot at $width px',
      (tester) async {
        final fixture = await _mount(tester, width);
        final keys = fixture.originalKeys;
        final last = tester.getRect(_row(keys.last));
        final viewport = tester.getRect(_queue());
        final destination = Offset(
          tester.getCenter(_handle(keys[1])).dx,
          (last.bottom + 20)
              .clamp(viewport.top + 20, viewport.bottom - 20)
              .toDouble(),
        );
        await _dragTo(tester, keys[1], destination, kind);
        expect(fixture.player.queueEntryKeys, [
          keys[0],
          keys[2],
          keys[3],
          keys[4],
          keys[1],
        ]);
        expect(fixture.player.queue.map((track) => track.id), [
          'a',
          'c',
          'a',
          'd',
          'b',
        ]);
        fixture.expectUninterrupted(selectedIndex: 4);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'accessible queue actions move both ways and disable bounds at $width px',
      (tester) async {
        final fixture = await _mount(tester, width);
        final keys = fixture.originalKeys;
        await _choose(tester, keys[2], 'up');
        expect(fixture.player.queueEntryKeys, [
          keys[0],
          keys[2],
          keys[1],
          keys[3],
          keys[4],
        ]);
        fixture.expectUninterrupted(selectedIndex: 2);
        await _choose(tester, keys[2], 'down');
        expect(fixture.player.queueEntryKeys, keys);
        fixture.expectUninterrupted(selectedIndex: 1);
        await _menu(tester, keys.first);
        expect(find.text('Выше в очереди'), findsOneWidget);
        expect(
          tester.widget<PopupMenuItem<String>>(_menuItem('up')).enabled,
          isFalse,
        );
        expect(
          tester.widget<PopupMenuItem<String>>(_menuItem('down')).enabled,
          isTrue,
        );
        await tester.tapAt(const Offset(3, 3));
        await _settleTransition(tester);
        await _menu(tester, keys.last);
        expect(find.text('Ниже в очереди'), findsOneWidget);
        expect(
          tester.widget<PopupMenuItem<String>>(_menuItem('down')).enabled,
          isFalse,
        );
        expect(
          tester.widget<PopupMenuItem<String>>(_menuItem('up')).enabled,
          isTrue,
        );
        await tester.tapAt(const Offset(3, 3));
        await _settleTransition(tester);
        expect(fixture.player.queueEntryKeys, keys);
        fixture.expectUninterrupted(selectedIndex: 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'removing one duplicate keeps the other occurrence movable at $width px',
      (tester) async {
        final fixture = await _mount(tester, width);
        final keys = fixture.originalKeys;
        final remove = find.descendant(
          of: _row(keys[0]),
          matching: find.byTooltip('Убрать из очереди'),
        );
        await tester.tap(remove);
        await _settleTransition(tester);
        expect(_row(keys[0]), findsNothing);
        expect(_row(keys[3]), findsOneWidget);
        expect(fixture.player.queueEntryKeys, [
          keys[1],
          keys[2],
          keys[3],
          keys[4],
        ]);
        expect(fixture.player.queue.map((track) => track.id), [
          'b',
          'c',
          'a',
          'd',
        ]);
        fixture.expectUninterrupted(selectedIndex: 0);
        await _choose(tester, keys[3], 'down');
        expect(fixture.player.queueEntryKeys, [
          keys[1],
          keys[2],
          keys[4],
          keys[3],
        ]);
        expect(fixture.player.queue.map((track) => track.id), [
          'b',
          'c',
          'd',
          'a',
        ]);
        fixture.expectUninterrupted(selectedIndex: 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
