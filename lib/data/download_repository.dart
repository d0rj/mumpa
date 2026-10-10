import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/models.dart';
import 'library_repository.dart';
import 'source_operation.dart';
import 'torrent_service.dart';

enum DownloadState { queued, downloading, paused, complete, failed }

class DownloadJob {
  DownloadJob(this.track, {this.state = DownloadState.queued});
  final Track track;
  DownloadState state;
  int received = 0;
  int total = 0;
  String? error;
  bool cancelled = false;
  HttpClient? client;
  _DownloadAttempt? _attempt;
  Future<void>? _completion;
  double? get progress => total > 0 ? (received / total).clamp(0, 1) : null;
}

class DownloadRepository extends ChangeNotifier {
  DownloadRepository(this.library, this.torrents, {int? maxConcurrentDownloads})
    : _maxConcurrentDownloads = _readConcurrency(
        maxConcurrentDownloads ?? library.settings['downloadConcurrency'],
      );
  final LibraryRepository library;
  final TorrentService torrents;
  final Map<String, DownloadJob> _jobs = {};
  final List<String> _pending = [];
  final Map<String, DownloadJob> _active = {};
  final Map<String, Future<void>> _removals = {};
  final Map<_DownloadAttempt, _DownloadReservation> _reservations = {};
  Future<void> _quotaTail = Future.value();
  final Set<String> _priority = {};
  int _maxConcurrentDownloads;
  bool _pumping = false;
  bool _disposed = false;
  static int _readConcurrency(Object? value) =>
      value is num && value.toInt() >= 1 && value.toInt() <= 6
      ? value.toInt()
      : 3;

  int get maxConcurrentDownloads => _maxConcurrentDownloads;

  Future<void> setMaxConcurrentDownloads(int value) async {
    RangeError.checkValueInInterval(value, 1, 6, 'maxConcurrentDownloads');
    if (_disposed) return;
    await library.setSetting('downloadConcurrency', value);
    if (_disposed) return;
    _maxConcurrentDownloads = value;
    var excess = _active.length - value;
    for (final job in _active.values.toList().reversed) {
      if (excess <= 0) break;
      if (_priority.contains(job.track.id) || !_yield(job)) continue;
      excess--;
    }
    notifyListeners();
    _pump();
  }

