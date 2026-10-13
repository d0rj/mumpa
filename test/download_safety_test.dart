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

const _mib = 1024 * 1024;

Uint8List _wav(int size) {
  assert(size >= 44 && size.isEven);
  final bytes = Uint8List(size);
  final header = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  header.setUint32(4, size - 8, Endian.little);
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
  header.setUint32(40, size - 44, Endian.little);
  for (var offset = 44; offset < size; offset += 2) {
    header.setInt16(offset, offset % 257 - 128, Endian.little);
  }
  return bytes;
}

Track _track(String id, {int bytes = 0}) => Track(
  id: id,
  title: 'Original title',
  artist: 'Original artist',
  album: 'Original album',
  source: TrackSource.torrent,
  torrentHash: 'local-fixture-hash',
  torrentIndex: 1,
  torrentPath: '$id.wav',
  bytes: bytes,
);

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'Local download fixture did not reach its barrier.',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _untilAsync(Future<bool> Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Local partial file did not reach its boundary.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _InspectionLibrary extends LibraryRepository {
  _InspectionLibrary(super.root);
  String? blockedId;
  final entered = Completer<void>();
  final release = Completer<void>();
  int inspections = 0;

  @override
  Future<Track> inspect(
    String path, {
    String? fallbackTitle,
    Track? torrent,
  }) async {
    inspections++;
    if (torrent?.id == blockedId) {
      entered.complete();
      await release.future;
    }
    final inspected = await super.inspect(
      path,
      fallbackTitle: fallbackTitle,
      torrent: torrent,
    );
    return torrent?.id == blockedId
        ? inspected.copyWith(
            title: 'Enriched title',
            album: 'Enriched album',
            albumArtist: 'Canonical artist',
            albumSource: TrackAlbumSource.tags,
            albumArtistFromTags: true,
            lyrics: 'Original fixture lyrics',
          )
        : inspected;
  }
}

class _LocalTorrentSource extends TorrentService {
  _LocalTorrentSource(this.base) : super(endpoint: () async => base.toString());
  final Uri base;
  final resolutions = <String>[];

  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) async {
    operation?.check();
    resolutions.add(track.id);
    return base.resolve('/stream/${track.id}');
  }
}

class _ResponsePlan {
  _ResponsePlan(
    this.bytes, {
    this.contentLength,
    this.prefix,
    this.gate,
    this.statusCode = HttpStatus.ok,
    this.contentRange,
  });
  final Uint8List bytes;
  final int? contentLength, prefix;
  final Completer<void>? gate;
  final int statusCode;
  final String? contentRange;
}

class _Fixture {
  _Fixture(this.root, this.library, this.server, this.torrents, this.downloads);
  final Directory root;
  final _InspectionLibrary library;
  final HttpServer server;
  final _LocalTorrentSource torrents;
  final DownloadRepository downloads;
  final plans = <String, _ResponsePlan>{};
  final requests = <String>[];
  final ranges = <String?>[];

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'mumpa-download-safety-',
    );
    final library = _InspectionLibrary(root);
    await library.load();
    await library.setSetting('cacheLimitMb', 1);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final torrents = _LocalTorrentSource(
      Uri.parse('http://127.0.0.1:${server.port}'),
    );
    final downloads = DownloadRepository(library, torrents);
    await downloads.restore();
    final fixture = _Fixture(root, library, server, torrents, downloads);
    server.listen(fixture.serve);
    return fixture;
  }

  Future<void> serve(HttpRequest request) async {
    final id = request.uri.pathSegments.last;
    requests.add(id);
    ranges.add(request.headers.value(HttpHeaders.rangeHeader));
    try {
      final plan = plans[id]!;
      request.response.statusCode = plan.statusCode;
      request.response.headers.contentType = ContentType('audio', 'wav');
      if (plan.contentRange != null) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          plan.contentRange!,
        );
      }
      if (plan.contentLength != null) {
        request.response.contentLength = plan.contentLength!;
      }
      final prefix = plan.prefix ?? plan.bytes.length;
      request.response.add(plan.bytes.sublist(0, prefix));
      await request.response.flush();
      await plan.gate?.future;
      if (prefix < plan.bytes.length) {
        request.response.add(plan.bytes.sublist(prefix));
      }
      await request.response.close();
    } catch (_) {
      // A quota rejection or explicit removal can close this fixture socket.
    }
  }

  DownloadJob job(String id) =>
      downloads.jobs.singleWhere((job) => job.track.id == id);
  File target(String id) => File(p.join(library.downloads.path, '$id.wav'));
  File partial(String id) => File('${target(id).path}.part');

  Future<int> diskBytes() async {
    var total = 0;
    await for (final entry in library.downloads.list(followLinks: false)) {
      if (entry is File) total += await entry.length();
    }
    return total;
  }

  Future<void> close() async {
    if (!library.release.isCompleted) library.release.complete();
    for (final plan in plans.values) {
      final gate = plan.gate;
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await downloads.close();
    torrents.dispose();
    await server.close(force: true);
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  }
}

