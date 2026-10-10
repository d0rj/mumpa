import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../domain/models.dart';
import '../domain/torrent_album_layout.dart';
import 'media_cache.dart';
import 'source_operation.dart';
import 'torrent_metainfo.dart';
import 'torrent_service.dart';

const _maxImageBytes = 5 * 1024 * 1024;

String _normalizedPath(String path) => path.replaceAll('\\', '/');
String _parent(String path) {
  final parts = _normalizedPath(path).split('/');
  return parts.take(parts.length - 1).join('/');
}

String? _albumDirectory(String path, String folder, TorrentInfo info) {
  final directories = _parent(
    path,
  ).split('/').where((s) => s.isNotEmpty).toList();
  if (folder.isNotEmpty) {
    final leaf = folder.split('/').last;
    final index = directories.lastIndexOf(leaf);
    return index < 0 ? null : directories.take(index + 1).join('/');
  }
  final paths = info.files
      .where((f) => isAudioPath(f.path))
      .map((f) => _normalizedPath(f.path).split('/'))
      .toList();
  if (paths.isNotEmpty &&
      paths.every(
        (parts) => parts.length > 1 && parts.first == paths.first.first,
      )) {
    return paths.first.first;
  }
  return '';
}

/// Select an unambiguous small front image from this track's album directory.
/// A flat mixed collection never establishes an album-wide artwork identity.
TorrentFile? selectTorrentArtwork(TorrentInfo info, Track track) {
  if (track.source != TrackSource.torrent ||
      track.torrentPath == null ||
      track.torrentHash?.toLowerCase() != info.hash.toLowerCase()) {
    return null;
  }
  final matchingAudio = info.files
      .where(
        (file) =>
            _normalizedPath(file.path) == _normalizedPath(track.torrentPath!) &&
            isAudioPath(file.path),
      )
      .toList();
  // Saved metainfo order and TorrServer's sorted FileStats IDs can differ.
  // Artwork belongs to the exact physical path, independently of audio IDs.
  if (matchingAudio.length != 1) return null;
  final audio = matchingAudio.single;
  final layout = TorrentAlbumLayout(
    info,
    artist: track.albumArtist ?? track.artist,
  );
  final folder = layout.forPath(audio.path).folder;
  if (folder == null) return null;
  final directory = _albumDirectory(audio.path, folder, info);
  if (directory == null) return null;
  final candidates = <({TorrentFile file, int score})>[];
  final names = ['cover', 'folder', 'front'];
  final extensions = ['jpg', 'jpeg', 'png', 'webp', 'gif'];
  for (final file in info.files) {
    if (file.bytes <= 0 || file.bytes > _maxImageBytes) continue;
    final match = RegExp(
      r'^(cover|folder|front)\.(jpg|jpeg|png|webp|gif)$',
      caseSensitive: false,
    ).firstMatch(_normalizedPath(file.path).split('/').last);
    if (match == null ||
        layout.forPath(file.path).folder != folder ||
        _albumDirectory(file.path, folder, info) != directory) {
      continue;
    }
    // A cover directly in the album wins over disc/codec-specific images.
    final nested = _parent(file.path) == directory ? 0 : 1;
    candidates.add((
      file: file,
      score:
          nested * 100 +
          names.indexOf(match.group(1)!.toLowerCase()) * 10 +
          extensions.indexOf(match.group(2)!.toLowerCase()),
    ));
  }
  candidates.sort((a, b) => a.score.compareTo(b.score));
  if (candidates.isEmpty ||
      (candidates.length > 1 && candidates[0].score == candidates[1].score)) {
    return null;
  }
  return candidates.first.file;
}

Future<TorrentInfo?> _readSavedMetainfo(String path, String hash) =>
    Isolate.run(() async {
      final file = File(path);
      if (!await file.exists() || await file.length() > 16 * 1024 * 1024) {
        return null;
      }
      final info = readTorrentMetainfo(await file.readAsBytes());
      return info.hash.toLowerCase() == hash.toLowerCase() ? info : null;
    });

/// Torrent covers share the metadata cache's quota and invalidation authority.
/// Never writes artwork paths into tracks, downloads audio, or sends a hash to
/// an external artwork service. At most two independent HTTP clients are live.
class TorrentArtworkRepository {
  TorrentArtworkRepository({
    required this.torrents,
    required this.cache,
    http.Client Function()? clientFactory,
    this.requestTimeout = const Duration(seconds: 45),
  }) : clientFactory = clientFactory ?? http.Client.new;

