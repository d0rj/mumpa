import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/models.dart';
import 'library_repository.dart';
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
  DownloadRepository(this.library, this.torrents);
  final LibraryRepository library;
  final TorrentService torrents;
  final Map<String, DownloadJob> _jobs = {};
  final List<String> _pending = [];
  DownloadJob? _active;
  bool _running = false;
  bool _disposed = false;
  List<DownloadJob> get jobs => List.unmodifiable(_jobs.values);
  bool active(String id) => {
    DownloadState.queued,
    DownloadState.downloading,
  }.contains(_jobs[id]?.state);
  Future<void> restore() async {
    await library.downloads.create(recursive: true);
    for (final track in library.tracks.where(
      (t) => t.source == TrackSource.torrent && t.cachedPath == null,
    )) {
      final partial = File('${_path(track)}.part');
      if (await partial.exists()) {
        final job = DownloadJob(track, state: DownloadState.paused)
          ..received = await partial.length()
          ..total = track.bytes;
        _jobs[track.id] = job;
      }
    }
    notifyListeners();
  }

  String _path(Track track) {
    final ext = p.extension(track.torrentPath ?? '').toLowerCase();
    return p.join(library.downloads.path, '${track.id}$ext');
  }

  /// Prioritizing the playing track yields the active background transfer.
  /// Its partial file is closed before the next transfer starts, then resumed.
  void enqueue(Iterable<Track> tracks, {bool priority = false}) {
    if (_disposed) return;
    final selected = <String>[];
    for (final track in tracks) {
      final latest = library.byId(track.id) ?? track;
      if (latest.source != TrackSource.torrent || latest.cachedPath != null) {
        continue;
      }
      final job = _jobs.putIfAbsent(track.id, () => DownloadJob(latest));
      if (job.state == DownloadState.complete) continue;
      selected.add(track.id);
      if (identical(job, _active) && job.state == DownloadState.downloading) {
        continue;
      }
      job.cancelled = false;
      job.error = null;
      job.state = DownloadState.queued;
      if (!_pending.contains(track.id)) _pending.add(track.id);
    }
    if (priority && selected.isNotEmpty) {
      final promoted = selected.toSet().where(_pending.contains).toList();
      _pending.removeWhere(promoted.contains);
      _pending.insertAll(0, promoted);
      final current = _active;
      if (current != null &&
          !selected.contains(current.track.id) &&
          current.state == DownloadState.downloading &&
          current._attempt?.finishing != true) {
        _interrupt(current, DownloadState.queued);
        if (!_pending.contains(current.track.id)) {
          _pending.insert(promoted.length, current.track.id);
        }
      }
    }
    notifyListeners();
    unawaited(_drain());
  }

  void pause(String id) {
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
    if (_disposed || job.state == DownloadState.complete) return;
    if (job.state == DownloadState.downloading) return;
    job.cancelled = false;
    job.error = null;
    job.state = DownloadState.queued;
    if (!_pending.contains(id)) _pending.add(id);
    notifyListeners();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_running || _disposed) return;
    _running = true;
    try {
      while (!_disposed) {
        if (_pending.isEmpty) break;
        final job = _jobs[_pending.removeAt(0)];
        if (job == null || job.state != DownloadState.queued) continue;
        final completion = Completer<void>();
        job._completion = completion.future;
        _active = job;
        try {
          await _download(job);
        } finally {
          _active = null;
          job._completion = null;
          completion.complete();
        }
      }
    } finally {
      _running = false;
    }
  }

  void _interrupt(DownloadJob job, DownloadState state) {
    job.cancelled = true;
    job.state = state;
    job._attempt?.cancel();
  }

  Future<void> _download(DownloadJob job) async {
    final attempt = _DownloadAttempt();
    job._attempt = attempt;
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
      var used = 0;
      await for (final item in library.downloads.list()) {
        if (item is File) used += await item.length();
      }
      final partialBytes = await partial.exists() ? await partial.length() : 0;
      final limit = (library.settings['cacheLimitMb'] as num?)?.toInt() ?? 4096;
      if (used + job.track.bytes - partialBytes > limit * 1024 * 1024) {
        throw const FileSystemException(
          'Лимит офлайн-кеша достигнут. Увеличьте лимит в настройках или удалите скачанные треки.',
        );
      }
      attempt.check();
      final uri = await attempt.wait(torrents.resolve(job.track));
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
        if (response.statusCode == 206) {
          final range = response.headers.value(HttpHeaders.contentRangeHeader);
          if (range == null || !range.startsWith('bytes $offset-')) {
            throw const HttpException('Сервер вернул неверный диапазон.');
          }
        }
        job.received = offset;
        job.total = job.track.bytes > 0
            ? job.track.bytes
            : response.contentLength > 0
            ? offset + response.contentLength
            : 0;
        sink = partial.openWrite(
          mode: offset > 0 ? FileMode.append : FileMode.write,
        );
        var lastNotify = DateTime.now();
        await for (final bytes in response.timeout(
          const Duration(seconds: 90),
        )) {
          attempt.check();
          sink.add(bytes);
          job.received += bytes.length;
          if (DateTime.now().difference(lastNotify).inMilliseconds > 150) {
            lastNotify = DateTime.now();
            if (!_disposed) notifyListeners();
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (job.total <= 0 || job.received != job.total) {
          throw const HttpException(
            'Файл получен не полностью. Можно продолжить загрузку.',
          );
        }
      }
      attempt.check();
      // Finalizing a complete file is atomic with respect to pause/preemption.
      // Otherwise an interrupted metadata read could leave an orphaned file.
      attempt.finishing = true;
      await partial.rename(target.path);
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
      job._attempt = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> removeOffline(Track track) async {
    final job = _jobs[track.id];
    pause(track.id);
    await job?._completion;
    // Never delete an imported file or a path outside the app-owned download directory.
    if (track.cachedPath != null &&
        p.isWithin(library.downloads.path, track.cachedPath!)) {
      final file = File(track.cachedPath!);
      if (await file.exists()) await file.delete();
    }
    _jobs.remove(track.id);
    _pending.remove(track.id);
    await library.upsert([
      track.copyWith(clearCache: true),
    ], preserveCache: false);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final job in _jobs.values) {
      _interrupt(job, DownloadState.paused);
    }
    super.dispose();
  }
}

class _DownloadInterrupted implements Exception {
  const _DownloadInterrupted();
}

class _DownloadAttempt {
  final _interrupted = Completer<void>();
  HttpClient? client;
  bool cancelled = false;
  bool finishing = false;

  void cancel() {
    if (finishing || cancelled) return;
    cancelled = true;
    _interrupted.complete();
    client?.close(force: true);
  }

  void check() {
    if (cancelled) throw const _DownloadInterrupted();
  }

  Future<T> wait<T>(Future<T> operation) => Future.any([
    operation,
    _interrupted.future.then<T>((_) => throw const _DownloadInterrupted()),
  ]);
}
