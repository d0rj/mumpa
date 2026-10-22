import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'test_artifacts.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/audio_runtime.dart';
import 'package:mumpa/logic/playback_controller.dart';

Uint8List _wav() {
  final bytes = Uint8List(44 + 8000 * 2 * 60);
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
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String description,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException(description);
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  initializeAudioRuntime();
  testWidgets('first Play restores the saved decoder position after restart', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('mumpa-resume-native-');
    final torrents = TorrentService(
      endpoint: () async =>
          throw StateError('Local audio must not use torrents'),
    );
    LibraryRepository? library;
    PlaybackController? controller;
    final report = <Map<String, Object?>>[];
    try {
      final file = File('${root.path}/local.wav');
      await file.writeAsBytes(_wav());
      library = LibraryRepository(Directory('${root.path}/profile'));
      await library.load();
      await library.upsert([
        for (final id in ['first', 'selected-version'])
          Track(
            id: id,
            title: id,
            artist: 'Resume fixture',
            album: 'Resume',
            source: TrackSource.local,
            localPath: file.path,
            durationMs: 60000,
          ),
      ]);
      final playlist = await library.createPlaylist('Saved queue');
      await library.addToPlaylist(playlist.id, ['first', 'selected-version']);
      await library.setSetting('playback', {
        'originalIds': ['first', 'selected-version', 'first'],
        'order': [2, 1, 0],
        'unshuffledOrder': [0, 1, 2],
        'index': 1,
        'position': 21750,
        'repeat': 'all',
        'shuffle': true,
        'contextPlaylistId': playlist.id,
        'radioEntries': <int>[],
      });
      await library.flush();
      library.dispose();
      library = null;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Saved-position regression')),
          ),
        ),
      );
      for (final cycle in [1, 2]) {
        library = LibraryRepository(Directory('${root.path}/profile'));
        await library.load();
        final session = Map<String, dynamic>.from(
          library.settings['playback'] as Map,
        );
        final saved = session['position'] as int;
        final audio = NativeAudioBackend();
        // Exercise the same DSP configuration path as ordinary application startup.
        await library.setSetting('monoAudio', true);
        controller = PlaybackController(
          library: library,
          torrents: torrents,
          backend: audio,
        );
        await controller.initialize(platformAudio: false);
        expect(controller.current!.id, 'selected-version');
        expect(controller.position.inMilliseconds, saved);
        expect(controller.playing, isFalse);
        expect(audio.position, Duration.zero);
        final positions = <int>[];
        void observe() {
          if (audio.position > Duration.zero) {
            positions.add(audio.position.inMilliseconds);
          }
        }

        audio.addListener(observe);
        await controller.play();
        await _until(tester, () => positions.isNotEmpty, 'No decoder position');
        expect(positions.first, greaterThanOrEqualTo(saved - 100));
        expect(positions.first, lessThan(saved + 1500));
        await _until(
          tester,
          () => audio.position.inMilliseconds >= saved + 600,
          'Decoder failed to resume beyond $saved ms',
        );
        await controller.pause();
        final paused = controller.position.inMilliseconds;
        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.position.inMilliseconds, closeTo(paused, 100));
        await controller.play();
        await _until(
          tester,
          () => audio.position.inMilliseconds >= paused + 400,
          'Pause/Resume did not preserve the decoder position',
        );
        await controller.pause();
        expect(controller.current!.id, 'selected-version');
        expect(controller.queueEntryKeys, [2, 1, 0]);
        expect(controller.contextPlaylistId, playlist.id);
        expect(controller.shuffle, isTrue);
        expect(controller.repeat, PlayerRepeatMode.all);
        final persisted = Map<String, dynamic>.from(
          library.settings['playback'] as Map,
        );
        expect(persisted['position'], greaterThan(saved));
        expect(persisted['originalIds'], session['originalIds']);
        expect(persisted['order'], session['order']);
        expect(persisted['unshuffledOrder'], session['unshuffledOrder']);
        expect(library.trackPlayCount('selected-version'), cycle);
        // Read the actual file before Close can hide an early, stale snapshot.
        final resumeAt = controller.position;
        await controller.seek(const Duration(milliseconds: 11250));
        await library.flush();
        final afterBack =
            jsonDecode(
                  await File(
                    '${library.root.path}/library.json',
                  ).readAsString(),
                )
                as Map;
        expect(
          afterBack['settings']['playback']['position'],
          closeTo(11250, 250),
        );
        await controller.seek(resumeAt);
        await library.flush();
        final afterForward =
            jsonDecode(
                  await File(
                    '${library.root.path}/library.json',
                  ).readAsString(),
                )
                as Map;
        expect(
          afterForward['settings']['playback']['position'],
          closeTo(resumeAt.inMilliseconds, 250),
        );
        report.add({
          'restart': cycle,
          'savedMs': saved,
          'firstDecoderMs': positions.first,
          'persistedMs': persisted['position'],
          'queue': controller.queueEntryKeys,
          'pauseResumePreserved': true,
          'pausedSeekSavedBeforeCloseMs':
              afterBack['settings']['playback']['position'],
          'forwardSeekSavedBeforeCloseMs':
              afterForward['settings']['playback']['position'],
        });
        audio.removeListener(observe);
        await controller.close();
        controller = null;
        await library.flush();
        library.dispose();
        library = null;
      }
      final output = File('${testArtifacts().path}/session-resume-native.json');
      await output.parent.create(recursive: true);
      await output.writeAsString(jsonEncode(report));
      binding.reportData = {
        'platform': Platform.operatingSystem,
        'sessions': report,
      };
      debugPrint('SAVED_POSITION: ${jsonEncode(report)}');
    } finally {
      await controller?.close();
      await library?.flush();
      library?.dispose();
      torrents.dispose();
      await root.delete(recursive: true);
    }
  });
}