  final TorrentService torrents;
  final DiskMediaCache cache;
  final http.Client Function() clientFactory;
  final Duration requestTimeout;
  final Map<String, TorrentInfo> _infos = {};
  final Map<String, Future<TorrentInfo?>> _reading = {};
  final Map<String, Future<String?>> _pending = {};
  final List<_ArtworkJob> _queued = [];
  final Set<_ArtworkTransfer> _active = {};
  int _running = 0, _generation = 0;
  bool _disposed = false;

  void _check(int generation, int cacheGeneration) {
    if (_disposed ||
        generation != _generation ||
        cacheGeneration != cache.generation) {
      throw const SourceCancelled();
    }
  }

  Future<TorrentInfo?> _info(String path, String hash) async {
    final known = _infos[hash];
    if (known != null) return known;
    return _reading.putIfAbsent(
      hash,
      () => _readSavedMetainfo(path, hash)
          .then((info) {
            if (info != null && !_disposed) _infos[hash] = info;
            return info;
          })
          .whenComplete(() {
            _reading.remove(hash);
          }),
    );
  }

  /// Reads an existing cover without creating a client or starting the engine.
  /// Saved metainfo supplies the same album/file identity used by [load].
  Future<String?> cachedCover(Track track) async {
    final sources = torrents.sources, hash = track.torrentHash;
    if (_disposed ||
        sources == null ||
        hash == null ||
        track.source != TrackSource.torrent) {
      return null;
    }
    final generation = _generation, cacheGeneration = cache.generation;
    try {
      final info = await _info(
        p.join(sources.path, '${stableId(hash)}.torrent'),
        hash,
      );
      _check(generation, cacheGeneration);
      if (info == null) return null;
      final cover = selectTorrentArtwork(info, track);
      if (cover == null) return null;
      final saved = await cache.pathFor(
        'torrent-cover:${info.hash}:${cover.index}',
      );
      _check(generation, cacheGeneration);
      return saved;
    } catch (_) {
      return null;
    }
  }

  Future<String?> load(Track track) async {
    final sources = torrents.sources, hash = track.torrentHash;
    if (_disposed ||
        sources == null ||
        hash == null ||
        track.source != TrackSource.torrent) {
      return null;
    }
    final generation = _generation, cacheGeneration = cache.generation;
    try {
      final metainfo = p.join(sources.path, '${stableId(hash)}.torrent');
      final info = await _info(metainfo, hash);
      _check(generation, cacheGeneration);
      if (info == null) return null;
      final cover = selectTorrentArtwork(info, track);
      if (cover == null) return null;
      final key = 'torrent-cover:${info.hash}:${cover.index}';
      final saved = await cache.pathFor(key);
      _check(generation, cacheGeneration);
      if (saved != null) return saved;
      final pendingKey = '$generation:$cacheGeneration:$key';
      return await _pending.putIfAbsent(pendingKey, () {
        final job = _ArtworkJob(
          generation,
          cacheGeneration,
          key,
          metainfo,
          info.hash,
          cover,
        );
        _queued.add(job);
        scheduleMicrotask(_drain);
        return job.result.future.whenComplete(() {
          _pending.remove(pendingKey);
        });
      });
    } catch (_) {
      // Artwork is optional. Never expose tracker URLs or engine diagnostics.
      return null;
    }
  }

  void _drain() {
    while (_running < 2 && _queued.isNotEmpty) {
      final job = _queued.removeAt(0);
      try {
        _check(job.generation, job.cacheGeneration);
      } on SourceCancelled {
        job.result.complete(null);
        continue;
      }
      _running++;
      unawaited(
        _fetch(job)
            .then(
              (path) => job.result.complete(path),
              onError: (Object _) {
                job.result.complete(null);
              },
            )
            .whenComplete(() {
              _running--;
              _drain();
            }),
      );
    }
  }

