import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/bounded_http.dart';
import 'package:mumpa/data/public_music_catalog.dart';
import 'package:mumpa/data/source_operation.dart';

class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() => closed = true;
}

void main() {
  final uri = Uri.https('example.test', '/');
  testWidgets('a completed response settles during widget frame pumping', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    final client = MockClient((_) => response.future);
    http.Response? result;
    final loading = getBounded(client, uri).then((value) => result = value);
    await tester.pump();
    response.complete(http.Response('ok', 200));
    await tester.pump();
    await tester.pump();
    expect(result?.body, 'ok');
    await loading;
  });
  test('catalog stops reading a chunked response at its byte budget', () async {
    var chunks = 0;
    bool cancelled = false;
    Stream<List<int>> data() async* {
      try {
        for (var i = 0; i < 100; i++) {
          chunks++;
          yield List.filled(64 * 1024, 32);
        }
      } finally {
        cancelled = true;
      }
    }

    final client = _Client((_) async => http.StreamedResponse(data(), 200));
    await expectLater(
      PublicMusicCatalog.search(client, 'Band'),
      throwsA(anything),
    );
    expect(chunks, 65);
    expect(cancelled, isTrue);
    expect(client.closed, isFalse);
  });

  test(
    'declared oversized error bodies are cancelled before reading',
    () async {
      var cancelled = false;
      final data = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final client = _Client(
        (_) async =>
            http.StreamedResponse(data.stream, 503, contentLength: 1000),
      );
      try {
        await expectLater(
          getBounded(client, uri, maxBytes: 10),
          throwsFormatException,
        );
        expect(cancelled, isTrue);
      } finally {
        await data.close();
      }
    },
  );

  test(
    'total deadline aborts a stalled body and leaves shared client usable',
    () async {
      var cancelled = false, requests = 0;
      Future<void>? abort;
      final data = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final client = _Client((request) async {
        if (++requests == 1) {
          abort = (request as http.Abortable).abortTrigger;
          return http.StreamedResponse(data.stream, 200);
        }
        return http.StreamedResponse(Stream.value(utf8.encode('ok')), 200);
      });
      try {
        await expectLater(
          getBounded(client, uri, timeout: const Duration(milliseconds: 30)),
          throwsA(isA<TimeoutException>()),
        );
        await abort!.timeout(const Duration(seconds: 1));
        expect(cancelled, isTrue);
        expect((await getBounded(client, uri)).body, 'ok');
        expect(client.closed, isFalse);
      } finally {
        await data.close();
      }
    },
  );

  test(
    'late headers after cancellation cannot leave an unread live body',
    () async {
      final headers = Completer<http.StreamedResponse>();
      final sent = Completer<void>(), cancelled = Completer<void>();
      final data = StreamController<List<int>>(onCancel: cancelled.complete);
      final client = _Client((_) {
        sent.complete();
        return headers.future;
      });
      final operation = SourceOperation();
      final result = expectLater(
        getBounded(client, uri, operation: operation),
        throwsA(isA<SourceCancelled>()),
      );
      await sent.future;
      operation.cancel();
      await result;
      headers.complete(http.StreamedResponse(data.stream, 200));
      await cancelled.future.timeout(const Duration(seconds: 1));
      await data.close();
    },
  );
}
