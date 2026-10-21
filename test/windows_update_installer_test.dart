import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/windows_update_installer.dart';
import 'package:path/path.dart' as p;

String get _powershell => p.join(
  Platform.environment['SystemRoot'] ?? r'C:\Windows',
  'System32',
  'WindowsPowerShell',
  'v1.0',
  'powershell.exe',
);

Future<String> _loadScript(String asset) => File(asset).readAsString();

Future<Map> _waitState(File receipt, String expected) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    if (await receipt.exists()) {
      final state =
          jsonDecode((await receipt.readAsString()).replaceFirst('\uFEFF', ''))
              as Map;
      if (state['state'] == 'failed') fail('${state['message']}');
      if (state['state'] == expected) return state;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('Installer did not reach $expected');
}

void main() {
  late Directory root;
  setUp(() async {
    await Directory('test-output').create(recursive: true);
    root = (await Directory(
      'test-output',
    ).createTemp('install-test-handoff-')).absolute;
  });
  tearDown(() async {
    // The detached host can still be closing its final log handle.
    for (var attempt = 0; attempt < 50; attempt++) {
      try {
        if (await root.exists()) await root.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 49) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  test(
    'a failed broker reports an error without waiting for a worker receipt',
    () async {
      final installer = WindowsUpdateInstaller(
        root,
        loadScript: (asset) => asset.endsWith('/start-installer.ps1')
            ? Future.value(
                "[Console]::Error.WriteLine('broker-failure'); exit 7\n",
              )
            : _loadScript(asset),
      );
      await expectLater(
        installer.startAndWait(
          package: File(p.join(root.path, 'unused.zip')),
          sha256: '0' * 64,
          version: '1.2.27+35',
          parentProcessId: 0,
          launch: false,
          noRegistration: true,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await installer.log.readAsString(), contains('broker-failure'));
    },
    skip: !Platform.isWindows,
  );

  test(
    'asset decoding cannot remove the BOM from written Windows helpers',
    () async {
      final installer = WindowsUpdateInstaller(
        root,
        loadScript: (_) async => '\uFEFF# Кириллица — музыкальная медиатека\n',
      );
      await installer.prepareHelpers();
      for (final name in [
        'start-installer.ps1',
        'run-installer.ps1',
        'install-windows.ps1',
        'uninstall-windows.ps1',
      ]) {
        final bytes = await File(
          p.join(root.path, 'helper', name),
        ).readAsBytes();
        expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
        expect(utf8.decode(bytes), '# Кириллица — музыкальная медиатека\n');
        expect(bytes.sublist(3, 6), isNot([0xef, 0xbb, 0xbf]));
      }
    },
  );

  test(
    'Windows PowerShell catches an inner parser failure and reports its log',
    () async {
      final installer = WindowsUpdateInstaller(
        root,
        loadScript: (asset) => asset.endsWith('/install-windows.ps1')
            ? Future.value('param(\n')
            : _loadScript(asset),
        pollInterval: const Duration(milliseconds: 50),
      );
      await expectLater(
        installer.startAndWait(
          package: File(p.join(root.path, 'unused.zip')),
          sha256: '0' * 64,
          version: '1.2.27+35',
          parentProcessId: 0,
          installDirectory: p.join(root.path, 'installed'),
          launch: false,
          noRegistration: true,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'diagnostic',
            contains('Журнал:'),
          ),
        ),
      );
      final state = jsonDecode(
        (await installer.receipt.readAsString()).replaceFirst('\uFEFF', ''),
      );
      expect(state['state'], 'failed');
      expect(
        await installer.log.readAsString(),
        contains('install-windows.ps1'),
      );
    },
    skip: !Platform.isWindows,
  );

  test(
    'a host that exits before its first receipt fails at the startup deadline',
    () async {
      final installer = WindowsUpdateInstaller(
        root,
        loadScript: (asset) => asset.endsWith('/run-installer.ps1')
            ? Future.value('exit 0\n')
            : _loadScript(asset),
        startupTimeout: const Duration(seconds: 2),
        readinessTimeout: const Duration(seconds: 20),
        pollInterval: const Duration(milliseconds: 50),
      );
      final clock = Stopwatch()..start();
      await expectLater(
        installer.startAndWait(
          package: File(p.join(root.path, 'unused.zip')),
          sha256: '0' * 64,
          version: '1.2.27+35',
          parentProcessId: 0,
          installDirectory: p.join(root.path, 'installed'),
          launch: false,
          noRegistration: true,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'startup',
            contains('запустить установщик'),
          ),
        ),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 10)));
    },
    skip: !Platform.isWindows,
  );

  for (final insideJob in [false, true]) {
    test(
      'native PS 5.1 handoff preserves rollback and data (app job: $insideJob)',
      () async {
        final fixture = Directory(p.join(root.path, 'Проверка обновления'));
        final source = Directory(p.join(fixture.path, 'source', 'Mumpa'));
        final target = Directory(p.join(fixture.path, 'installed'));
        final current = Directory(p.join(target.path, 'current'));
        await Directory(
          p.join(source.path, 'data', 'flutter_assets'),
        ).create(recursive: true);
        await current.create(recursive: true);
        final compiler = File(p.join(root.path, 'compile.ps1'));
        await compiler.writeAsString(r'''
param([string]$OutputPath)
Add-Type -Path 'test/fixtures/update_job_host.cs' -OutputAssembly $OutputPath -OutputType ConsoleApplication
''');
        final executable = File(p.join(source.path, 'mumpa.exe'));
        final compiled = await Process.run(_powershell, [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          compiler.path,
          '-OutputPath',
          executable.path,
        ]);
        expect(
          compiled.exitCode,
          0,
          reason: '${compiled.stdout}\n${compiled.stderr}',
        );
        await executable.copy(p.join(current.path, 'mumpa.exe'));
        await File(p.join(current.path, 'generation.txt')).writeAsString('old');
        await File(p.join(target.path, 'install.json')).writeAsString(
          jsonEncode({'version': '1.2.26+34', 'directory': target.path}),
        );
        for (final name in [
          'flutter_windows.dll',
          'libmpv-2.dll',
          'data/flutter_assets/fixture.bin',
          'generation.txt',
        ]) {
          await File(p.join(source.path, name)).writeAsString('new');
        }
        final archive = Archive();
        await for (final entry in source.list(recursive: true)) {
          if (entry is File) {
            final bytes = await entry.readAsBytes();
            archive.addFile(
              ArchiveFile(
                'Mumpa/${p.relative(entry.path, from: source.path).replaceAll('\\', '/')}',
                bytes.length,
                bytes,
              ),
            );
          }
        }
        final zip = File(p.join(root.path, 'package.zip'));
        await zip.writeAsBytes(ZipEncoder().encode(archive));
        final personalData = File(p.join(root.path, 'personal-data.json'));
        await personalData.writeAsString('{"favorites":["keep-me"]}');
        final beforeData = await personalData.readAsBytes();
        final quit = File(p.join(root.path, 'parent-quit'));
        final installer = WindowsUpdateInstaller(
          Directory(p.join(fixture.path, "updates with ' quote")),
          loadScript: _loadScript,
          pollInterval: const Duration(milliseconds: 50),
        );
        final configuration = File(
          p.join(installer.directory.path, 'job-launch.json'),
        );
        final helper = p.join(installer.directory.path, 'helper');
        if (insideJob) {
          await installer.prepareHelpers();
          await configuration.writeAsString(
            jsonEncode({
              'RunnerPath': p.join(helper, 'run-installer.ps1'),
              'StdoutPath': p.join(installer.directory.path, 'stdout.log'),
              'StderrPath': p.join(installer.directory.path, 'stderr.log'),
              'Parameters': {
                'InstallerPath': p.join(helper, 'install-windows.ps1'),
                'ZipPath': zip.path,
                'Sha256': sha256.convert(await zip.readAsBytes()).toString(),
                'Version': '1.2.27+35',
                'StatusPath': installer.receipt.path,
                'LogPath': installer.log.path,
                // The host's PID is filled in after it starts.
                'WaitForProcessId': 0,
                'InstallDirectory': target.path,
                'Launch': false,
                'NoRegistration': true,
              },
            }),
          );
          // Gate the broker until its own parent PID is available.
          await File(p.join(helper, 'job-broker.ps1')).writeAsString('''\uFEFF
param([string]\$ConfigurationPath)
while (!(Test-Path -LiteralPath (\$ConfigurationPath + '.go'))) { Start-Sleep -Milliseconds 25 }
& '${p.join(helper, 'start-installer.ps1').replaceAll("'", "''")}' -ConfigurationPath \$ConfigurationPath
''');
        }
        final parent = await Process.start(p.join(current.path, 'mumpa.exe'), [
          quit.path,
          if (insideJob) ...[
            _powershell,
            '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${p.join(helper, 'job-broker.ps1')}" -ConfigurationPath "${configuration.path}"',
          ],
        ]);
        parent.stdout.drain<void>();
        parent.stderr.drain<void>();
        try {
          if (insideJob) {
            final config =
                jsonDecode(await configuration.readAsString()) as Map;
            (config['Parameters'] as Map)['WaitForProcessId'] = parent.pid;
            await configuration.writeAsString(jsonEncode(config));
            await File('${configuration.path}.go').writeAsString('go');
            try {
              await _waitState(installer.receipt, 'ready');
            } catch (_) {
              final diagnostic = File('${quit.path}.broker');
              if (await diagnostic.exists()) {
                // ignore: avoid_print
                print(await diagnostic.readAsString());
              }
              rethrow;
            }
          } else {
            expect(
              await installer.startAndWait(
                package: zip,
                sha256: sha256.convert(await zip.readAsBytes()).toString(),
                version: '1.2.27+35',
                parentProcessId: parent.pid,
                installDirectory: target.path,
                launch: false,
                noRegistration: true,
              ),
              isTrue,
            );
          }
          expect(
            await File(p.join(current.path, 'generation.txt')).readAsString(),
            'old',
          );
          expect(
            (await _waitState(installer.receipt, 'ready'))['state'],
            'ready',
          );
          await quit.writeAsString('exit');
          expect(await parent.exitCode.timeout(const Duration(seconds: 10)), 0);
          await _waitState(installer.receipt, 'installed');
          expect(
            await File(p.join(current.path, 'generation.txt')).readAsString(),
            'new',
          );
          expect(
            await File(
              p.join(target.path, 'previous', 'generation.txt'),
            ).readAsString(),
            'old',
          );
          expect(await personalData.readAsBytes(), beforeData);
          if (insideJob) {
            final servicePid = int.parse(
              await File('${quit.path}.service').readAsString(),
            );
            final services = await Process.run(_powershell, [
              '-NoProfile',
              '-Command',
              'if (Get-Process -Id $servicePid -ErrorAction SilentlyContinue) { exit 1 }',
            ]);
            expect(
              services.exitCode,
              0,
              reason: 'Ordinary service must die with app',
            );
          }
        } finally {
          await quit.writeAsString('exit');
          try {
            await parent.exitCode.timeout(const Duration(seconds: 5));
          } on TimeoutException {
            parent.kill();
          }
        }
      },
      skip: !Platform.isWindows,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}