  List<DownloadJob> get jobs => List.unmodifiable(_jobs.values);
  bool active(String id) => {
    DownloadState.queued,
    DownloadState.downloading,
  }.contains(_jobs[id]?.state);
  Future<void> restore() async {
    final directory = library.downloads;
    await directory.create(recursive: true);
    // A large torrent collection can contain thousands of uncached tracks.
    // List the few existing transfers once instead of stat'ing every missing
    // .part file during application startup. Do not follow unrelated links.
    final partials = <String, File>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && p.extension(entity.path).toLowerCase() == '.part') {
        partials[_restorePathKey(entity.path)] = entity;
      }
    }
    for (final track in library.tracks.where(
      (t) => t.source == TrackSource.torrent && t.cachedPath == null,
    )) {
      final partial = partials[_restorePathKey('${_path(track)}.part')];
      if (partial != null) {
        final job = DownloadJob(track, state: DownloadState.paused)
          ..received = await partial.length()
          ..total = track.bytes;
        _jobs[track.id] = job;
      }
    }
    notifyListeners();
  }

  String _restorePathKey(String path) {
    final normalized = p.normalize(p.absolute(path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  String _path(Track track) {
    final ext = p.extension(track.torrentPath ?? '').toLowerCase();
    return p.join(library.downloads.path, '${track.id}$ext');
  }

  /// A playing track gets the next slot. Only when all slots are occupied does
  /// one background transfer yield, retaining its partial file for resumption.
  void enqueue(Iterable<Track> tracks, {bool priority = false}) {
    if (_disposed) return;
    final selected = <String>[];
    for (final track in tracks) {
      final latest = library.byId(track.id) ?? track;
      if (latest.source != TrackSource.torrent || latest.cachedPath != null) {
        continue;
      }
      if (_removals.containsKey(track.id)) continue;
      final job = _jobs.putIfAbsent(track.id, () => DownloadJob(latest));
      if (job.state == DownloadState.complete) continue;
      selected.add(track.id);
      if (_active.containsKey(track.id) &&
          job.state == DownloadState.downloading) {
        continue;
      }
      job.cancelled = false;
      job.error = null;
      job.state = DownloadState.queued;
      if (!_pending.contains(track.id)) _pending.add(track.id);
    }
    if (priority && selected.isNotEmpty) {
      _priority
        ..clear()
        ..addAll(selected);
      final promoted = selected.toSet().where(_pending.contains).toList();
      _pending.removeWhere(promoted.contains);
      _pending.insertAll(0, promoted);
      final occupied = _active.values
          .where((job) => job._attempt?.cancelled != true)
          .length;
      var needed =
          promoted.where((id) => !_active.containsKey(id)).length -
          (_maxConcurrentDownloads - occupied);
      for (final job in _active.values.toList().reversed) {
        if (needed <= 0) break;
        if (_priority.contains(job.track.id)) continue;
        if (_yield(job, after: promoted.length)) needed--;
      }
    }
    notifyListeners();
    _pump();
  }

  void pause(String id) {
    if (_disposed) return;
    final job = _jobs[id];
    if (job == null) return;
    if (job.state == DownloadState.complete) return;
    _pending.remove(id);
    _interrupt(job, DownloadState.paused);
    notifyListeners();
  }

  void retry(String id) {
    final job = _jobs[id];
    if (job == null) return;
    if (_disposed ||
        _removals.containsKey(id) ||
        job.state == DownloadState.complete) {
      return;
    }
    if (job.state == DownloadState.downloading) return;
    job.cancelled = false;
    job.error = null;
    job.state = DownloadState.queued;
    if (!_pending.contains(id)) _pending.add(id);
    notifyListeners();
    _pump();
  }

  void _pump() {
    if (_pumping || _disposed) return;
    _pumping = true;
    try {
      while (!_disposed && _active.length < _maxConcurrentDownloads) {
        _pending.removeWhere((id) => _jobs[id]?.state != DownloadState.queued);
        final index = _pending.indexWhere(
          (id) => !_active.containsKey(id) && !_removals.containsKey(id),
        );
        if (index < 0) break;
        final job = _jobs[_pending.removeAt(index)]!;
        final completion = Completer<void>();
        final attempt = _DownloadAttempt();
        job._completion = completion.future;
        job._attempt = attempt;
        _active[job.track.id] = job;
        unawaited(_run(job, attempt, completion));
      }
    } finally {
      _pumping = false;
    }
  }

  bool _yield(DownloadJob job, {int? after}) {
    if (job.state != DownloadState.downloading ||
        !_interrupt(job, DownloadState.queued)) {
      return false;
    }
    if (!_pending.contains(job.track.id)) {
      _pending.insert(after ?? _pending.length, job.track.id);
    }
    return true;
  }

  Future<void> _run(
    DownloadJob job,
    _DownloadAttempt attempt,
    Completer<void> completion,
  ) async {
    try {
      await _download(job, attempt);
    } catch (e) {
      if (!attempt.cancelled) {
        job.state = DownloadState.failed;
        job.error = e.toString();
      }
    } finally {
      // A retry cannot reuse this path until its writer and reservation close.
      await _withQuotaLock(() async {
        _reservations.remove(attempt);
      });
      if (identical(job._attempt, attempt)) {
        job._attempt = null;
        job._completion = null;
        _active.remove(job.track.id);
        if (job.state != DownloadState.queued) _priority.remove(job.track.id);
      }
      completion.complete();
      if (!_disposed) {
        notifyListeners();
        _pump();
      }
    }
  }

  bool _interrupt(DownloadJob job, DownloadState state) {
    if (job._attempt?.finishing == true) return false;
    job.cancelled = true;
    job.state = state;
    job._attempt?.cancel();
    return true;
  }

  Future<void> _download(DownloadJob job, _DownloadAttempt attempt) async {
    job.cancelled = false;
    job.state = DownloadState.downloading;
    notifyListeners();
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 15);
    job.client = client;
    attempt.client = client;
    final target = File(_path(job.track));
    final partial = File('${target.path}.part');
    IOSink? sink;
    try {
      await partial.parent.create(recursive: true);
      final partialBytes = await partial.exists() ? await partial.length() : 0;
      await _reserve(
        attempt,
        target,
        partial,
        job.track.bytes > partialBytes ? job.track.bytes : partialBytes,
      );
      attempt.check();
      final uri = await attempt.wait(
        torrents.resolve(job.track, operation: attempt.operation),
      );
      attempt.check();
      var offset = await partial.exists() ? await partial.length() : 0;
      final request = await attempt.wait(client.getUrl(uri));
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      }
      final response = await attempt.wait(
        request.close().timeout(const Duration(seconds: 90)),
      );
      attempt.check();
      if (response.statusCode == 416 &&
          offset == job.track.bytes &&
          offset > 0) {
        await response.drain<void>();
        // The file was completely written before the previous process stopped.
      } else {
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw HttpException('Загрузка: HTTP ${response.statusCode}.');
        }
        if (response.statusCode == 200) offset = 0;
        int? rangeTotal;
        if (response.statusCode == 206) {
          final range = response.headers.value(HttpHeaders.contentRangeHeader);
          final match = range == null
              ? null
              : RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(range);
          final start = int.tryParse(match?.group(1) ?? '');
          final end = int.tryParse(match?.group(2) ?? '');
          rangeTotal = int.tryParse(match?.group(3) ?? '');
          if (start != offset ||
              end == null ||
              rangeTotal == null ||
              end < offset ||
              rangeTotal <= end ||
              (response.contentLength >= 0 &&
                  response.contentLength != end - offset + 1) ||
              (job.track.bytes > 0 && job.track.bytes != rangeTotal)) {
            throw const HttpException('Сервер вернул неверный диапазон.');
          }
        }
        job.received = offset;
        job.total = job.track.bytes > 0
            ? job.track.bytes
            : rangeTotal ??
                  (response.contentLength > 0
                      ? offset + response.contentLength
                      : 0);
        await _reserve(
          attempt,
          target,
          partial,
          job.total > partialBytes ? job.total : partialBytes,
        );
        attempt.check();
        sink = partial.openWrite(
          mode: offset > 0 ? FileMode.append : FileMode.write,
        );
        var lastNotify = DateTime.now();
        await for (final bytes in response.timeout(
          const Duration(seconds: 90),
        )) {
          attempt.check();
          final next = job.received + bytes.length;
          if (job.total > 0 && next > job.total) {
            throw const HttpException(
              'Сервер передал больше данных, чем размер трека.',
            );
          }
          if (job.total == 0) {
            await _reserve(attempt, target, partial, next);
            attempt.check();
          }
          sink.add(bytes);
          job.received = next;
          if (DateTime.now().difference(lastNotify).inMilliseconds > 150) {
            lastNotify = DateTime.now();
            if (!_disposed) notifyListeners();
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (job.received <= 0 || (job.total > 0 && job.received != job.total)) {
          throw const HttpException(
            'Файл получен не полностью. Можно продолжить загрузку.',
          );
        }
      }
      attempt.check();
      // Finalizing a complete file is atomic with respect to pause/preemption.
      // Otherwise an interrupted metadata read could leave an orphaned file.
      await _withQuotaLock(() async {
        attempt.check();
        attempt.finishing = true;
        await partial.rename(target.path);
        _reservations[attempt]!.published = true;
      });
      final track = await library.inspect(
        target.path,
        torrent: library.byId(job.track.id) ?? job.track,
      );
      await library.upsert([track]);
      job.received = await target.length();
      job.total = job.received;
      job.state = DownloadState.complete;
    } catch (e) {
      if (!attempt.cancelled) {
        job.state = DownloadState.failed;
        job.error = e.toString();
      }
    } finally {
      try {
        await sink?.close();
      } catch (e) {
        if (!attempt.cancelled) {
          job.state = DownloadState.failed;
          job.error = e.toString();
        }
      }
      client.close(force: true);
      job.client = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<T> _withQuotaLock<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _quotaTail = _quotaTail.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  /// Each active writer reserves its whole future file. Its physical partial
  /// is excluded from the scan, so received bytes are never counted twice.
  Future<void> _reserve(
    _DownloadAttempt attempt,
    File target,
    File partial,
    int bytes,
  ) => _withQuotaLock(() async {
    attempt.check();
    final previous = _reservations[attempt];
    final candidate =
        previous ??
        _DownloadReservation(
          _restorePathKey(target.path),
          _restorePathKey(partial.path),
          bytes,
        );
    final excluded = <String>{
      candidate.partial,
      for (final reservation in _reservations.values) reservation.partial,
      for (final reservation in _reservations.values)
        if (reservation.published) reservation.target,
    };
    var used = 0;
    await for (final item in library.downloads.list(followLinks: false)) {
      if (item is File && !excluded.contains(_restorePathKey(item.path))) {
        used += await item.length();
      }
    }
    final reserved = _reservations.values.fold<int>(
      0,
      (sum, reservation) => sum + reservation.bytes,
    );
    final limit = (library.settings['cacheLimitMb'] as num?)?.toInt() ?? 4096;
    attempt.check();
    if (used + reserved - (previous?.bytes ?? 0) + bytes >
        limit * 1024 * 1024) {
      throw const FileSystemException(
        'Лимит офлайн-кеша достигнут. Увеличьте лимит в настройках или удалите скачанные треки.',
      );
    }
    candidate.bytes = bytes;
    _reservations[attempt] = candidate;
  });

  Future<void> removeOffline(Track track) {
    final pending = _removals[track.id];
    if (pending != null) return pending;
    final result = Completer<void>();
    _removals[track.id] = result.future;
    unawaited(() async {
      try {
        await _removeOffline(track);
        result.complete();
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _removals.remove(track.id);
        if (!_disposed) {
          notifyListeners();
          _pump();
        }
      }
    }());
    return result.future;
  }

  Future<void> _removeOffline(Track track) async {
    final job = _jobs[track.id];
    pause(track.id);
    await job?._completion;
    // A finishing transfer may have published new tags and cachedPath while
    // remove awaited it. Never overwrite those with the caller's old snapshot.
    final latest = library.byId(track.id) ?? track;
    // Never delete an imported file or a path outside the app-owned download directory.
    await _withQuotaLock(() async {
      if (latest.cachedPath != null &&
          p.isWithin(library.downloads.path, latest.cachedPath!)) {
        final file = File(latest.cachedPath!);
        if (await file.exists()) await file.delete();
      }
      if (latest.source == TrackSource.torrent) {
        for (final path in [_path(latest), '${_path(latest)}.part']) {
          if (!p.isWithin(library.downloads.path, path)) continue;
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
      }
    });
    _jobs.remove(track.id);
    _priority.remove(track.id);
    _pending.remove(track.id);
    await library.upsert([
      latest.copyWith(clearCache: true),
    ], preserveCache: false);
    if (!_disposed) notifyListeners();
  }

  Future<void> close() async {
    dispose();
    await Future.wait(
      _jobs.values.map((job) => job._completion).whereType<Future<void>>(),
    );
    await Future.wait(_removals.values.toList());
    await _quotaTail;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final job in _jobs.values) {
      _interrupt(job, DownloadState.paused);
    }
    super.dispose();
  }
}

class _DownloadReservation {
  _DownloadReservation(this.target, this.partial, this.bytes);
  final String target, partial;
  int bytes;
  bool published = false;
}

class _DownloadInterrupted implements Exception {
  const _DownloadInterrupted();
}

class _DownloadAttempt {
  final operation = SourceOperation();
  HttpClient? client;
  bool get cancelled => operation.cancelled;
  bool finishing = false;

  void cancel() {
    if (finishing || cancelled) return;
    operation.cancel();
    client?.close(force: true);
  }

  void check() {
    if (cancelled) throw const _DownloadInterrupted();
  }

  Future<T> wait<T>(Future<T> pending) => Future.any([
    pending,
    operation.whenCancelled.then<T>((_) => throw const _DownloadInterrupted()),
  ]);
}
