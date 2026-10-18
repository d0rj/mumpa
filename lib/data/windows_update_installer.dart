import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Windows-native handoff: the helper survives this app's graceful shutdown.
class WindowsUpdateInstaller {
  WindowsUpdateInstaller(
    this.directory, {
    Future<String> Function(String)? loadScript,
    this.startupTimeout = const Duration(seconds: 15),
    this.readinessTimeout = const Duration(minutes: 3),
    this.pollInterval = const Duration(milliseconds: 250),
  }) : _loadScript = loadScript ?? rootBundle.loadString;

  final Directory directory;
  final Future<String> Function(String) _loadScript;
  final Duration startupTimeout, readinessTimeout, pollInterval;
  File get receipt => File(p.join(directory.path, 'install-status.json'));
  File get log => File(p.join(directory.path, 'install.log'));

  Future<void> prepareHelpers() async {
    final helper = Directory(p.join(directory.path, 'helper'));
    await helper.create(recursive: true);
    for (final name in [
      'start-installer.ps1',
      'run-installer.ps1',
      'install-windows.ps1',
      'uninstall-windows.ps1',
    ]) {
      final source = await _loadScript('assets/updater/$name');
      // UTF-8 decoding removes an asset's BOM. Windows PowerShell 5.1 needs it
      // restored on disk or it reads Cyrillic source as the Windows ANSI page.
      await File(p.join(helper.path, name)).writeAsString(
        '\uFEFF${source.replaceFirst(RegExp(r'^\uFEFF'), '')}',
        flush: true,
      );
    }
  }

  Future<bool> startAndWait({
    required File package,
    required String sha256,
    required String version,
    required int parentProcessId,
    bool Function()? cancelled,
    String? installDirectory,
    bool launch = true,
    bool noRegistration = false,
  }) async {
    await prepareHelpers();
    if (await receipt.exists()) await receipt.delete();
    final executable = p.join(
      Platform.environment['SystemRoot'] ?? r'C:\Windows',
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final helper = p.join(directory.path, 'helper');
    final configuration = File(p.join(helper, 'launch.json'));
    await configuration.writeAsString(
      jsonEncode({
        'RunnerPath': p.join(helper, 'run-installer.ps1'),
        'StdoutPath': p.join(directory.path, 'installer-stdout.log'),
        'StderrPath': p.join(directory.path, 'installer-stderr.log'),
        'Parameters': {
          'InstallerPath': p.join(helper, 'install-windows.ps1'),
          'ZipPath': package.absolute.path,
          'Sha256': sha256,
          'Version': version,
          'WaitForProcessId': parentProcessId,
          'StatusPath': receipt.absolute.path,
          'LogPath': log.absolute.path,
          'InstallDirectory': ?installDirectory,
          'Launch': launch,
          'NoRegistration': noRegistration,
        },
      }),
      flush: true,
    );
    final broker = await Process.start(executable, [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      p.join(helper, 'start-installer.ps1'),
      '-ConfigurationPath',
      configuration.absolute.path,
    ]);
    // Windows descendants can inherit duplicate pipe handles even when their
    // own output is redirected. Read the broker's one-line acknowledgement;
    // waiting for EOF would deadlock until the worker (waiting for us) exits.
    final output = broker.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .catchError((Object _) => '');
    final errors = StringBuffer();
    final errorSubscription = broker.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(errors.write);
    await broker.stdin.close();
    int exitCode;
    var stdout = '';
    try {
      exitCode = await broker.exitCode.timeout(startupTimeout);
      if (exitCode == 0) stdout = await output.timeout(startupTimeout);
    } on TimeoutException {
      broker.kill();
      throw FormatException(
        'Не удалось запустить установщик Windows. Журнал: ${log.path}',
      );
    } finally {
      await errorSubscription.cancel();
    }
    final stderr = errors.toString();
    int? workerPid;
    try {
      final result = jsonDecode(stdout.trim());
      if (result is Map && result['processId'] is int) {
        workerPid = result['processId'] as int;
      }
    } on FormatException {
      // Missing or malformed output is a broker failure, never a ready receipt.
    }
    if (exitCode != 0 || workerPid == null || workerPid <= 0) {
      await log.writeAsString(
        'Installer launch failed ($exitCode)\n$stdout\n$stderr',
        flush: true,
      );
      throw FormatException(
        'Не удалось запустить установщик Windows. Журнал: ${log.path}',
      );
    }
    final clock = Stopwatch()..start();
    var responded = false;
    while (clock.elapsed < readinessTimeout) {
      if (cancelled?.call() == true) return false;
      if (await receipt.exists()) {
        Map? result;
        try {
          final value = jsonDecode(
            (await receipt.readAsString()).replaceFirst('\uFEFF', ''),
          );
          if (value is Map) result = value;
        } on FormatException {
          // A receipt can be replaced between its existence check and read.
        } on FileSystemException {
          // Retry a short file-share race with the helper's atomic promotion.
        }
        if (result != null) {
          responded = true;
          if (result['state'] == 'failed') {
            throw FormatException(
              'Ошибка установщика: ${result['message'] ?? 'неизвестная ошибка'}. '
              'Журнал: ${log.path}',
            );
          }
          if (result['state'] == 'ready' || result['state'] == 'installed') {
            return true;
          }
        }
      }
      if (!responded && clock.elapsed >= startupTimeout) {
        Process.killPid(workerPid);
        final workerErrors = File(
          p.join(directory.path, 'installer-stderr.log'),
        );
        final errorBytes = await workerErrors.exists()
            ? await workerErrors.readAsBytes()
            : <int>[];
        final workerDiagnostic =
            errorBytes.length >= 2 &&
                errorBytes[0] == 0xff &&
                errorBytes[1] == 0xfe
            ? String.fromCharCodes(
                List.generate(
                  (errorBytes.length - 2) ~/ 2,
                  (i) => errorBytes[2 + i * 2] | (errorBytes[3 + i * 2] << 8),
                ),
              )
            : utf8.decode(errorBytes, allowMalformed: true);
        await log.writeAsString(
          'Installer did not report startup.\n'
          '$workerDiagnostic',
          flush: true,
        );
        throw FormatException(
          'Не удалось запустить установщик Windows. Журнал: ${log.path}',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
    Process.killPid(workerPid);
    throw FormatException(
      'Установщик не завершил подготовку. Журнал: ${log.path}',
    );
  }
}
