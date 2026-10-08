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
  double? get progress => total > 0 ? (received / total).clamp(0, 1) : null;
}

class DownloadRepository extends ChangeNotifier {
  DownloadRepository(this.library, this.torrents);
  final LibraryRepository library;
  final TorrentService torrents;
  final Map<String, DownloadJob> _jobs = {};
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

  void enqueue(Iterable<Track> tracks) {
    for (final track in tracks) {
      if (track.source != TrackSource.torrent ||
          track.cachedPath != null ||
          active(track.id)) {
        continue;
      }
      _jobs[track.id] = DownloadJob(track);
    }
    notifyListeners();
    unawaited(_drain());
  }

  void pause(String id) {
    final job = _jobs[id];
    if (job == null) return;
    job.cancelled = true;
    job.state = DownloadState.paused;
    job.client?.close(force: true);
    notifyListeners();
  }

  void retry(String id) {
    final job = _jobs[id];
    if (job == null) return;
    job.cancelled = false;
    job.error = null;
    job.state = DownloadState.queued;
    notifyListeners();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_running || _disposed) return;
    _running = true;
    try {
      while (!_disposed) {
        final job = _jobs.values
            .where((j) => j.state == DownloadState.queued)
            .firstOrNull;
        if (job == null) break;
        await _download(job);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _download(DownloadJob job) async {
    job.state = DownloadState.downloading;
    notifyListeners();
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 15);
    job.client = client;
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
      final uri = await torrents.resolve(job.track);
      var offset = await partial.exists() ? await partial.length() : 0;
      final request = await client.getUrl(uri);
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 90),
      );
      if (job.cancelled) return;
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
          if (job.cancelled) return;
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
      if (job.cancelled) return;
      await partial.rename(target.path);
      final track = await library.inspect(target.path, torrent: job.track);
      await library.upsert([track]);
      job.received = await target.length();
      job.total = job.received;
      job.state = DownloadState.complete;
    } catch (e) {
      if (!job.cancelled) {
        job.state = DownloadState.failed;
        job.error = e.toString();
      }
    } finally {
      await sink?.close();
      client.close(force: true);
      job.client = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> removeOffline(Track track) async {
    pause(track.id);
    // Never delete an imported file or a path outside the app-owned download directory.
    if (track.cachedPath != null &&
        p.isWithin(library.downloads.path, track.cachedPath!)) {
      final file = File(track.cachedPath!);
      if (await file.exists()) await file.delete();
    }
    _jobs.remove(track.id);
    await library.upsert([
      track.copyWith(clearCache: true),
    ], preserveCache: false);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final job in _jobs.values) {
      job.cancelled = true;
      job.client?.close(force: true);
    }
    super.dispose();
  }
}
