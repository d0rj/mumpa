import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:path/path.dart' as p;

const _prefixBytes = 32768;
const _ordinaryBytes = 128 * 1024;

// Original mono PCM, generated locally rather than copied from music media.
Uint8List _wav(int length, int seed) {
  assert(length >= 44 && length.isEven);
  final bytes = Uint8List(length);
  final header = ByteData.sublistView(bytes);
  void text(int start, String value) {
    bytes.setRange(start, start + value.length, value.codeUnits);
  }

  text(0, 'RIFF');
  header.setUint32(4, length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 8000, Endian.little);
  header.setUint32(28, 16000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  text(36, 'data');
  header.setUint32(40, length - 44, Endian.little);
  for (var offset = 44; offset < length; offset += 2) {
    header.setInt16(
      offset,
      ((offset * 31 + seed * 97) % 16001) - 8000,
      Endian.little,
    );
  }
  return bytes;
}

Future<void> _until(bool Function() condition, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(reason);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _Transfer {
  _Transfer(this.id, this.offset);
  final String id;
  final int offset;
  final gate = Completer<void>();
  bool prefixSent = false;
  void release() {
    if (!gate.isCompleted) gate.complete();
  }
}

class _GatedServer {
  _GatedServer(this.server, this.payloads) {
    _subscription = server.listen((request) {
      final operation = _serve(request);
      _handlers.add(operation);
      unawaited(operation.whenComplete(() => _handlers.remove(operation)));
    });
  }

  final HttpServer server;
  final Map<String, Uint8List> payloads;
  final List<_Transfer> requests = [];
  // A gated HTTP failure holds a worker while its neighbors stream normally.
  final Set<String> failOnRelease = {};
  final _closing = Completer<void>();
  final Set<Future<void>> _handlers = {};
  late final StreamSubscription<HttpRequest> _subscription;
  bool autoRelease = false;

  String get base => 'http://127.0.0.1:${server.port}';
  List<_Transfer> forId(String id) =>
      requests.where((request) => request.id == id).toList();
  bool hasPrefix(String id) => forId(id).any((request) => request.prefixSent);

  Future<void> _serve(HttpRequest request) async {
    final id = request.uri.pathSegments.single;
    final payload = payloads[id]!;
    final range = request.headers.value(HttpHeaders.rangeHeader) ?? '';
    final offset =
        int.tryParse(
          RegExp(r'^bytes=(\d+)-$').firstMatch(range)?.group(1) ?? '',
        ) ??
        0;
    final transfer = _Transfer(id, offset);
    requests.add(transfer);
    if (autoRelease) transfer.release();
    // Client cancellation is an expected part of pause, priority and close.
    unawaited(request.response.done.then<void>((_) {}, onError: (Object _) {}));
    try {
      if (failOnRelease.contains(id)) {
        await Future.any([transfer.gate.future, _closing.future]);
        if (!_closing.isCompleted) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
        }
        return;
      }
      request.response.headers.contentType = ContentType('audio', 'wav');
      request.response.contentLength = payload.length - offset;
      if (offset > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $offset-${payload.length - 1}/${payload.length}',
        );
      }
      final firstEnd = offset + _prefixBytes > payload.length
          ? payload.length
          : offset + _prefixBytes;
      request.response.add(payload.sublist(offset, firstEnd));
      await request.response.flush();
      transfer.prefixSent = true;
      await Future.any([transfer.gate.future, _closing.future]);
      if (_closing.isCompleted) return;
      request.response.add(payload.sublist(firstEnd));
      await request.response.close();
    } catch (_) {
      // The downloader forcibly closes interrupted HTTP clients.
    }
  }

  void release(String id) {
    for (final request in forId(id)) {
      request.release();
    }
  }

  void releaseAll() {
    autoRelease = true;
    for (final request in requests) {
      request.release();
    }
  }

  Future<void> close() async {
    if (!_closing.isCompleted) _closing.complete();
    await server.close(force: true);
    await _subscription.cancel();
    await Future.wait(_handlers.toList());
  }
}

class _SpyTorrents extends TorrentService {
  _SpyTorrents(this.base) : super(endpoint: () async => base);
  final String base;
  final List<String> resolves = [];
  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) async {
    resolves.add(track.id);
    return Uri.parse('$base/${track.id}');
  }
}

class _Fixture {
  _Fixture(
    this.root,
    this.library,
    this.server,
    this.torrents,
    this.downloads,
    this.tracks,
  );
  final Directory root;
  final LibraryRepository library;
  final _GatedServer server;
  final _SpyTorrents torrents;
  final DownloadRepository downloads;
  final List<Track> tracks;

