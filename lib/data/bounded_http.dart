import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'source_operation.dart';

/// Bounds the *stream*, including error bodies, and aborts the actual request
/// on expiry. The shared client remains available to unrelated requests.
Future<http.Response> sendBounded(
  http.Client client,
  http.BaseRequest Function(Future<void> abort) build, {
  required int maxBytes,
  required Duration timeout,
  SourceOperation? operation,
}) async {
  operation?.check();
  final abort = Completer<void>();
  var timedOut = false;
  final trigger = abort.future;
  final removeCancellation = operation?.onCancel(() {
    if (!abort.isCompleted) abort.complete();
  });
  final deadline = Timer(timeout, () {
    timedOut = true;
    if (!abort.isCompleted) abort.complete();
  });
  StreamIterator<List<int>>? body;
  var bodyDone = false;
  Future<void>? bodyCancellation;
  Future<void> cancelBody() =>
      bodyCancellation ??= body!.cancel().then<void>((_) {});
  void check() {
    if (timedOut) throw TimeoutException('Сервер не ответил вовремя.');
    operation?.check();
  }

  Future<http.Response> read() async {
    final response = await client.send(build(trigger));
    // send() may complete after its caller has already timed out/cancelled.
    try {
      check();
      if (response.contentLength != null &&
          response.contentLength! > maxBytes) {
        throw const FormatException('Ответ сервера слишком большой.');
      }
    } catch (_) {
      // StreamIterator.cancel does not subscribe before its first moveNext.
      await response.stream.listen((_) {}).cancel();
      rethrow;
    }
    final stream = body = StreamIterator(response.stream);
    try {
      final bytes = BytesBuilder(copy: false);
      while (await stream.moveNext()) {
        check();
        if (bytes.length + stream.current.length > maxBytes) {
          throw const FormatException('Ответ сервера слишком большой.');
        }
        bytes.add(stream.current);
      }
      bodyDone = true;
      check();
      return http.Response.bytes(
        bytes.takeBytes(),
        response.statusCode,
        headers: response.headers,
        request: response.request,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } finally {
      if (!bodyDone) await cancelBody();
    }
  }

  try {
    return await Future.any([
      read(),
      trigger.then<http.Response>((_) {
        check();
        throw const SourceCancelled();
      }),
    ]);
  } finally {
    deadline.cancel();
    removeCancellation?.call();
    if (!abort.isCompleted) abort.complete();
    if (body != null && !bodyDone) await cancelBody();
  }
}

Future<http.Response> getBounded(
  http.Client client,
  Uri uri, {
  int maxBytes = 4 * 1024 * 1024,
  Duration timeout = const Duration(seconds: 20),
  Map<String, String>? headers,
  SourceOperation? operation,
}) => sendBounded(
  client,
  (abort) =>
      http.AbortableRequest('GET', uri, abortTrigger: abort)
        ..headers.addAll(headers ?? const {}),
  maxBytes: maxBytes,
  timeout: timeout,
  operation: operation,
);

Future<http.Response> postBounded(
  http.Client client,
  Uri uri, {
  String body = '',
  int maxBytes = 4 * 1024 * 1024,
  Duration timeout = const Duration(seconds: 20),
  Map<String, String>? headers,
}) => sendBounded(
  client,
  (abort) => http.AbortableRequest('POST', uri, abortTrigger: abort)
    ..headers.addAll(headers ?? const {})
    ..body = body,
  maxBytes: maxBytes,
  timeout: timeout,
);
