import 'package:mumpa/logic/audio_runtime.dart';
// Real libmpv DSP and dual-decoder transport proof, using generated local audio.
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
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/audio_preferences.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:path/path.dart' as p;

Uint8List _wav({double amplitude = .1, int seconds = 10}) {
  const rate = 48000;
  final bytes = Uint8List(44 + seconds * rate * 4);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  for (var i = 0; i < seconds * rate; i++) {
    final bass = math.sin(2 * math.pi * 60 * i / rate),
        mid = math.sin(2 * math.pi * 1000 * i / rate);
    data.setInt16(
      44 + i * 4,
      ((bass + mid) * amplitude * 32767).round(),
      Endian.little,
    );
    data.setInt16(46 + i * 4, (mid * amplitude * 32767).round(), Endian.little);
  }
  return bytes;
}

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(
        cache: DiskMediaCache(Directory(p.join(root.path, 'metadata'))),
        client: MockClient((_) async => throw StateError('No network')),
      );
  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String description,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException(description);
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<List<double>> _renderPcm(
  Directory root,
  String name,
  File source,
  AudioPreferences prefs,
) async {
  final audio = NativeAudioBackend();
  final output = File(p.join(root.path, '$name.pcm'));
  final errors = <String>[];
  final logs = <String>[];
  final logSub = audio.player.stream.log.listen(
    (log) => logs.add('${log.prefix}: ${log.text}'),
  );
  final sub = audio.errors.listen(errors.add);
  try {
    final native = audio.player.platform as NativePlayer;
    await native.setProperty('ao', 'pcm');
    await native.setProperty('ao-pcm-file', output.path);
    await native.setProperty('ao-pcm-waveheader', 'no');
    await native.setProperty('audio-format', 's16');
    await native.setProperty('audio-samplerate', '48000');
    await native.setProperty('audio-channels', 'stereo');
    await audio.applyPreferences(prefs);
    await audio.setVolume(1);
    final done = audio.completed.first.timeout(const Duration(seconds: 20));
    await audio.open(source.uri.toString());
    try {
      await done;
    } catch (_) {
      final diagnostics = <String, Object?>{
        'name': name,
        'position': audio.position.inMilliseconds,
        'errors': errors,
        'fileBytes': await output.exists() ? await output.length() : -1,
      };
      for (final property in [
        'ao',
        'pause',
        'idle-active',
        'audio-out-params',
        'af',
        'path',
      ]) {
        diagnostics[property] = await native.getProperty(property);
      }
      diagnostics['logs'] = logs;
      debugPrint(jsonEncode(diagnostics));
      rethrow;
    }
    expect(errors, isEmpty);
  } finally {
    await logSub.cancel();
    await sub.cancel();
    await audio.close();
  }
  final bytes = await output.readAsBytes();
  expect(bytes.length, greaterThan(48000 * 4 * 7));
  final data = ByteData.sublistView(bytes);
  return List.generate(
    bytes.length ~/ 2,
    (i) => data.getInt16(i * 2, Endian.little) / 32768,
  );
}

double _rms(List<double> values) {
  final start = values.length ~/ 2;
  return math.sqrt(
    values.skip(start).fold<double>(0, (sum, v) => sum + v * v) /
        (values.length - start),
  );
}