  static Future<_Fixture> create({
    int? maxConcurrentDownloads,
    Map<String, int> sizes = const {
      'one': _ordinaryBytes,
      'two': _ordinaryBytes,
      'three': _ordinaryBytes,
      'four': _ordinaryBytes,
    },
    int? cacheLimitMb,
  }) async {
    final root = await Directory.systemTemp.createTemp('mumpa-parallel-');
    final library = LibraryRepository(root);
    await library.load();
    if (cacheLimitMb != null) {
      await library.setSetting('cacheLimitMb', cacheLimitMb);
    }
    final originals = await Directory(
      p.join(root.path, 'originals'),
    ).create(recursive: true);
    final payloads = <String, Uint8List>{};
    var seed = 0;
    for (final item in sizes.entries) {
      final original = File(p.join(originals.path, '${item.key}.wav'));
      await original.writeAsBytes(_wav(item.value, ++seed), flush: true);
      payloads[item.key] = await original.readAsBytes();
    }
    final tracks = sizes.entries
        .map(
          (item) => Track(
            id: item.key,
            title: item.key,
            artist: 'Original fixture artist',
            album: 'Parallel fixture album',
            source: TrackSource.torrent,
            torrentHash: 'local-fixture-hash',
            torrentIndex: sizes.keys.toList().indexOf(item.key) + 1,
            torrentPath: '${item.key}.wav',
            bytes: item.value,
          ),
        )
        .toList();
    await library.upsert(tracks);
    final server = _GatedServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      payloads,
    );
    final torrents = _SpyTorrents(server.base);
    final downloads = maxConcurrentDownloads == null
        ? DownloadRepository(library, torrents)
        : DownloadRepository(
            library,
            torrents,
            maxConcurrentDownloads: maxConcurrentDownloads,
          );
    await downloads.restore();
    final fixture = _Fixture(
      root,
      library,
      server,
      torrents,
      downloads,
      tracks,
    );
    addTearDown(fixture.close);
    return fixture;
  }

  Track track(String id) => tracks.singleWhere((track) => track.id == id);
  DownloadJob job(String id) =>
      downloads.jobs.singleWhere((job) => job.track.id == id);
  File partial(String id) =>
      File(p.join(library.downloads.path, '$id.wav.part'));

  Future<void> prefix(String id) => _until(
    () => server.hasPrefix(id) && job(id).received >= _prefixBytes,
    'The $id stream must deliver its held prefix',
  );
  Future<void> completed(String id) => _until(
    () => job(id).state == DownloadState.complete,
    'The $id stream must become a complete offline item',
  );

  Future<void> completeAll() async {
    server.releaseAll();
    await _until(
      () => downloads.jobs.every((job) => job.state == DownloadState.complete),
      'All admitted streams must finish',
    );
    for (final job in downloads.jobs) {
      final cached = library.byId(job.track.id)!.cachedPath;
      expect(cached, isNotNull);
      expect(await File(cached!).readAsBytes(), server.payloads[job.track.id]);
      expect(await partial(job.track.id).exists(), isFalse);
      expect(job.received, server.payloads[job.track.id]!.length);
    }
  }

  Future<int> cacheBytes() async {
    var total = 0;
    await for (final item in library.downloads.list(followLinks: false)) {
      if (item is File) total += await item.length();
    }
    return total;
  }

  Future<void> close() async {
    await downloads.close().timeout(const Duration(seconds: 8));
    await server.close();
    torrents.dispose();
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  }
}

