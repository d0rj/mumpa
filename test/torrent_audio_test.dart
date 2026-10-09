import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';

void main() {
  late HttpServer server;
  late TorrentService service;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    service = TorrentService(endpoint: () async => base(server));
  });
  tearDown(() async {
    service.dispose();
    await server.close(force: true);
  });

  test('HTTP headers alone do not establish audio readiness', () async {
    final arrived = Completer<void>();
    final payload = Completer<void>();
    server.listen((request) async {
      expect(request.headers.value('range'), 'bytes=0-4095');
      request.response.statusCode = 206;
      request.response.contentLength = 4;
      await request.response.flush();
      arrived.complete();
      await payload.future;
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    var ready = false;
    final waiting = service.waitForAudio(Uri.parse('${base(server)}/stream'))
      ..then((_) => ready = true);
    await arrived.future;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(ready, isFalse);
    payload.complete();
    await waiting;
    expect(ready, isTrue);
  });

  test('peerless response expires and closes its HTTP connection', () async {
    // HttpServer retains an outstanding response in connectionsInfo even after
    // the client closes. Observe EOF on the actual TCP socket instead.
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final disconnected = Completer<void>();
    Socket? peer;
    raw.listen((socket) {
      peer = socket;
      var answered = false;
      socket.listen((bytes) {
        if (answered) return;
        answered = true;
        socket.write(
          'HTTP/1.1 206 Partial Content\r\n'
          'Content-Length: 4096\r\n'
          'Content-Range: bytes 0-4095/4096\r\n\r\n',
        );
      }, onDone: () => disconnected.complete());
    });
    try {
      await expectLater(
        service.waitForAudio(
          Uri.parse('http://127.0.0.1:${raw.port}/stream'),
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await disconnected.future.timeout(const Duration(seconds: 2));
    } finally {
      peer?.destroy();
      await raw.close();
    }
  });

  test(
    'cancel aborts only this probe and keeps the shared client usable',
    () async {
      final arrived = Completer<void>();
      server.listen((request) async {
        if (request.uri.path == '/ok') {
          request.response.write('ok');
          await request.response.close();
          return;
        }
        request.response.statusCode = 206;
        request.response.contentLength = 4096;
        await request.response.flush();
        arrived.complete();
      });
      final operation = SourceOperation();
      final waiting = service.waitForAudio(
        Uri.parse('${base(server)}/stream'),
        operation: operation,
      );
      final cancelled = expectLater(waiting, throwsA(isA<SourceCancelled>()));
      await arrived.future;
      operation.cancel();
      await cancelled;
      final response = await service.client.get(
        Uri.parse('${base(server)}/ok'),
      );
      expect(response.body, 'ok');
    },
  );
}

String base(HttpServer server) => 'http://127.0.0.1:${server.port}';
