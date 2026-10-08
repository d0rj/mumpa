import 'dart:async';

class SourceCancelled implements Exception {
  const SourceCancelled();
}

/// Cancels only the current source request, without closing shared clients.
class SourceOperation {
  final _cancelled = Completer<void>();
  bool get cancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!cancelled) _cancelled.complete();
  }

  void check() {
    if (cancelled) throw const SourceCancelled();
  }

  Future<T> wait<T>(Future<T> pending) {
    check();
    return Future.any([
      pending,
      whenCancelled.then<T>((_) => throw const SourceCancelled()),
    ]);
  }
}