double _tone(List<double> values, int hz) {
  var real = 0.0, imag = 0.0;
  final count = math.min(48000, values.length ~/ 2);
  final start = values.length ~/ 2 - count;
  for (var i = 0; i < count; i++) {
    final phase = 2 * math.pi * hz * i / 48000;
    real += values[(start + i) * 2] * math.cos(phase);
    imag += values[(start + i) * 2] * math.sin(phase);
  }
  return math.sqrt(real * real + imag * imag) * 2 / count;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native PCM proves EQ, mono and normalization; crossfade preserves transport',
    (tester) async {
      initializeAudioRuntime();
      final root = await Directory.systemTemp.createTemp('mumpa-native-audio-');
      final report = <String, Object?>{};
      AppController? app;
      try {
        final loud = File(p.join(root.path, 'loud.wav')),
            quiet = File(p.join(root.path, 'quiet.wav'));
        await loud.writeAsBytes(_wav());
        await quiet.writeAsBytes(_wav(amplitude: .025));
        final baseline = await _renderPcm(
          root,
          'baseline',
          loud,
          AudioPreferences(),
        );
        final eq = await _renderPcm(
          root,
          'equalizer',
          loud,
          AudioPreferences(
            equalizerEnabled: true,
            gains: const [6, 0, 0, 0, 0, 0],
          ),
        );
        final eqRatio =
            (_tone(eq, 60) / _tone(eq, 1000)) /
            (_tone(baseline, 60) / _tone(baseline, 1000));
        expect(eqRatio, greaterThan(1.7));
        final high = File(p.join(root.path, 'high.wav'));
        await high.writeAsBytes(_wav(amplitude: .3));
        final boosted = await _renderPcm(root, 'boosted', high, AudioPreferences(equalizerEnabled: true, gains: const [12, 0, 0, 0, 0, 0]));
        final clippingHarmonic = _tone(boosted, 180);
        expect(clippingHarmonic, lessThan(.001));
        final mono = await _renderPcm(
          root,
          'mono',
          loud,
          AudioPreferences(mono: true),
        );
        var maxChannelDifference = 0.0;
        for (var i = mono.length ~/ 2; i < mono.length - 1; i += 2) {
          maxChannelDifference = math.max(
            maxChannelDifference,
            (mono[i] - mono[i + 1]).abs(),
          );
        }
        expect(maxChannelDifference, lessThan(.0001));
        final normalizedLoud = await _renderPcm(
          root,
          'normalized-loud',
          loud,
          AudioPreferences(normalize: true),
        );
        final normalizedQuiet = await _renderPcm(
          root,
          'normalized-quiet',
          quiet,
          AudioPreferences(normalize: true),
        );
        final normalizedRatio = _rms(normalizedLoud) / _rms(normalizedQuiet);
        expect(normalizedRatio, closeTo(1, .1));
        report['pcm'] = {
          'boostedBassClippingHarmonic': clippingHarmonic,
          'equalizerBassRelativeGain': eqRatio,
          'monoMaxChannelDifference': maxChannelDifference,
          'normalizedLoudQuietRatio': normalizedRatio,
        };
        debugPrint('PCM: ${jsonEncode(report['pcm'])}');

        final library = LibraryRepository(
          Directory(p.join(root.path, 'profile')),
        );
        await library.load();
        final tracks = [
          for (var i = 0; i < 3; i++)
            Track(
              id: '$i',
              title: 'Тестовый трек $i',
              artist: 'Mumpa Audio Test',
              album: 'Audio settings',
              source: TrackSource.local,
              localPath: i == 1 ? quiet.path : loud.path,
              durationMs: 10000,
            ),
        ];
        await library.upsert(tracks);
        final torrents = TorrentService(
          endpoint: () async => throw StateError('No torrent engine'),
          client: MockClient((_) async => throw StateError('No network')),
        );
        final backend = NativeAudioBackend();
        report['runtime'] = await (backend.player.platform as NativePlayer)
            .getProperty('mpv-version');
        final player = PlaybackController(
          library: library,
          torrents: torrents,
          backend: backend,
        );
        await player.initialize(platformAudio: false);
        await player.setVolume(0);
        app = AppController(
          library: library,
          playback: player,
          downloads: DownloadRepository(library, torrents),
          torrents: torrents,
          engine: TorrentEngine(root),
          metadata: _Metadata(root),
        );
        await player.setAudioSetting('crossfadeSeconds', 3.0);
        await player.setAudioSetting('crossfadeEnabled', true);
        await player.playTracks(tracks);
        await _until(
          tester,
          () => player.position > const Duration(milliseconds: 500),
          'first native track',
        );
        await _until(
          tester,
          () => backend.transitioning && player.index == 1,
          'overlapping decoders',
        );
        await player.setVolume(.2);
        await tester.pump(const Duration(milliseconds: 400));
        expect(backend.player.state.volume, greaterThan(0));
        expect(backend.player.state.volume, lessThan(20));
        expect(player.error, isNull);
        expect(player.queue.map((t) => t.id), ['0', '1', '2']);
        report['crossfade'] = {
          'index': player.index,
          'positionMs': player.position.inMilliseconds,
          'overlapping': backend.transitioning,
          'incomingVolumeDuringFade': backend.player.state.volume,
        };
        final selectedPlayer = backend.player;
        await player.pause();
        await player.setVolume(0);
        await tester.pump(const Duration(milliseconds: 150));
        final pausedAt = player.position;
        expect(backend.transitioning, isFalse);
        await player.setAudioSetting('equalizerEnabled', true);
        await player.setAudioSetting(
          'equalizerGains',
          AudioPreferences.presets['bass']!,
        );
        await player.setAudioSetting('monoAudio', true);
        await player.setAudioSetting('normalizeVolume', true);
        expect(backend.player, same(selectedPlayer));
        expect(
          (player.position - pausedAt).inMilliseconds.abs(),
          lessThan(150),
        );
        expect(player.index, 1);
        expect(player.playing, isFalse);
        await player.play();
        await _until(
          tester,
          () => player.position > pausedAt + const Duration(milliseconds: 250),
          'resume same decoder',
        );
        await player.pause();
        await library.setSetting('language', 'en');
        app.navigate(AppPage.settings);
        app.setSettingsSection('playback');
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MumpaApp(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Equalizer'), findsOneWidget);
        expect(find.text('Crossfade'), findsOneWidget);
        expect(player.current!.title, 'Тестовый трек 1');
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = Directory('test-output')..createSync();
        await File(
          p.join(output.path, 'audio-settings-en.png'),
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        report['transport'] = {
          'sameDecoderAfterEffectsAndResume': true,
          'queuePreserved': true,
          'language': 'en',
        };
        await File(
          p.join(output.path, 'audio-settings-native.json'),
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (app != null) {
          await app.shutdown();
          app.library.dispose();
        }
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