void main() {
  test(
    'three held streams run together while the fourth waits; success refills',
    () async {
      final fixture = await _Fixture.create();
      expect(fixture.downloads.maxConcurrentDownloads, 3);
      fixture.downloads.enqueue(fixture.tracks);
      await Future.wait(['one', 'two', 'three'].map(fixture.prefix));

      expect(fixture.server.requests.map((request) => request.id).toSet(), {
        'one',
        'two',
        'three',
      });
      expect(
        fixture.downloads.jobs
            .where((job) => job.state == DownloadState.downloading)
            .length,
        3,
      );
      expect(fixture.job('four').state, DownloadState.queued);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fixture.server.forId('four'), isEmpty);

      fixture.server.release('one');
      await fixture.completed('one');
      await fixture.prefix('four');
      expect(fixture.job('two').state, DownloadState.downloading);
      expect(fixture.job('three').state, DownloadState.downloading);
      await fixture.completeAll();
    },
  );

  test(
    'a failed held worker releases its slot for the next queued track',
    () async {
      final fixture = await _Fixture.create();
      fixture.server.failOnRelease.add('one');
      fixture.downloads.enqueue(fixture.tracks);
      await _until(
        () => fixture.server.requests.length == 3,
        'Three requests must occupy the workers before the failure',
      );
      await Future.wait(['two', 'three'].map(fixture.prefix));
      expect(fixture.job('four').state, DownloadState.queued);

      fixture.server.release('one');
      await _until(
        () => fixture.job('one').state == DownloadState.failed,
        'HTTP 503 must fail its job',
      );
      await fixture.prefix('four');
      expect(fixture.job('one').error, contains('503'));
      expect(fixture.library.byId('one')!.offline, isFalse);
      expect(fixture.job('two').state, DownloadState.downloading);
      expect(fixture.job('three').state, DownloadState.downloading);

      fixture.server.failOnRelease.remove('one');
      fixture.downloads.retry('one');
      fixture.server.releaseAll();
      await fixture.completeAll();
      expect(fixture.server.forId('one').length, 2);
    },
  );

  test(
    'repeated enqueue does not duplicate active or queued album tracks',
    () async {
      final fixture = await _Fixture.create();
      fixture.downloads.enqueue([
        ...fixture.tracks,
        fixture.track('one'),
        fixture.track('four'),
      ]);
      await Future.wait(['one', 'two', 'three'].map(fixture.prefix));
      fixture.downloads.enqueue(fixture.tracks);
      fixture.downloads.enqueue([fixture.track('one')], priority: true);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(fixture.downloads.jobs.length, 4);
      expect(fixture.server.requests.length, 3);
      expect(fixture.job('four').state, DownloadState.queued);
      await fixture.completeAll();
      for (final track in fixture.tracks) {
        expect(
          fixture.torrents.resolves.where((id) => id == track.id).length,
          1,
        );
        expect(fixture.server.forId(track.id).length, 1);
      }
      fixture.downloads.enqueue(fixture.tracks);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fixture.server.requests.length, 4);
    },
  );

  test(
    'pause and immediate retry resumes one file without disturbing neighbors',
    () async {
      final fixture = await _Fixture.create();
      fixture.downloads.enqueue(fixture.tracks.take(3));
      await Future.wait(['one', 'two', 'three'].map(fixture.prefix));
      fixture.downloads.pause('one');
      fixture.downloads.retry('one');
      await _until(
        () => fixture.server.forId('one').length == 2,
        'The paused file must have one resumed request',
      );
      await _until(
        () => fixture.server.forId('one').last.prefixSent,
        'The resumed stream must receive its prefix',
      );

      expect(fixture.server.forId('one').last.offset, greaterThan(0));
      expect(fixture.server.forId('two').length, 1);
      expect(fixture.server.forId('three').length, 1);
      expect(fixture.job('two').state, DownloadState.downloading);
      expect(fixture.job('three').state, DownloadState.downloading);
      expect(fixture.library.byId('one')!.cachedPath, isNull);
      await fixture.completeAll();
      expect(fixture.server.forId('one').length, 2);
      expect(await fixture.cacheBytes(), 3 * _ordinaryBytes);
    },
  );

  test(
    'close cancels all active workers and never starts the queued track',
    () async {
      final fixture = await _Fixture.create();
      fixture.downloads.enqueue(fixture.tracks);
      await Future.wait(['one', 'two', 'three'].map(fixture.prefix));
      await fixture.downloads.close().timeout(const Duration(seconds: 3));

      expect(
        fixture.downloads.jobs.every(
          (job) => job.state == DownloadState.paused,
        ),
        isTrue,
      );
      expect(fixture.library.tracks.every((track) => !track.offline), isTrue);
      expect(fixture.server.forId('four'), isEmpty);
      final saved = <String, Uint8List>{};
      for (final id in ['one', 'two', 'three']) {
        saved[id] = await fixture.partial(id).readAsBytes();
        expect(saved[id], isNotEmpty);
        expect(
          saved[id],
          fixture.server.payloads[id]!.sublist(0, saved[id]!.length),
        );
      }
      fixture.server.releaseAll();
      fixture.downloads.retry('one');
      fixture.downloads.enqueue([fixture.track('four')]);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fixture.server.requests.length, 3);
      for (final entry in saved.entries) {
        expect(await fixture.partial(entry.key).readAsBytes(), entry.value);
        expect(
          await File(
            p.join(fixture.library.downloads.path, '${entry.key}.wav'),
          ).exists(),
          isFalse,
        );
      }
    },
  );

  test(
    'shared one MiB quota reserves concurrent known sizes instead of overflowing',
    () async {
      final fixture = await _Fixture.create(
        sizes: {'one': 600 * 1024, 'two': 600 * 1024},
        cacheLimitMb: 1,
      );
      fixture.downloads.enqueue(fixture.tracks);
      await _until(
        () => fixture.server.requests.isNotEmpty,
        'One 600 KiB file must be admitted',
      );
      await _until(
        () => fixture.downloads.jobs.any(
          (job) => job.state == DownloadState.failed,
        ),
        'The second full reservation must exceed the shared quota',
      );

      expect(fixture.server.requests.length, 1);
      expect(await fixture.cacheBytes(), lessThanOrEqualTo(1024 * 1024));
      fixture.server.releaseAll();
      await _until(
        () => fixture.downloads.jobs.every(
          (job) =>
              job.state == DownloadState.complete ||
              job.state == DownloadState.failed,
        ),
        'The admitted file must finish and the oversized total remain refused',
      );
      final complete = fixture.downloads.jobs.singleWhere(
        (job) => job.state == DownloadState.complete,
      );
      final failed = fixture.downloads.jobs.singleWhere(
        (job) => job.state == DownloadState.failed,
      );
      expect(failed.error, contains('Лимит'));
      expect(fixture.library.byId(failed.track.id)!.cachedPath, isNull);
      expect(
        await File(
          fixture.library.byId(complete.track.id)!.cachedPath!,
        ).readAsBytes(),
        fixture.server.payloads[complete.track.id],
      );
      expect(await fixture.cacheBytes(), 600 * 1024);
      fixture.downloads.retry(failed.track.id);
      await _until(
        () => failed.state == DownloadState.failed,
        'Retry must respect the bytes already cached by the first worker',
      );
      expect(fixture.server.requests.length, 1);
      expect(await fixture.cacheBytes(), lessThanOrEqualTo(1024 * 1024));
    },
  );

  test(
    'priority uses a free slot without interrupting the other partials',
    () async {
      final fixture = await _Fixture.create();
      fixture.downloads.enqueue(fixture.tracks.take(2));
      await Future.wait(['one', 'two'].map(fixture.prefix));
      fixture.downloads.enqueue([fixture.track('three')], priority: true);
      await fixture.prefix('three');

      expect(fixture.job('one').state, DownloadState.downloading);
      expect(fixture.job('two').state, DownloadState.downloading);
      expect(fixture.server.forId('one').length, 1);
      expect(fixture.server.forId('two').length, 1);
      expect(fixture.library.tracks.every((track) => !track.offline), isTrue);
      await fixture.completeAll();
    },
  );

  test(
    'priority yields only one occupied slot and resumes its exact partial',
    () async {
      final fixture = await _Fixture.create();
      fixture.downloads.enqueue(fixture.tracks);
      await Future.wait(['one', 'two', 'three'].map(fixture.prefix));
      fixture.downloads.enqueue([fixture.track('four')], priority: true);
      await fixture.prefix('four');

      final backgrounds = fixture.downloads.jobs
          .where((job) => job.track.id != 'four')
          .toList();
      final interrupted = backgrounds.singleWhere(
        (job) => job.state == DownloadState.queued,
      );
      expect(
        backgrounds
            .where((job) => job.state == DownloadState.downloading)
            .length,
        2,
      );
      expect(fixture.library.tracks.every((track) => !track.offline), isTrue);
      final id = interrupted.track.id;
      final partial = await fixture.partial(id).readAsBytes();
      expect(partial.length, greaterThan(0));
      expect(partial, fixture.server.payloads[id]!.sublist(0, partial.length));
      expect(fixture.server.forId(id).length, 1);

      fixture.server.release('four');
      await fixture.completed('four');
      await _until(
        () => fixture.server.forId(id).length == 2,
        'The yielded background must resume after the playing file',
      );
      expect(fixture.server.forId(id).last.offset, partial.length);
      for (final background in backgrounds.where((job) => job.track.id != id)) {
        expect(fixture.server.forId(background.track.id).length, 1);
        expect(background.state, DownloadState.downloading);
      }
      await fixture.completeAll();
    },
  );

  test(
    'changing concurrency 1 to 3 to 1 yields two writers and preserves Range bytes',
    () async {
      final fixture = await _Fixture.create(maxConcurrentDownloads: 1);
      fixture.downloads.enqueue(fixture.tracks);
      await fixture.prefix('one');
      expect(fixture.server.requests.map((request) => request.id), ['one']);

      await fixture.downloads.setMaxConcurrentDownloads(3);
      await Future.wait(['two', 'three'].map(fixture.prefix));
      expect(fixture.downloads.maxConcurrentDownloads, 3);
      expect(fixture.library.settings['downloadConcurrency'], 3);
      expect(
        fixture.downloads.jobs
            .where((job) => job.state == DownloadState.downloading)
            .length,
        3,
      );
      expect(fixture.job('four').state, DownloadState.queued);

      await fixture.downloads.setMaxConcurrentDownloads(1);
      final yielded = ['two', 'three'].map(fixture.job).toList();
      await _until(
        () => yielded.every(
          (job) => job.state == DownloadState.queued && job.client == null,
        ),
        'Both excess writers must close before their partials can resume',
      );
      expect(fixture.downloads.maxConcurrentDownloads, 1);
      expect(fixture.library.settings['downloadConcurrency'], 1);
      expect(fixture.job('one').state, DownloadState.downloading);
      expect(
        fixture.downloads.jobs
            .where((job) => job.state == DownloadState.queued)
            .map((job) => job.track.id)
            .toSet(),
        {'two', 'three', 'four'},
      );
      final partials = <String, Uint8List>{};
      for (final job in yielded) {
        final id = job.track.id;
        partials[id] = await fixture.partial(id).readAsBytes();
        expect(partials[id]!.length, _prefixBytes);
        expect(
          partials[id],
          fixture.server.payloads[id]!.sublist(0, _prefixBytes),
        );
        expect(fixture.library.byId(id)!.cachedPath, isNull);
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fixture.server.requests.length, 3);
      expect(fixture.server.forId('four'), isEmpty);

      fixture.server.release('one');
      await fixture.completed('one');
      final remaining = {'two', 'three', 'four'};
      var requestCount = 3;
      while (remaining.isNotEmpty) {
        await _until(
          () => fixture.server.requests.length == requestCount + 1,
          'The reduced queue must start exactly one next stream',
        );
        final request = fixture.server.requests.last;
        final id = request.id;
        expect(remaining.remove(id), isTrue);
        // The untouched queued track keeps its place ahead of yielded work.
        if (requestCount == 3) expect(id, 'four');
        requestCount++;
        final expectedOffset = partials[id]?.length ?? 0;
        expect(request.offset, expectedOffset);
        await _until(
          () =>
              request.prefixSent &&
              fixture.job(id).received >= expectedOffset + _prefixBytes,
          'The next stream must consume its exact original or resumed Range',
        );
        expect(
          fixture.downloads.jobs
              .where((job) => job.state == DownloadState.downloading)
              .map((job) => job.track.id),
          [id],
        );
        for (final waiting in remaining) {
          expect(fixture.job(waiting).state, DownloadState.queued);
          if (partials.containsKey(waiting)) {
            expect(
              await fixture.partial(waiting).readAsBytes(),
              partials[waiting],
            );
          }
        }
        fixture.server.release(id);
        await fixture.completed(id);
      }
      await fixture.completeAll();
      expect(fixture.server.forId('one').length, 1);
      expect(fixture.server.forId('four').length, 1);
      expect(fixture.server.forId('two').length, 2);
      expect(fixture.server.forId('three').length, 2);
      expect(await fixture.cacheBytes(), 4 * _ordinaryBytes);
    },
  );

  test(
    'one worker retains sequential queue and priority Range resume semantics',
    () async {
      final fixture = await _Fixture.create(maxConcurrentDownloads: 1);
      expect(fixture.downloads.maxConcurrentDownloads, 1);
      fixture.downloads.enqueue(fixture.tracks.take(3));
      await fixture.prefix('one');
      expect(fixture.server.requests.map((request) => request.id), ['one']);
      expect(fixture.job('two').state, DownloadState.queued);
      expect(fixture.job('three').state, DownloadState.queued);

      fixture.downloads.enqueue([fixture.track('two')], priority: true);
      await fixture.prefix('two');
      expect(fixture.job('one').state, DownloadState.queued);
      fixture.server.release('two');
      await fixture.completed('two');
      await _until(
        () => fixture.server.forId('one').length == 2,
        'The interrupted first file must resume before the last queued item',
      );
      expect(fixture.server.forId('one').last.offset, greaterThan(0));
      expect(fixture.server.forId('three'), isEmpty);
      fixture.server.release('one');
      await fixture.completed('one');
      await fixture.prefix('three');
      fixture.server.release('three');
      await fixture.completeAll();
      expect(fixture.server.requests.map((request) => request.id), [
        'one',
        'two',
        'one',
        'three',
      ]);
    },
  );
}
