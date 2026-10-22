import 'dart:async';

class SourceCancelled implements Exception {
  const SourceCancelled();
}

/// Cancels only the current source request, without closing shared clients.
class SourceOperation {
  final _cancelled = Completer<void>();
  final _listeners = <void Function()>{};
  bool get cancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (cancelled) return;
    _cancelled.complete();
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  /// The owner removes its callback when work settles, so a long-lived scope
  /// does not retain a listener for every request it has ever awaited.
  void Function() onCancel(void Function() listener) {
    if (cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void check() {
    if (cancelled) throw const SourceCancelled();
  }

  Future<T> wait<T>(Future<T> pending) async {
    check();
    final result = Completer<T>();
    final remove = onCancel(() {
      if (!result.isCompleted) result.completeError(const SourceCancelled());
    });
    unawaited(
      pending.then<void>(
        (value) {
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    try {
      return await result.future;
    } finally {
      remove();
    }
  }
}
