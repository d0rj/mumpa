import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/torrent_service.dart';

class FakeEngineProcess implements Process {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final completion = Completer<int>();
  var kills = 0;

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

class TrackingClient extends MockClient {
  TrackingClient(super.fn);
  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test(
    'peer candidates avoid TCP auto-select and spread beyond exclusion blocks',
    () {
      final candidates = torrentPeerPortCandidates(59486, random: Random(1));
      expect(candidates.first, 59486);
      expect(candidates.length, 64);
      expect(candidates.toSet().length, 64);
      expect(candidates.every((port) => port >= 1024 && port <= 65535), isTrue);
      expect(candidates.any((port) => port < 49152), isTrue);
      expect(
        candidates.reduce(max) - candidates.reduce(min),
        greaterThan(50000),
      );
      final automatic = torrentPeerPortCandidates(0, random: Random(1));
      expect(automatic, isNot(contains(0)));
    },
  );
  late Directory root;
  late TorrentEngine engine;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-engine-');
    engine = TorrentEngine(root);
  });
  tearDown(() async {
    await engine.stop();
    await root.delete(recursive: true);
  });

  test(
    'bootstrap probes stay local across launches and release both ports',
    () async {
      final tcpAddresses = <InternetAddress>[];
      final udpAddresses = <InternetAddress>[];
      final executables = <String>[];
      engine = TorrentEngine.testing(
        root,
        executable: File('${root.path}/stable-engine.exe'),
        clientFactory: () =>
            MockClient((_) async => http.Response('ready', 200)),
        tcpBinder: (address, port) async {
          tcpAddresses.add(address);
          final socket = await ServerSocket.bind(address, port);
          expect(socket.address.isLoopback, isTrue);
          return socket;
        },
        udpBinder: (address, port) async {
          udpAddresses.add(address);
          final socket = await RawDatagramSocket.bind(
            address,
            port,
            reuseAddress: false,
          );
          expect(socket.address.isLoopback, isTrue);
          return socket;
        },
        startProcess: (executable, arguments) async {
          executables.add(executable);
          final peerAddress = arguments[arguments.indexOf('--torrentaddr') + 1];
          expect(peerAddress, startsWith('0.0.0.0:'));
          final peerPort = int.parse(peerAddress.split(':').last);
          // Both preflight sockets are already closed when native ownership starts.
          final tcp = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            peerPort,
          );
          final udp = await RawDatagramSocket.bind(
            InternetAddress.loopbackIPv4,
            peerPort,
            reuseAddress: false,
          );
          udp.close();
          await tcp.close();
          return FakeEngineProcess();
        },
      );
      await engine.start();
      await engine.stop();
      await engine.start();
      expect(executables, hasLength(2));
      expect(executables.toSet(), {'${root.path}/stable-engine.exe'});
      // Excluded UDP ranges may require extra candidates on Windows.
      expect(tcpAddresses.length, greaterThanOrEqualTo(4));
      expect(udpAddresses.length, greaterThanOrEqualTo(2));
      expect(tcpAddresses.every((address) => address.isLoopback), isTrue);
      expect(udpAddresses.every((address) => address.isLoopback), isTrue);
    },
  );

  test(
    'missing selected network prevents native startup and permits system retry',
    () async {
      var selected = 'mumpa-test-nonexistent-interface';
      var launches = 0;
      engine = TorrentEngine.testing(
        root,
        executable: File('${root.path}/stable-engine.exe'),
        networkInterface: () => selected,
        clientFactory: () =>
            MockClient((_) async => http.Response('ready', 200)),
        startProcess: (_, arguments) async {
          launches++;
          expect(
            arguments[arguments.indexOf('--torrentaddr') + 1],
            startsWith('0.0.0.0:'),
          );
          return FakeEngineProcess();
        },
      );
      await expectLater(engine.start(), throwsStateError);
      expect(launches, 0);
      selected = '';
      await engine.start();
      expect(launches, 1);
    },
  );

  test(
    'skips TCP-available ports occupied by UDP and retains peer transports',
    () async {
      final occupied = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        reuseAddress: false,
      );
      final unavailable = occupied.port;
      var selected = 0;
      final process = FakeEngineProcess();
      engine = TorrentEngine.testing(
        root,
        executable: File('${root.path}/stable-engine.exe'),
        preferredPeerPort: unavailable,
        clientFactory: () =>
            MockClient((_) async => http.Response('ready', 200)),
        startProcess: (executable, arguments) async {
          expect(executable, '${root.path}/stable-engine.exe');
          expect(arguments[arguments.indexOf('-i') + 1], '127.0.0.1');
          final address = arguments[arguments.indexOf('--torrentaddr') + 1];
          expect(address, startsWith('0.0.0.0:'));
          selected = int.parse(address.split(':').last);
          expect(selected, isNot(unavailable));
          expect(selected, isNot(int.parse(arguments[1])));
          // The production reservation has been released for the native process,
          // and this exact port permits both transports at the same time.
          final tcp = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            selected,
          );
          final udp = await RawDatagramSocket.bind(
            InternetAddress.loopbackIPv4,
            selected,
            reuseAddress: false,
          );
          udp.close();
          await tcp.close();
          return process;
        },
      );
      try {
        await engine.start();
        expect(selected, greaterThan(0));
        final settings =
            jsonDecode(
                  await File(
                    '${root.path}/engine/settings.json',
                  ).readAsString(),
                )['BitTorr']
                as Map;
        expect(settings['DisableDHT'], isNot(true));
        expect(settings['DisableUTP'], isNot(true));
        expect(settings['DisableUPNP'], isTrue);
        expect(settings['EnableLPD'], isFalse);
      } finally {
        occupied.close();
      }
    },
  );

  test(
    'reports early process exit, retains both logs and permits retry',
    () async {
      var launches = 0;
      final clients = <TrackingClient>[];
      final paths = <String>[];
      final processes = <FakeEngineProcess>[];
      engine = TorrentEngine.testing(
        root,
        executable: File('${root.path}/stable-engine.exe'),
        clientFactory: () {
          final client = TrackingClient((_) async {
            if (launches == 1) return Completer<http.Response>().future;
            return http.Response('ready', 200);
          });
          clients.add(client);
          return client;
        },
        startProcess: (executable, _) async {
          paths.add(executable);
          final process = FakeEngineProcess();
          processes.add(process);
          launches++;
          if (launches == 1) {
            Timer(const Duration(milliseconds: 10), () {
              process.output.add(utf8.encode('BTS.Connect() error!\n'));
              process.errors.add(utf8.encode('udp bind forbidden\n'));
              process.finish(17);
            });
          }
          return process;
        },
      );
      final watch = Stopwatch()..start();
      await expectLater(
        engine.start(),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('код 17') &&
                error.toString().contains('udp bind forbidden'),
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      final log = await File('${root.path}/engine/startup.log').readAsString();
      expect(log, contains('[stdout] BTS.Connect() error!'));
      expect(log, contains('[stderr] udp bind forbidden'));
      expect(log, contains('exit code=17'));
      expect(clients.single.closed, isTrue);
      await engine.start();
      expect(launches, 2);
      expect(paths.toSet(), {'${root.path}/stable-engine.exe'});
      await engine.stop();
      expect(processes.last.kills, 1);
      expect(
        await File('${root.path}/engine/startup.log').readAsString(),
        contains('udp bind forbidden'),
      );
    },
  );

  test('cleans a process that never becomes ready before retry', () async {
    var ready = false;
    final processes = <FakeEngineProcess>[];
    final clients = <TrackingClient>[];
    engine = TorrentEngine.testing(
      root,
      executable: File('${root.path}/stable-engine.exe'),
      startupTimeout: const Duration(milliseconds: 60),
      clientFactory: () {
        final client = TrackingClient(
          (_) async =>
              http.Response(ready ? 'ready' : 'waiting', ready ? 200 : 503),
        );
        clients.add(client);
        return client;
      },
      startProcess: (_, _) async {
        final process = FakeEngineProcess();
        processes.add(process);
        return process;
      },
    );
    await expectLater(engine.start(), throwsStateError);
    expect(processes.single.kills, 1);
    expect(clients.single.closed, isTrue);
    ready = true;
    await engine.start();
    expect(processes.length, 2);
  });

  test(
    'stop during native launch cleans the late process before restart',
    () async {
      final launchRequested = Completer<void>();
      final pendingProcess = Completer<Process>();
      final process = FakeEngineProcess();
      var launches = 0;
      engine = TorrentEngine.testing(
        root,
        executable: File('${root.path}/stable-engine.exe'),
        clientFactory: () =>
            MockClient((_) async => http.Response('ready', 200)),
        startProcess: (_, _) async {
          launches++;
          if (launches == 1) {
            launchRequested.complete();
            return pendingProcess.future;
          }
          return FakeEngineProcess();
        },
      );
      final initial = engine.start();
      final cancellation = expectLater(
        initial,
        throwsA(predicate((error) => error.toString().contains('отменён'))),
      );
      await launchRequested.future;
      final stopping = engine.stop();
      pendingProcess.complete(process);
      await stopping;
      await cancellation;
      expect(process.kills, 1);
      await engine.start();
      expect(launches, 2);
    },
  );

  test(
    'shares concurrent startup and restarts after a ready process exits',
    () async {
      final processes = <FakeEngineProcess>[];
      engine = TorrentEngine.testing(
        root,
        executable: File('${root.path}/stable-engine.exe'),
        clientFactory: () =>
            MockClient((_) async => http.Response('ready', 200)),
        startProcess: (_, _) async {
          final process = FakeEngineProcess();
          processes.add(process);
          return process;
        },
      );
      final first = engine.start();
      final second = engine.start();
      expect(identical(first, second), isTrue);
      expect(await first, await second);
      expect(processes.length, 1);
      processes.single.finish(1);
      await Future<void>.delayed(Duration.zero);
      await engine.start();
      expect(processes.length, 2);
    },
  );
}
