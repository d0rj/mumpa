import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:mumpa/data/bounded_http.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/audio_preferences.dart';
import 'package:mumpa/main.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/audio_runtime.dart';
import 'package:mumpa/logic/playback_controller.dart';

class _FailingBackend extends NativeAudioBackend {
  bool released = false;
  @override
  Future<void> applyPreferences(AudioPreferences preferences) async =>
      throw StateError('Injected startup failure');
  @override
  Future<void> close() async {
    await super.close();
    released = true;
  }
}

Future<Map<String, Object>> _memory(int cycle) async {
  final service = await developer.Service.getInfo();
  final address = service.serverUri;
  final client = http.Client();
  try {
    final heap = address == null
        ? null
        : jsonDecode(
                (await getBounded(
                  client,
                  address
                      .resolve('getAllocationProfile')
                      .replace(
                        queryParameters: {
                          'isolateId': developer.Service.getIsolateId(
                            Isolate.current,
                          )!,
                          'gc': 'true',
                        },
                      ),
                  maxBytes: 16 * 1024 * 1024,
                )).body,
              )
              as Map;
    return {
      'cycle': cycle,
      'rssBytes': ProcessInfo.currentRss,
      if (heap != null)
        'memoryUsageAfterGC': (heap['result'] as Map)['memoryUsage'],
      if (heap != null)
        'liveInstancesAfterGC': {
          for (final row in (heap['result'] as Map)['members'] as List)
            if (const {
              'AppController',
              'PlaybackController',
              'NativeAudioBackend',
              'DownloadRepository',
              'LibraryRepository',
              'Player',
              'NativePlayer',
            }.contains((row['class'] as Map)['name']))
              (row['class'] as Map)['name'] as String: row['instancesCurrent'],
        },
    };
  } finally {
    client.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  initializeAudioRuntime();
  testWidgets(
    'repeated native playback and application shutdown release resources',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'mumpa-resource-lifecycle-',
      );
      final samples = <Map<String, Object>>[];
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Resource lifecycle audit')),
        ),
      );
      try {
        final failing = _FailingBackend();
        await expectLater(
          createApplication(
            dataDirectory: Directory('${root.path}/failed-startup'),
            catalogEnabled: false,
            audioBackendFactory: () => failing,
          ),
          throwsStateError,
        );
        expect(failing.released, isTrue);
        final asset = await rootBundle.load(
          'assets/demo/01 - First light.wav.bin',
        );
        final file = File('${root.path}/local.wav');
        await file.writeAsBytes(
          asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        );
        for (var cycle = 0; cycle < 30; cycle++) {
          final library = LibraryRepository(Directory('${root.path}/profile'));
          final torrents = TorrentService(
            endpoint: () async => throw StateError('Local fixture only'),
          );
          AppController? app;
          PlaybackController? playback;
          DownloadRepository? downloads;
          try {
            await library.load();
            final tracks = await library.importPaths([file.path]);
            await library.setSetting('autoplayRadio', false);
            playback = PlaybackController(
              library: library,
              torrents: torrents,
              backend: NativeAudioBackend(),
            );
            await playback.initialize(platformAudio: false);
            downloads = DownloadRepository(library, torrents);
            await downloads.restore();
            app = AppController(
              library: library,
              playback: playback,
              downloads: downloads,
              torrents: torrents,
              engine: TorrentEngine(library.root),
            );
            await playback.playTracks(tracks);
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (playback.position < const Duration(milliseconds: 100)) {
              if (DateTime.now().isAfter(deadline)) {
                throw TimeoutException('Native playback did not advance');
              }
              await tester.pump(const Duration(milliseconds: 50));
            }
            await playback.pause();
            expect(playback.current?.source, TrackSource.local);
            await app.shutdown();
            await app.shutdown();
          } finally {
            if (app != null) {
              await app.shutdown();
            } else {
              await downloads?.close();
              await playback?.close();
              torrents.dispose();
            }
            await library.flush();
            library.dispose();
          }
          await tester.pump(const Duration(milliseconds: 100));
          samples.add(await _memory(cycle));
        }
        binding.reportData = {'resourceLifecycle': samples};
        final evidence = File(
          '${Directory.current.path}/test-output/audit-native-memory.json',
        );
        await evidence.parent.create(recursive: true);
        await evidence.writeAsString(
          const JsonEncoder.withIndent('  ').convert(samples),
          flush: true,
        );
        // Six warmup cycles precede the comparison. This is a coarse regression
        // guard; RSS includes native allocators and is also saved for inspection.
        final first = samples[5]['rssBytes'] as int,
            last = samples.last['rssBytes'] as int;
        expect(last - first, lessThan(64 * 1024 * 1024));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
