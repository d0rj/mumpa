import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/flaresolverr_service.dart';

class FakeSolverProcess implements Process {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final completion = Completer<int>();
  void finish(int code) {
    if (completion.isCompleted) return;
    unawaited(output.close());
    unawaited(errors.close());
    completion.complete(code);
  }

  @override
  Future<int> get exitCode => completion.future;
  @override
  int get pid => 123;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  IOSink get stdin => throw UnsupportedError('Unused fake stdin');
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    finish(0);
    return true;
  }
}

class FakeGuard implements FlareSolverrProcessGuard {
  FakeGuard(this.process);
  final FakeSolverProcess process;
  bool closed = false;
  @override
  void close() {
    closed = true;
    process.finish(0);
  }
}

void main() {
  late Directory root;
  late File bundle;
  late String expected;
  FlareSolverrService? service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-solver-');
    final archive = Archive();
    for (final path in [
      'flaresolverr/flaresolverr.exe',
      'flaresolverr/_internal/python311.dll',
      'flaresolverr/_internal/chrome/chrome.exe',
      'flaresolverr/_internal/chrome/chrome.dll',
    ]) {
      archive.addFile(ArchiveFile.string(path, 'fixture $path'));
    }
    final bytes = ZipEncoder().encode(archive);
    expected = sha256.convert(bytes).toString();
    bundle = await File('${root.path}/fixture.zip').writeAsBytes(bytes);
  });
  tearDown(() async {
    await service?.stop();
    service = null;
    await root.delete(recursive: true);
  });

  test(
    'is lazy, persists opt-in, isolates profile and reuses its installation',
    () async {
      var process = FakeSolverProcess();
      var launches = 0;
      final paths = <String>[];
      service = FlareSolverrService.testing(
        root,
        bundledArchive: bundle,
        expectedHash: expected,
        launcher: (executable, environment, directory) async {
          launches++;
          paths.add(executable);
          process = FakeSolverProcess();
          expect(environment['HOST'], '127.0.0.1');
          expect(environment['HEADLESS'], 'true');
          expect(environment['LOG_LEVEL'], 'error');
          expect(environment['LOG_HTML'], 'false');
          expect(environment['LOG_FILE'], '');
          expect(environment['USERPROFILE'], startsWith(root.path));
          expect(environment['TEMP'], startsWith(root.path));
          expect(directory, File(executable).parent.path);
          return process;
        },
        guardFactory: (_) => FakeGuard(process),
        clientFactory: () =>
            MockClient((_) async => http.Response('{"status":"ok"}', 200)),
      );
      expect(launches, 0);
      expect(await service!.isEnabled(), isFalse);
      final first = service!.start();
      expect(identical(first, service!.start()), isTrue);
      expect(await first, startsWith('http://127.0.0.1:'));
      expect(await service!.isEnabled(), isFalse);
      await service!.enable();
      expect(await service!.isEnabled(), isTrue);
      await service!.stop();
      expect(await service!.isEnabled(), isTrue);
      // A completed installation remains usable even without the source archive.
      await bundle.delete();
      await service!.start();
      expect(launches, 2);
      expect(paths.toSet().length, 1);
      await service!.disable();
      expect(await service!.isEnabled(), isFalse);
    },
  );

  test('rejects an altered archive before launching or enabling', () async {
    var launches = 0;
    service = FlareSolverrService.testing(
      root,
      bundledArchive: bundle,
      expectedHash: 'incorrect',
      launcher: (_, _, _) async {
        launches++;
        return FakeSolverProcess();
      },
      guardFactory: (_) => throw StateError('not reached'),
      clientFactory: () =>
          MockClient((_) async => http.Response('{"status":"ok"}', 200)),
    );
    await expectLater(service!.enable(), throwsStateError);
    expect(launches, 0);
    expect(await service!.isEnabled(), isFalse);
  });

  test(
    'returns safe probe fields and never stores HTML/cookies/diagnostics',
    () async {
      final process = FakeSolverProcess();
      service = FlareSolverrService.testing(
        root,
        bundledArchive: bundle,
        expectedHash: expected,
        launcher: (_, _, _) async {
          process.output.add(
            utf8.encode('<html>PRIVATE_COOKIE PASSWORD</html>'),
          );
          return process;
        },
        guardFactory: (_) => FakeGuard(process),
        clientFactory: () => MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response('{"status":"ok"}', 200);
          }
          final body = jsonDecode(request.body) as Map;
          expect(body['cmd'], 'request.get');
          expect(body.containsKey('session'), isFalse);
          return http.Response(
            jsonEncode({
              'status': 'ok',
              'message': 'Challenge solved!',
              'solution': {
                'status': 200,
                'response': '<html>PRIVATE_COOKIE PASSWORD</html>',
                'cookies': [
                  {'name': 'token', 'value': 'SECRET'},
                ],
              },
            }),
            200,
          );
        }),
      );
      final result = await service!.probe(
        Uri.parse('https://example.com/login'),
      );
      expect(result.success, isTrue);
      expect(result.challengeSolved, isTrue);
      expect(result.siteStatus, 200);
      await service!.stop();
      final files = await root
          .list(recursive: true)
          .where((file) => file is File)
          .toList();
      expect(files.any((file) => file.path.endsWith('.log')), isFalse);
      for (final file in files.where((file) => file.path.endsWith('.json'))) {
        expect(
          await File(file.path).readAsString(),
          isNot(contains('PRIVATE_COOKIE')),
        );
      }
    },
  );

  test(
    'early exit clears the owned tree and allows retry without raw error text',
    () async {
      var launches = 0;
      var process = FakeSolverProcess();
      final guards = <FakeGuard>[];
      service = FlareSolverrService.testing(
        root,
        bundledArchive: bundle,
        expectedHash: expected,
        launcher: (_, _, _) async {
          process = FakeSolverProcess();
          launches++;
          if (launches == 1) {
            final exiting = process;
            Timer(const Duration(milliseconds: 10), () {
              exiting.errors.add(utf8.encode('SECRET_COOKIE PASSWORD HTML'));
              exiting.finish(17);
            });
          }
          return process;
        },
        guardFactory: (_) {
          final guard = FakeGuard(process);
          guards.add(guard);
          return guard;
        },
        clientFactory: () => MockClient(
          (_) async => launches == 1
              ? Completer<http.Response>().future
              : http.Response('{"status":"ok"}', 200),
        ),
      );
      await expectLater(
        service!.start(),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('17') &&
                !error.toString().contains('SECRET_COOKIE'),
          ),
        ),
      );
      expect(guards.first.closed, isTrue);
      await service!.start();
      expect(launches, 2);
    },
  );

  test(
    'readiness timeout closes the process tree and keeps opt-in disabled',
    () async {
      final process = FakeSolverProcess();
      final guard = FakeGuard(process);
      service = FlareSolverrService.testing(
        root,
        bundledArchive: bundle,
        expectedHash: expected,
        startupTimeout: const Duration(milliseconds: 20),
        launcher: (_, _, _) async => process,
        guardFactory: (_) => guard,
        clientFactory: () =>
            MockClient((_) async => http.Response('{"status":"error"}', 200)),
      );
      await expectLater(service!.enable(), throwsStateError);
      expect(guard.closed, isTrue);
      expect(await service!.isEnabled(), isFalse);
    },
  );

  test(
    'Windows guard terminates only its own parent and child',
    () async {
      final process = await Process.start('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Command',
        r'$child = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -NonInteractive -Command Start-Sleep -Seconds 30"; $child.Id; Start-Sleep -Seconds 30',
      ]);
      final guard = FlareSolverrService.guardProcess(process.pid);
      try {
        final child = int.parse(
          await process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 5)),
        );
        unawaited(process.stderr.drain<void>());
        guard.close();
        await process.exitCode.timeout(const Duration(seconds: 5));
        final tasks = await Process.run('tasklist.exe', [
          '/FI',
          'PID eq $child',
          '/FO',
          'CSV',
          '/NH',
        ]);
        expect(tasks.stdout.toString(), isNot(contains('"$child"')));
      } finally {
        guard.close();
        process.kill();
      }
    },
    skip: !Platform.isWindows,
  );
}
