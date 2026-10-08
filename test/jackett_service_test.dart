import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/jackett_service.dart';

class FakeJackettProcess implements Process {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final completion = Completer<int>();
  int kills = 0;

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
    kills++;
    finish(0);
    return true;
  }
}

class RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Uint8List archive;
  JackettService? service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-jackett-');
    final fixture = Archive();
    for (final name in [
      'JackettConsole.exe',
      'JackettConsole.dll',
      'Jackett.Common.dll',
    ]) {
      fixture.addFile(ArchiveFile.string('Jackett/$name', 'fixture $name'));
    }
    archive = Uint8List.fromList(ZipEncoder().encode(fixture));
  });
  tearDown(() async {
    await service?.stop();
    service = null;
    await root.delete(recursive: true);
  });

  JackettService fakeService({
    required JackettProcessStarter launch,
    required Future<http.Response> Function(http.Request) respond,
    Directory? legacy,
    Duration timeout = const Duration(seconds: 60),
    String? expectedHash,
    Future<Uint8List> Function()? load,
  }) => JackettService.testing(
    root,
    archiveHash: expectedHash ?? sha256.convert(archive).toString(),
    assetLoader: load ?? () async => archive,
    startProcess: launch,
    clientFactory: () => MockClient(respond),
    startupTimeout: timeout,
    legacyProfile: legacy,
  );

  test(
    'extracts once, retains path/key/port and prewrites private CLI config',
    () async {
      var loads = 0;
      final paths = <String>[];
      var process = FakeJackettProcess();
      service = fakeService(
        load: () async {
          loads++;
          return archive;
        },
        launch: (executable, arguments, {workingDirectory}) async {
          paths.add(executable);
          expect(workingDirectory, File(executable).parent.path);
          expect(
            arguments,
            containsAll(['--ListenPrivate', '--NoUpdates', '--NoRestart']),
          );
          expect(arguments, isNot(contains('--Install')));
          final config =
              jsonDecode(
                    await File(
                      '${root.path}/jackett/ServerConfig.json',
                    ).readAsString(),
                  )
                  as Map;
          expect(
            config['Port'].toString(),
            arguments[arguments.indexOf('--Port') + 1],
          );
          expect(config['AllowExternal'], isFalse);
          expect(config['LocalBindAddress'], '127.0.0.1');
          expect(config['UpdateDisabled'], isTrue);
          return process;
        },
        respond: (request) async {
          if (request.method == 'POST') {
            process.finish(0);
            return http.Response('', 200);
          }
          return http.Response('<caps><server title="Jackett"/></caps>', 200);
        },
      );
      final first = service!.start();
      expect(identical(first, service!.start()), isTrue);
      final initial = await first;
      expect(initial.apiKey.length, 32);
      expect(
        initial.torznabUrl,
        '${initial.baseUrl}/api/v2.0/indexers/all/results/torznab/api',
      );
      await service!.stop();
      process = FakeJackettProcess();
      final restarted = await service!.start();
      expect(restarted.baseUrl, initial.baseUrl);
      expect(restarted.apiKey, initial.apiKey);
      expect(paths.toSet().length, 1);
      expect(loads, 1);
    },
  );

  test(
    'rejects bad archives before launching or writing a profile key',
    () async {
      var launched = false;
      service = fakeService(
        expectedHash: 'wrong',
        launch: (_, _, {workingDirectory}) async {
          launched = true;
          return FakeJackettProcess();
        },
        respond: (_) async => http.Response('<caps/>', 200),
      );
      await expectLater(service!.start(), throwsStateError);
      expect(launched, isFalse);
      expect(
        await File('${root.path}/jackett/ServerConfig.json').exists(),
        isFalse,
      );
    },
  );

  test('protects an existing legacy profile from upstream migration', () async {
    final legacy = await Directory('${root.path}/legacy').create();
    final existing = await File(
      '${legacy.path}/settings.json',
    ).writeAsString('original');
    var launched = false;
    service = fakeService(
      legacy: legacy,
      launch: (_, _, {workingDirectory}) async {
        launched = true;
        return FakeJackettProcess();
      },
      respond: (_) async => http.Response('<caps/>', 200),
    );
    await expectLater(service!.start(), throwsStateError);
    expect(launched, isFalse);
    expect(await existing.readAsString(), 'original');
  });

  test(
    'reads RuTracker status through the API-key indexer inventory',
    () async {
      var configured = false;
      service = fakeService(
        launch: (_, _, {workingDirectory}) async =>
            throw StateError('External endpoint must not launch'),
        respond: (request) async {
          expect(request.url.queryParameters['t'], 'indexers');
          expect(request.url.queryParameters['configured'], 'true');
          expect(request.url.queryParameters['apikey'], 'secret');
          return http.Response(
            '<indexers><indexer id="rutracker-ru" configured="true"/>'
            '<indexer id="rutracker" configured="$configured"/></indexers>',
            200,
          );
        },
      );
      const connection = JackettConnection(
        baseUrl: 'http://localhost:9117',
        apiKey: 'secret',
      );
      expect(await service!.isRuTrackerConfigured(connection), isFalse);
      configured = true;
      expect(await service!.isRuTrackerConfigured(connection), isTrue);
    },
  );

  test(
    'redacts split key output on early exit and allows a clean retry',
    () async {
      var launches = 0;
      var process = FakeJackettProcess();
      service = fakeService(
        launch: (_, _, {workingDirectory}) async {
          launches++;
          process = FakeJackettProcess();
          if (launches == 1) {
            final config =
                jsonDecode(
                      await File(
                        '${root.path}/jackett/ServerConfig.json',
                      ).readAsString(),
                    )
                    as Map;
            final key = config['APIKey'] as String;
            final exiting = process;
            Timer(const Duration(milliseconds: 10), () {
              exiting.output.add(utf8.encode('apikey=${key.substring(0, 12)}'));
              exiting.output.add(utf8.encode('${key.substring(12)}\n'));
              exiting.errors.add(utf8.encode('startup failed\n'));
              exiting.finish(23);
            });
          }
          return process;
        },
        respond: (request) async {
          if (request.method == 'POST') {
            process.finish(0);
            return http.Response('', 200);
          }
          if (launches == 1) return Completer<http.Response>().future;
          return http.Response('<caps/>', 200);
        },
      );
      Object? failure;
      try {
        await service!.start();
      } catch (error) {
        failure = error;
      }
      expect(failure.toString(), contains('код 23'));
      final config =
          jsonDecode(
                await File(
                  '${root.path}/jackett/ServerConfig.json',
                ).readAsString(),
              )
              as Map;
      final log = await File('${root.path}/jackett/startup.log').readAsString();
      expect(log, contains('[REDACTED]'));
      expect(log, contains('startup failed'));
      expect(log, isNot(contains(config['APIKey'])));
      expect(failure.toString(), isNot(contains(config['APIKey'])));
      await service!.start();
      expect(launches, 2);
    },
  );

  test(
    'stops an unready process and does not accept a Torznab error as ready',
    () async {
      final process = FakeJackettProcess();
      service = fakeService(
        timeout: const Duration(milliseconds: 20),
        launch: (_, _, {workingDirectory}) async => process,
        respond: (_) async => http.Response(
          '<error code="100" description="Invalid API Key"/>',
          200,
        ),
      );
      await expectLater(service!.start(), throwsStateError);
      expect(process.kills, 1);
    },
  );

  test(
    'native bundled Jackett serves caps and indexer inventory on localhost',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        service = JackettService(root);
        final connection = await service!.start();
        expect(connection.baseUrl, startsWith('http://127.0.0.1:'));
        expect(connection.apiKey, isNotEmpty);
        expect(await service!.isRuTrackerConfigured(connection), isFalse);
        final client = http.Client();
        try {
          final login = http.Request(
            'GET',
            Uri.parse('${connection.baseUrl}/UI/Login?cookiesChecked=1'),
          )..followRedirects = false;
          final authenticated = await http.Response.fromStream(
            await client.send(login),
          );
          final cookie = RegExp(
            r'Jackett=[^;,]+',
          ).firstMatch(authenticated.headers['set-cookie'] ?? '')?.group(0);
          expect(cookie, isNotNull);
          final headers = {'Cookie': cookie!};
          final response = await client.get(
            Uri.parse('${connection.baseUrl}/api/v2.0/server/config'),
            headers: headers,
          );
          expect(response.statusCode, 200);
          final config = jsonDecode(response.body) as Map;
          expect(config['api_key'] == connection.apiKey, isTrue);
          expect(config['external'], isFalse);
          expect(config['updatedisabled'], isTrue);
          final indexers = await client.get(
            Uri.parse('${connection.baseUrl}/api/v2.0/indexers'),
            headers: headers,
          );
          final all = jsonDecode(indexers.body) as List;
          expect(all.any((item) => item['id'] == 'rutracker'), isTrue);
        } finally {
          client.close();
        }
        await service!.stop();
        final log = await File(
          '${root.path}/jackett/startup.log',
        ).readAsString();
        expect(log, isNot(contains(connection.apiKey)));
      }, RealNetwork());
    },
    skip:
        !Platform.isWindows ||
        Platform.environment['MUMPA_TEST_JACKETT'] != '1',
  );
}
