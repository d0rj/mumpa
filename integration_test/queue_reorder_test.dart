// Opt-in Windows proof using original local WAV files and the real libmpv.
// No production profile, torrent engine or external metadata is accessed.
import 'package:mumpa/logic/audio_runtime.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/rutracker_service.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/player.dart';
import 'package:path/path.dart' as p;

Uint8List _originalWav(int tone) {
  const rate = 8000;
  final bytes = Uint8List(44 + rate * 2 * 20);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  for (var offset = 44; offset < bytes.length; offset += 2) {
    final sample = (offset - 44) ~/ 2;
    final value = math.sin(2 * math.pi * tone * sample / rate);
    data.setInt16(offset, (value * 5000).round(), Endian.little);
  }
  return bytes;
}

class _NetworkGuard {
  int httpRequests = 0, engineStarts = 0;
  MockClient client() => MockClient((_) async {
    httpRequests++;
    throw StateError('The queue fixture must not send HTTP.');
  });
}

class _OfflineMetadata extends MusicMetadataRepository {
  _OfflineMetadata(Directory root, _NetworkGuard guard)
    : super(
        cache: DiskMediaCache(Directory(p.join(root.path, 'metadata'))),
        client: guard.client(),
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

class _ObservedNativeAudio extends NativeAudioBackend {
  int opens = 0, stops = 0, seeks = 0;
  final openedFiles = <String>[];

  Map<String, int> get counts => {'open': opens, 'stop': stops, 'seek': seeks};
  @override
  Future<void> open(
    String uri, {
    bool play = true,
    Duration start = Duration.zero,
  }) async {
    opens++;
    openedFiles.add(p.basename(Uri.parse(uri).toFilePath()));
    await super.open(uri, play: play, start: start);
  }

  @override
  Future<void> stop() async {
    stops++;
    await super.stop();
  }

  @override
  Future<void> seek(Duration value) async {
    seeks++;
    await super.seek(value);
  }
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() ready, {
  String condition = 'native playback',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Queue fixture: $condition');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Deliver a mouse drag through the UI handle, never through moveQueue.
Future<void> _mouseDrag(
  WidgetTester tester, {
  required int entry,
  required int targetEntry,
  required bool before,
}) async {
  final handle = find.byKey(ValueKey('queue-drag-$entry'));
  final row = find.byKey(ValueKey('queue-entry-$targetEntry'));
  expect(handle, findsOneWidget);
  expect(row, findsOneWidget);
  final start = tester.getCenter(handle);
  final target = tester.getRect(row);
  final finish = Offset(start.dx, before ? target.top + 8 : target.bottom - 8);
  final gesture = await tester.startGesture(
    start,
    kind: ui.PointerDeviceKind.mouse,
  );
  var released = false;
  try {
    await tester.pump();
    for (var step = 1; step <= 16; step++) {
      await gesture.moveTo(Offset.lerp(start, finish, step / 16)!);
      await tester.pump(const Duration(milliseconds: 25));
    }
    await gesture.up();
    released = true;
    await tester.pumpAndSettle();
  } finally {
    if (!released) await gesture.up();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('QUEUE_REORDER_TEST');
  if (enabled && Platform.isWindows) initializeAudioRuntime();
  testWidgets(
    'native queue drags retain decoder position and change the next successor',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('mumpa-queue-native-');
      final library = LibraryRepository(root);
      await library.load();
      await library.setSetting('autoCache', false);
      await library.setSetting('volume', 0.0);
      final tracks = <Track>[];
      for (var index = 0; index < 5; index++) {
        final file = await File(
          p.join(root.path, 'queue-$index.wav'),
        ).writeAsBytes(_originalWav(180 + index * 35));
        tracks.add(
          Track(
            id: 'fixture-$index',
            title: 'Queue tone ${index + 1}',
            artist: 'Original fixture',
            album: 'Native queue fixture',
            source: TrackSource.local,
            localPath: file.path,
            number: index + 1,
            durationMs: 20000,
            bytes: await file.length(),
          ),
        );
      }
      await library.upsert(tracks);
      final guard = _NetworkGuard();
      final torrents = TorrentService(
        client: guard.client(),
        audioClientFactory: guard.client,
        endpoint: () async {
          guard.engineStarts++;
          throw StateError(
            'The queue fixture must not start a torrent engine.',
          );
        },
      );
      final backend = _ObservedNativeAudio();
      expect(backend.player.platform, isA<NativePlayer>());
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
        indexer: IndexerService(client: guard.client()),
        catalog: RuTrackerService(
          transport: HttpCatalogTransport(client: guard.client()),
        ),
        metadata: _OfflineMetadata(root, guard),
      );
      final screenshot = GlobalKey();
      try {
        app.navigate(AppPage.library);
        await tester.pumpWidget(
          RepaintBoundary(
            key: screenshot,
            child: MumpaApp(controller: app),
          ),
        );
        await tester.pump();
        await playback.playTracks(tracks, index: 1);
        await _wait(
          tester,
          () => playback.playing && playback.position.inMilliseconds >= 500,
        );
        await playback.pause();
        await playback.seek(const Duration(seconds: 2));
        await _wait(
          tester,
          () =>
              !playback.playing &&
              (playback.position.inMilliseconds - 2000).abs() <= 100,
          condition: 'paused seek',
        );
        final positionBefore = playback.position;
        final callsBefore = backend.counts;
        expect(playback.queueEntryKeys, [0, 1, 2, 3, 4]);
        expect(backend.opens, 1);
        expect(backend.openedFiles, ['queue-1.wav']);
        unawaited(
          showNowPlaying(tester.element(find.byType(AppScreen)), app, tab: 1),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('playback-queue')), findsOneWidget);

        await _mouseDrag(tester, entry: 4, targetEntry: 0, before: true);
        expect(playback.queueEntryKeys, [4, 0, 1, 2, 3]);
        expect(playback.current?.id, tracks[1].id);
        expect(playback.index, 2);
        expect(playback.playing, isFalse);
        expect(backend.counts, callsBefore);
        final positionAfterFutureDrag = playback.position;
        expect(
          (positionAfterFutureDrag - positionBefore).inMilliseconds.abs(),
          lessThanOrEqualTo(100),
        );

        await _mouseDrag(tester, entry: 1, targetEntry: 2, before: false);
        expect(playback.queueEntryKeys, [4, 0, 2, 1, 3]);
        expect(playback.current?.id, tracks[1].id);
        expect(playback.index, 3);
        expect(playback.playing, isFalse);
        expect(backend.counts, callsBefore);
        final positionAfterCurrentDrag = playback.position;
        expect(
          (positionAfterCurrentDrag - positionBefore).inMilliseconds.abs(),
          lessThanOrEqualTo(100),
        );
        final orderAfterDrag = List<int>.of(playback.queueEntryKeys);
        final callsAfterDrag = backend.counts;
        await playback.play();
        await _wait(
          tester,
          () =>
              playback.playing &&
              playback.position >
                  positionAfterCurrentDrag + const Duration(milliseconds: 400),
          condition: 'resume after current-entry drag',
        );
        final resumedPosition = playback.position;
        expect(playback.current?.id, tracks[1].id);
        expect(playback.index, 3);
        expect(backend.counts, callsBefore);
        await playback.next();
        await _wait(
          tester,
          () =>
              playback.current?.id == tracks[3].id &&
              playback.playing &&
              playback.position.inMilliseconds >= 400,
          condition: 'new queue successor',
        );
        expect(playback.index, 4);
        expect(backend.opens, callsBefore['open']! + 1);
        expect(backend.stops, callsBefore['stop']! + 1);
        expect(backend.seeks, callsBefore['seek']);
        expect(backend.openedFiles, ['queue-1.wav', 'queue-3.wav']);
        expect(guard.httpRequests, 0);
        expect(guard.engineStarts, 0);
        expect(tester.takeException(), isNull);

        final output = Directory('test-output');
        await output.create(recursive: true);
        await tester.pump();
        final image =
            await (screenshot.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          p.join(output.path, 'queue-reorder-1.2.6.png'),
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        await File(
          p.join(output.path, 'queue-reorder-1.2.6.json'),
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'passed': true,
            'nativeAudio': true,
            'mouseHandleDrags': 2,
            'initialOrder': [0, 1, 2, 3, 4],
            'afterFutureDrag': [4, 0, 1, 2, 3],
            'afterCurrentDrag': orderAfterDrag,
            'currentEntryAfterDrag': 1,
            'currentIndexAfterDrag': 3,
            'positionBeforeDragMs': positionBefore.inMilliseconds,
            'positionAfterFutureDragMs': positionAfterFutureDrag.inMilliseconds,
            'positionAfterCurrentDragMs':
                positionAfterCurrentDrag.inMilliseconds,
            'resumedPositionMs': resumedPosition.inMilliseconds,
            'nextTrack': playback.current!.id,
            'nextPositionMs': playback.position.inMilliseconds,
            'decoderCallsBeforeDrag': callsBefore,
            'decoderCallsAfterDrag': callsAfterDrag,
            'decoderCallsAfterNext': backend.counts,
            'httpRequests': guard.httpRequests,
            'engineStarts': guard.engineStarts,
          }),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await app.shutdown();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !enabled || !Platform.isWindows,
  );
}