  Future<String?> _fetch(_ArtworkJob job) async {
    _check(job.generation, job.cacheGeneration);
    final transfer = _ArtworkTransfer(clientFactory());
    _active.add(transfer);
    // Closing this dedicated client also cancels multipart metadata upload.
    final deadline = Timer(requestTimeout, transfer.cancel);
    final invalidation = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_disposed ||
          job.generation != _generation ||
          job.cacheGeneration != cache.generation) {
        transfer.cancel();
      }
    });
    StreamSubscription<List<int>>? subscription;
    try {
      final local = TorrentService(
        endpoint: torrents.endpoint,
        client: transfer.client,
        metadataTimeout: requestTimeout,
      );
      TorrentInfo? loaded;
      try {
        loaded = await transfer.operation.wait(
          local.get(job.hash, operation: transfer.operation),
        );
      } on HttpException {
        transfer.operation.check();
      }
      _check(job.generation, job.cacheGeneration);
      if (loaded == null || loaded.files.isEmpty) {
        loaded = await transfer.operation.wait(
          local.upload(job.metainfo, operation: transfer.operation),
        );
      }
      _check(job.generation, job.cacheGeneration);
      final ready = loaded;
      if (ready == null || ready.hash.toLowerCase() != job.hash.toLowerCase()) {
        return null;
      }
      final matchingCovers = ready.files
          .where(
            (file) =>
                _normalizedPath(file.path) == _normalizedPath(job.cover.path) &&
                file.bytes == job.cover.bytes,
          )
          .toList();
      if (matchingCovers.length != 1 || matchingCovers.single.index <= 0) {
        return null;
      }
      // The immutable metainfo index remains the cache identity; only the
      // HTTP request uses the engine's current sorted FileStats index.
      final uri = await transfer.operation.wait(
        local.stream(job.hash, matchingCovers.single.index),
      );
      _check(job.generation, job.cacheGeneration);
      final response = await transfer.operation.wait(
        transfer.client.send(
          http.AbortableRequest(
              'GET',
              uri,
              abortTrigger: transfer.operation.whenCancelled,
            )
            ..followRedirects = false
            ..headers.addAll({
              'Accept': 'image/*',
              'Range': 'bytes=0-${job.cover.bytes - 1}',
            }),
        ),
      );
      if (response.statusCode != 200 && response.statusCode != 206) return null;
      if (response.contentLength != null &&
          (response.contentLength! > _maxImageBytes ||
              response.contentLength! != job.cover.bytes)) {
        return null;
      }
      final bytes = BytesBuilder(copy: false),
          received = Completer<Uint8List>();
      subscription = response.stream.listen(
        (chunk) {
          if (received.isCompleted) return;
          if (bytes.length + chunk.length > _maxImageBytes ||
              bytes.length + chunk.length > job.cover.bytes) {
            received.completeError(
              const FormatException('Artwork size exceeded.'),
            );
            transfer.cancel();
            return;
          }
          bytes.add(chunk);
        },
        onError: (Object error, StackTrace stack) {
          if (!received.isCompleted) received.completeError(error, stack);
        },
        onDone: () {
          if (!received.isCompleted) received.complete(bytes.takeBytes());
        },
        cancelOnError: true,
      );
      final payload = await transfer.operation.wait(received.future);
      _check(job.generation, job.cacheGeneration);
      final extension = _imageExtension(payload);
      if (payload.length != job.cover.bytes || extension == null) return null;
      final path = await cache.put(
        job.key,
        payload,
        extension: extension,
        expectedGeneration: job.cacheGeneration,
      );
      _check(job.generation, job.cacheGeneration);
      return path;
    } finally {
      deadline.cancel();
      invalidation.cancel();
      transfer.cancel();
      _active.remove(transfer);
      await subscription?.cancel();
    }
  }

  /// Call before clearing the shared cache, or when abandoning artwork work.
  void cancelPending() {
    _generation++;
    for (final job in _queued) {
      job.result.complete(null);
    }
    _queued.clear();
    for (final transfer in _active) {
      transfer.cancel();
    }
  }

  void dispose() {
    _disposed = true;
    cancelPending();
    _infos.clear();
  }
}

String? _imageExtension(Uint8List bytes) {
  bool starts(List<int> prefix) =>
      bytes.length >= prefix.length &&
      Iterable<int>.generate(prefix.length).every((i) => bytes[i] == prefix[i]);
  if (starts([0xff, 0xd8, 0xff])) return 'jpg';
  if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return 'png';
  if (starts([71, 73, 70, 56, 55, 97]) || starts([71, 73, 70, 56, 57, 97])) {
    return 'gif';
  }
  if (starts([82, 73, 70, 70]) &&
      bytes.length >= 12 &&
      bytes[8] == 87 &&
      bytes[9] == 69 &&
      bytes[10] == 66 &&
      bytes[11] == 80) {
    return 'webp';
  }
  return null;
}

class _ArtworkJob {
  _ArtworkJob(
    this.generation,
    this.cacheGeneration,
    this.key,
    this.metainfo,
    this.hash,
    this.cover,
  );
  final int generation, cacheGeneration;
  final String key, metainfo, hash;
  final TorrentFile cover;
  final result = Completer<String?>();
}

class _ArtworkTransfer {
  _ArtworkTransfer(this.client);
  final http.Client client;
  final operation = SourceOperation();
  bool _closed = false;
  void cancel() {
    operation.cancel();
    if (!_closed) {
      _closed = true;
      client.close();
    }
  }
}
