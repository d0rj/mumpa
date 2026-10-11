import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/radio_repository.dart';
import '../data/source_operation.dart';
import '../domain/models.dart';

/// Keeps a small, cancellable buffer. It never touches the audio decoder.
class PlaylistRadio extends ChangeNotifier {
  PlaylistRadio({
    this.source,
    this.capacity = 6,
    this.preparationTimeout = const Duration(minutes: 2),
    this.candidateTimeout = const Duration(seconds: 35),
  });
  RadioSource? source;
  final int capacity;
  final Duration preparationTimeout, candidateTimeout;
  final List<PreparedRadioTrack> _ready = [];
  final Set<String> _attempted = {};
  final Map<String, DateTime> _unavailable = {};
  List<Track> _seeds = const [];
  SourceOperation? _operation;
  Future<void>? _pending;
  final Set<Future<void>> _jobs = {};
  bool _closed = false, exhausted = false;
  String? message;
  bool get preparing => _operation != null;
  int get readyCount => _ready.length;

  void reset(List<Track> seeds) {
    cancel();
    _seeds = List.unmodifiable(seeds);
    _attempted.clear();
    exhausted = false;
    message = null;
  }

  void updateSeeds(List<Track> seeds) {
    _seeds = List.unmodifiable(seeds);
  }

  void cancel() {
    _operation?.cancel();
    _operation = null;
    _pending = null;
    _ready.clear();
    _attempted.clear();
    exhausted = false;
    message = null;
    if (!_closed) notifyListeners();
  }

  void reject(Track track) {
    if (track.torrentHash != null) {
      if (_unavailable.length >= 100) {
        _unavailable.remove(_unavailable.keys.first);
      }
      _unavailable[track.torrentHash!] = DateTime.now().add(
        const Duration(minutes: 10),
      );
      _ready.removeWhere((item) => item.track.torrentHash == track.torrentHash);
    }
    _attempted.add(radioSongKey(track));
  }

  bool _blocked(Track track) =>
      track.torrentHash != null &&
      (_unavailable[track.torrentHash]?.isAfter(DateTime.now()) ?? false);

  PreparedRadioTrack? take(String? previousArtist) {
    _ready.removeWhere((item) => _blocked(item.track));
    if (_ready.isEmpty) return null;
    final different = _ready.indexWhere(
      (item) => radioArtist(item.track) != previousArtist,
    );
    final item = _ready.removeAt(different < 0 ? 0 : different);
    notifyListeners();
    return item;
  }

  Future<void> fill(Set<String> excluded) {
    if (_closed ||
        source == null ||
        exhausted ||
        _seeds.isEmpty ||
        _ready.length >= capacity) {
      return Future.value();
    }
    if (_pending != null) return _pending!;
    final operation = _operation = SourceOperation();
    final job = _fill(excluded, operation);
    _pending = job;
    _jobs.add(job);
    unawaited(job.whenComplete(() => _jobs.remove(job)));
    return job;
  }

  /// Start playback as soon as one candidate is ready, while the rest warm up.
  Future<void> waitForReady(Set<String> excluded) async {
    final pending = fill(excluded);
    if (_ready.isNotEmpty || !preparing) return;
    final available = Completer<void>();
    void changed() {
      if ((_ready.isNotEmpty || !preparing) && !available.isCompleted) {
        available.complete();
      }
    }

    addListener(changed);
    try {
      changed();
      await Future.any([pending, available.future]);
    } finally {
      removeListener(changed);
    }
  }

  Future<void> _fill(Set<String> excluded, SourceOperation operation) async {
    // Deferring ensures _pending is installed before an empty stream finishes.
    await Future<void>.delayed(Duration.zero);
    final deadline = Timer(preparationTimeout, operation.cancel);
    StreamIterator<Track>? iterator;
    try {
      operation.check();
      notifyListeners();
      final blocked = {
        ...excluded,
        ..._attempted,
        ..._ready.map((item) => radioSongKey(item.track)),
      };
      iterator = StreamIterator(source!.candidates(_seeds, blocked, operation));
      var inspected = 0;
      while (_ready.length < capacity &&
          inspected < 24 &&
          await operation.wait(iterator.moveNext())) {
        final track = iterator.current;
        final key = radioSongKey(track);
        if (blocked.contains(key) || _blocked(track)) continue;
        blocked.add(key);
        _attempted.add(key);
        if (_attempted.length > 5000) _attempted.remove(_attempted.first);
        inspected++;
        final child = SourceOperation();
        unawaited(operation.whenCancelled.then((_) => child.cancel()));
        try {
          final ready = await operation
              .wait(source!.prepare(track, child))
              .timeout(candidateTimeout);
          operation.check();
          _ready.add(ready);
          message = null;
          notifyListeners();
        } on SourceCancelled {
          operation.check();
        } catch (_) {
          reject(track);
        } finally {
          child.cancel();
        }
      }
      operation.check();
      exhausted = _ready.isEmpty;
      if (exhausted) message = 'Новых доступных треков пока нет';
    } on SourceCancelled {
      if (!identical(_operation, operation)) return;
      exhausted = _ready.isEmpty;
      if (exhausted) message = 'Не удалось подготовить продолжение';
    } catch (_) {
      if (identical(_operation, operation)) {
        exhausted = _ready.isEmpty;
        message = 'Поиск продолжения временно недоступен';
      }
    } finally {
      deadline.cancel();
      operation.cancel();
      await iterator?.cancel();
      if (identical(_operation, operation)) {
        _operation = null;
        _pending = null;
        if (!_closed) notifyListeners();
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    cancel();
    await Future.wait(_jobs.toList());
    dispose();
  }
}
