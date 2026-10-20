import 'package:mumpa/logic/audio_runtime.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mumpa/main.dart';
import 'package:mumpa/ui/app_screen.dart';

Future<void> postWindowMessage(
  int window,
  int message,
  int wparam, [
  int lparam = 0,
]) async {
  final script =
      '''
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class MumpaWindowInput { [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam); }';
if (-not [MumpaWindowInput]::PostMessage([IntPtr]$window, [uint32]$message, [IntPtr]$wparam, [IntPtr]$lparam)) { throw "PostMessage failed" }
''';
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-Command',
    script,
  ]);
  if (result.exitCode != 0) {
    throw StateError('Local window input failed: ${result.stderr}');
  }
}

Future<void> waitForShellPlayback(
  WidgetTester tester,
  bool Function() ready, {
  int seconds = 15,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Windows playback condition');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  initializeAudioRuntime();
  testWidgets(
    'Windows shell buttons and close-to-tray retain native playback',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('mumpa-shell-native-');
      final app = await createApplication(
        dataDirectory: root,
        demo: true,
        catalogEnabled: false,
        desktopIntegration: true,
      );
      final shell = app.windowsPlayer!;
      addTearDown(() async {
        // Restore the runner's normal close behavior before ending the test.
        await shell.close();
        await tester.pumpWidget(const SizedBox.shrink());
        await app.shutdown();
        await root.delete(recursive: true);
      });
      await tester.pumpWidget(MumpaApp(controller: app));
      var diagnostic = await shell.diagnostics();
      final shellDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (diagnostic['taskbarButtonsAdded'] != true &&
          DateTime.now().isBefore(shellDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        diagnostic = await shell.diagnostics();
      }
      expect(diagnostic['initialized'], isTrue);
      expect(diagnostic['trayReady'], isTrue);
      expect(diagnostic['smtc'], isTrue);
      expect(diagnostic['taskbarButtonsAdded'], isTrue);
      final window = diagnostic['windowHandle'] as int;
      expect(window, isNot(0));
      final player = app.playback;
      final tracks = app.library.tracks;
      await player.setVolume(0);
      await player.playTracks(tracks);
      await waitForShellPlayback(
        tester,
        () =>
            player.playing &&
            player.position > const Duration(milliseconds: 700),
      );

      // Real WM_APPCOMMAND delivery exercises the HWND -> native -> Dart path.
      await postWindowMessage(window, 0x0319, window, 14 << 16);
      await waitForShellPlayback(tester, () => !player.playing);
      await postWindowMessage(window, 0x0319, window, 14 << 16);
      await waitForShellPlayback(tester, () => player.playing);
      await postWindowMessage(window, 0x0319, window, 11 << 16);
      await waitForShellPlayback(
        tester,
        () => player.current?.id == tracks[1].id && player.playing,
      );

      // Windows sends this same notification for clicks below thumbnail previews.
      // Previous restarts the current track after three seconds, as in the UI.
      await player.pause();
      await player.seek(Duration.zero);
      await postWindowMessage(window, 0x0111, (0x1800 << 16) | 0xA101);
      await waitForShellPlayback(
        tester,
        () => player.current?.id == tracks[0].id && player.playing,
      );
      await postWindowMessage(window, 0x0111, (0x1800 << 16) | 0xA103);
      await waitForShellPlayback(
        tester,
        () => player.current?.id == tracks[1].id && player.playing,
      );
      await postWindowMessage(window, 0x0111, (0x1800 << 16) | 0xA102);
      await waitForShellPlayback(tester, () => !player.playing);
      await postWindowMessage(window, 0x0111, (0x1800 << 16) | 0xA102);
      await waitForShellPlayback(tester, () => player.playing);

      final beforeHidden = player.position;
      await postWindowMessage(window, 0x0010, 0);
      // Hidden windows may not receive rendering frames; use real time here.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect((await shell.diagnostics())['windowVisible'], isFalse);
      expect(player.playing, isTrue);
      expect(
        player.position,
        greaterThan(beforeHidden + const Duration(milliseconds: 500)),
      );
      await shell.show();
      expect((await shell.diagnostics())['windowVisible'], isTrue);
      final evidence = {
        'smtcCreated': true,
        'trayCreated': true,
        'thumbnailButtonsCreated': true,
        'nativeMediaPlayPause': true,
        'nativeMediaNext': true,
        'thumbnailPreviousNextPlayPause': true,
        'closeHidesWindow': true,
        'playbackContinuesHidden': true,
        'restoreWindow': true,
      };
      final output = File('test-output/windows-shell-1.2.0.json');
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert(evidence),
      );
      await tester.pump();
    },
    skip: !Platform.isWindows,
  );
}