void main() {
  test(
    'cleanup during finalization preserves the completed offline file',
    () async {
      final fixture = await _Fixture.create();
      try {
        final bytes = _wav(64 * 1024);
        final track = _track('protected-finish', bytes: bytes.length);
        fixture.library.blockedId = track.id;
        fixture.plans[track.id] = _ResponsePlan(
          bytes,
          contentLength: bytes.length,
        );
        await fixture.library.upsert([track]);
        fixture.downloads.enqueue([track]);
        await fixture.library.entered.future.timeout(
          const Duration(seconds: 10),
        );
        final cleanup = fixture.downloads.removeOffline(track);
        fixture.library.release.complete();
        await cleanup.timeout(const Duration(seconds: 10));
        expect(
          fixture.library.byId(track.id)!.cachedPath,
          fixture.target(track.id).path,
        );
        expect(await fixture.target(track.id).readAsBytes(), bytes);
        expect(fixture.job(track.id).state, DownloadState.complete);
        expect(fixture.requests, [track.id]);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'stale remove waits for finalization and preserves enriched metadata',
    () async {
      final fixture = await _Fixture.create();
      try {
        final bytes = _wav(64 * 1024);
        final stale = _track('blocked', bytes: bytes.length);
        fixture.library.blockedId = stale.id;
        fixture.plans[stale.id] = _ResponsePlan(
          bytes,
          contentLength: bytes.length,
        );
        await fixture.library.upsert([stale]);
        await fixture.library.toggleLike(stale.id);
        final imported = await File(
          p.join(fixture.root.path, 'imported.wav'),
        ).writeAsBytes(bytes);
        fixture.downloads.enqueue([stale]);
        await fixture.library.entered.future.timeout(
          const Duration(seconds: 10),
        );
        expect(await fixture.target(stale.id).exists(), isTrue);
        expect(fixture.library.byId(stale.id)!.cachedPath, isNull);
        await fixture.partial(stale.id).writeAsBytes(bytes.sublist(0, 44));

        var removed = false;
        final removal = fixture.downloads
            .removeOffline(stale, userRequested: true)
            .then((_) {
              removed = true;
            });
        fixture.downloads.enqueue([stale], priority: true);
        fixture.downloads.retry(stale.id);
        await Future<void>.delayed(Duration.zero);
        expect(removed, isFalse);
        expect(fixture.library.inspections, 1);
        expect(fixture.torrents.resolutions, [stale.id]);
        expect(fixture.requests, [stale.id]);

        fixture.library.release.complete();
        await removal.timeout(const Duration(seconds: 10));
        final latest = fixture.library.byId(stale.id)!;
        expect(latest.id, stale.id);
        expect(latest.title, 'Enriched title');
        expect(latest.album, 'Enriched album');
        expect(latest.albumArtist, 'Canonical artist');
        expect(latest.albumSource, TrackAlbumSource.tags);
        expect(latest.albumArtistFromTags, isTrue);
        expect(latest.lyrics, 'Original fixture lyrics');
        expect(latest.cachedPath, isNull);
        expect(fixture.library.liked, contains(stale.id));
        expect(await fixture.target(stale.id).exists(), isFalse);
        expect(await fixture.partial(stale.id).exists(), isFalse);
        expect(await imported.readAsBytes(), bytes);
        expect(fixture.downloads.jobs, isEmpty);
        expect(fixture.requests, [stale.id]);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'unknown chunked stream respects another full-file reservation',
    () async {
      final fixture = await _Fixture.create();
      try {
        final knownBytes = _wav(768 * 1024);
        final unknownBytes = _wav(512 * 1024);
        final known = _track('known', bytes: knownBytes.length);
        final unknown = _track('unknown');
        final releaseKnown = Completer<void>();
        final releaseUnknown = Completer<void>();
        fixture.plans[known.id] = _ResponsePlan(
          knownBytes,
          contentLength: knownBytes.length,
          prefix: 64 * 1024,
          gate: releaseKnown,
        );
        fixture.plans[unknown.id] = _ResponsePlan(
          unknownBytes,
          prefix: 128 * 1024,
          gate: releaseUnknown,
        );
        await fixture.library.upsert([known, unknown]);
        fixture.downloads.enqueue([known]);
        await _until(() => fixture.job(known.id).received >= 64 * 1024);
        fixture.downloads.enqueue([unknown]);
        await _until(() => fixture.job(unknown.id).received >= 128 * 1024);
        expect(fixture.job(unknown.id).total, 0);
        expect(fixture.job(unknown.id).state, DownloadState.downloading);
        expect(await fixture.diskBytes(), lessThanOrEqualTo(_mib));
        expect(
          knownBytes.length + fixture.job(unknown.id).received,
          lessThanOrEqualTo(_mib),
        );

        releaseUnknown.complete();
        await _until(
          () => fixture.job(unknown.id).state == DownloadState.failed,
        );
        expect(fixture.job(unknown.id).error, contains('Лимит'));
        expect(fixture.library.byId(unknown.id)!.offline, isFalse);
        expect(await fixture.target(unknown.id).exists(), isFalse);
        expect(await fixture.diskBytes(), lessThanOrEqualTo(_mib));
        releaseKnown.complete();
        await _until(
          () => fixture.job(known.id).state == DownloadState.complete,
        );
        await fixture.downloads.close();
        final partialBytes = await fixture.partial(unknown.id).readAsBytes();
        expect(partialBytes.length, lessThanOrEqualTo(256 * 1024));
        expect(partialBytes, unknownBytes.sublist(0, partialBytes.length));
        expect(await fixture.target(known.id).readAsBytes(), knownBytes);
        expect(await fixture.diskBytes(), lessThanOrEqualTo(_mib));
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'unknown WAV completes but advertised overrun is rejected before write',
    () async {
      final fixture = await _Fixture.create();
      try {
        final validBytes = _wav(16 * 1024);
        final valid = _track('valid-unknown');
        final overrunBytes = _wav(96 * 1024);
        final overrun = _track('overrun', bytes: 64 * 1024);
        final releaseOverrun = Completer<void>();
        fixture.plans[valid.id] = _ResponsePlan(validBytes);
        fixture.plans[overrun.id] = _ResponsePlan(
          overrunBytes,
          prefix: overrun.bytes,
          gate: releaseOverrun,
        );
        await fixture.library.upsert([valid, overrun]);
        fixture.downloads.enqueue([valid]);
        await _until(
          () => fixture.job(valid.id).state == DownloadState.complete,
        );
        expect(fixture.job(valid.id).total, validBytes.length);
        expect(fixture.library.byId(valid.id)!.offline, isTrue);
        expect(await fixture.target(valid.id).readAsBytes(), validBytes);

        fixture.downloads.enqueue([overrun]);
        await _until(() => fixture.job(overrun.id).received == overrun.bytes);
        releaseOverrun.complete();
        await _until(
          () => fixture.job(overrun.id).state == DownloadState.failed,
        );
        await fixture.downloads.close();
        expect(fixture.job(overrun.id).error, contains('больше данных'));
        expect(fixture.job(overrun.id).received, overrun.bytes);
        expect(fixture.library.byId(overrun.id)!.offline, isFalse);
        expect(await fixture.target(overrun.id).exists(), isFalse);
        expect(await fixture.partial(overrun.id).length(), overrun.bytes);
        expect(
          await fixture.partial(overrun.id).readAsBytes(),
          overrunBytes.sublist(0, overrun.bytes),
        );
        expect(await fixture.diskBytes(), lessThanOrEqualTo(_mib));
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'unknown resume rejects an intermediate range then completes its remainder',
    () async {
      final fixture = await _Fixture.create();
      try {
        final bytes = _wav(64 * 1024);
        final track = _track('unknown-resume');
        const initial = 16 * 1024;
        const intermediate = 32 * 1024;
        await fixture.library.upsert([track]);
        await fixture.partial(track.id).writeAsBytes(bytes.sublist(0, initial));
        fixture.plans[track.id] = _ResponsePlan(
          Uint8List.sublistView(bytes, initial, intermediate),
          contentLength: intermediate - initial,
          statusCode: HttpStatus.partialContent,
          contentRange: 'bytes $initial-${intermediate - 1}/${bytes.length}',
        );
        fixture.downloads.enqueue([track]);
        await _until(() => fixture.job(track.id).state == DownloadState.failed);
        await _untilAsync(
          () async =>
              await fixture.partial(track.id).exists() &&
              await fixture.partial(track.id).length() == intermediate,
        );
        expect(fixture.job(track.id).total, bytes.length);
        expect(fixture.library.byId(track.id)!.offline, isFalse);
        expect(await fixture.target(track.id).exists(), isFalse);
        expect(
          await fixture.partial(track.id).readAsBytes(),
          bytes.sublist(0, intermediate),
        );

        fixture.plans[track.id] = _ResponsePlan(
          Uint8List.sublistView(bytes, intermediate),
          contentLength: bytes.length - intermediate,
          statusCode: HttpStatus.partialContent,
          contentRange:
              'bytes $intermediate-${bytes.length - 1}/${bytes.length}',
        );
        fixture.downloads.retry(track.id);
        await _until(
          () => fixture.job(track.id).state == DownloadState.complete,
        );
        expect(fixture.ranges, ['bytes=$initial-', 'bytes=$intermediate-']);
        expect(fixture.requests, [track.id, track.id]);
        expect(fixture.job(track.id).total, bytes.length);
        expect(fixture.library.byId(track.id)!.offline, isTrue);
        expect(await fixture.target(track.id).readAsBytes(), bytes);
        expect(await fixture.partial(track.id).exists(), isFalse);
      } finally {
        await fixture.close();
      }
    },
  );
}
