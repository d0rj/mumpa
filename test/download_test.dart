import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class PendingDownloadSource extends TorrentService {
  PendingDownloadSource(this.base) : super(endpoint: () async => base);
  final String base;
  final pending = Completer<Uri>();
  @override
  Future<Uri> resolve(Track track) => track.id == 'torrent1'
      ? pending.future
      : Future.value(Uri.parse('$base/stream?index=${track.torrentIndex}'));
}

void main() {
  late Directory root;
  late LibraryRepository library;
  late TorrentService torrents;
  late DownloadRepository downloads;
  late HttpServer server;
  final bytes = List<int>.generate(256000, (i) => i % 251);
  String? range;
  bool slow = false;
  final requests = <({int index, int offset})>[];
  final payloads = <int, List<int>>{};
  const track = Track(
    id: 'torrent1',
    title: 'Song',
    artist: 'Band',
    album: 'Album',
    source: TrackSource.torrent,
    torrentHash: 'hash',
    torrentIndex: 7,
    torrentPath: 'Song.wav',
    bytes: 256000,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-download-');
    library = LibraryRepository(root);
    await library.load();
    await library.upsert([track]);
    range = null;
    slow = false;
    requests.clear();
    payloads.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        if (request.uri.path == '/torrents') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'hash': 'hash',
              'name': 'Album',
              'file_stats': [
                {'id': 7, 'path': 'Song.wav', 'length': bytes.length},
              ],
            }),
          );
        } else {
          final index =
              int.tryParse(request.uri.queryParameters['index'] ?? '') ?? 7;
          final payload = payloads[index] ?? bytes;
          range = request.headers.value(HttpHeaders.rangeHeader);
          final offset =
              int.tryParse(
                RegExp(r'bytes=(\d+)-').firstMatch(range ?? '')?.group(1) ?? '',
              ) ??
              0;
          requests.add((index: index, offset: offset));
          if (offset > 0) {
            request.response.statusCode = 206;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $offset-${payload.length - 1}/${payload.length}',
            );
          }
          request.response.contentLength = payload.length - offset;
          if (slow) {
            for (var i = offset; i < payload.length; i += 1024) {
              request.response.add(
                payload.sublist(i, (i + 1024).clamp(0, payload.length)),
              );
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 3));
            }
          } else {
            request.response.add(payload.sublist(offset));
          }
        }
        await request.response.close();
      } catch (_) {}
    });
    torrents = TorrentService(
      endpoint: () async => 'http://127.0.0.1:${server.port}',
    );
    downloads = DownloadRepository(library, torrents);
    await downloads.restore();
  });
  tearDown(() async {
    downloads.dispose();
    torrents.dispose();
    await server.close(force: true);
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  });
  test(
    'resumes partial bytes and publishes an exact complete offline file',
    () async {
      await File(
        '${library.downloads.path}/torrent1.wav.part',
      ).writeAsBytes(bytes.sublist(0, 8192));
      downloads.enqueue([track]);
      await until(() => downloads.jobs.single.state == DownloadState.complete);
      expect(range, 'bytes=8192-');
      final cached = library.byId(track.id)!.cachedPath!;
      expect(await File(cached).readAsBytes(), bytes);
      expect(await File('$cached.part').exists(), isFalse);
      await downloads.removeOffline(library.byId(track.id)!);
      expect(library.byId(track.id)!.cachedPath, isNull);
      expect(await File(cached).exists(), isFalse);
    },
  );
  test(
    'pause retains partial data, resume continues instead of restarting',
    () async {
      slow = true;
      downloads.enqueue([track]);
      await until(() => downloads.jobs.single.received > 16384);
      downloads.pause(track.id);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(downloads.jobs.single.state, DownloadState.paused);
      expect(library.byId(track.id)!.cachedPath, isNull);
      downloads.retry(track.id);
      await until(() => downloads.jobs.single.state == DownloadState.complete);
      expect(range, startsWith('bytes='));
      expect(
        await File(library.byId(track.id)!.cachedPath!).readAsBytes(),
        bytes,
      );
    },
  );
  test(
    'cache quota refuses an oversized download without claiming offline',
    () async {
      await library.setSetting('cacheLimitMb', 0);
      downloads.enqueue([track]);
      await until(() => downloads.jobs.single.state == DownloadState.failed);
      expect(downloads.jobs.single.error, contains('Лимит'));
      expect(library.byId(track.id)!.offline, isFalse);
    },
  );
  test(
    'priority promotes an already queued track and resumes background Range bytes',
    () async {
      slow = true;
      final priority = Track(
        id: 'priority',
        title: 'Playing',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.torrent,
        torrentHash: 'hash',
        torrentIndex: 8,
        torrentPath: 'Playing.wav',
        bytes: bytes.length,
      );
      final later = Track(
        id: 'later',
        title: 'Later',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.torrent,
        torrentHash: 'hash',
        torrentIndex: 9,
        torrentPath: 'Later.wav',
        bytes: bytes.length,
      );
      payloads[8] = bytes.map((b) => (b + 1) % 251).toList();
      payloads[9] = bytes.map((b) => (b + 2) % 251).toList();
      await library.upsert([priority, later]);
      downloads.enqueue([track, priority, later]);
      await until(() => downloads.jobs.first.received > 16384);
      downloads.enqueue([priority], priority: true);
      await until(
        () =>
            downloads.jobs
                .where((j) => j.track.id == priority.id)
                .single
                .state ==
            DownloadState.downloading,
      );
      downloads.enqueue([priority], priority: true);
      final partial = File('${library.downloads.path}/${track.id}.wav.part');
      expect(await partial.length(), greaterThan(0));
      expect(library.byId(track.id)!.offline, isFalse);
      await until(
        () =>
            downloads.jobs.every((job) => job.state == DownloadState.complete),
      );
      expect(requests.map((r) => r.index), [7, 8, 7, 9]);
      expect(requests[2].offset, greaterThan(0));
      for (final item in [
        (track, bytes),
        (priority, payloads[8]!),
        (later, payloads[9]!),
      ]) {
        expect(
          await File(library.byId(item.$1.id)!.cachedPath!).readAsBytes(),
          item.$2,
        );
      }
    },
  );

  test(
    'immediate pause and retry cannot fail the resumed transfer from an old attempt',
    () async {
      slow = true;
      downloads.enqueue([track]);
      await until(() => downloads.jobs.single.received > 16384);
      downloads.pause(track.id);
      downloads.retry(track.id);
      await until(() => downloads.jobs.single.state == DownloadState.complete);
      expect(requests.length, 2);
      expect(requests.last.offset, greaterThan(0));
      expect(
        await File(library.byId(track.id)!.cachedPath!).readAsBytes(),
        bytes,
      );
    },
  );

  test(
    'priority bypasses a background metadata wait and explicit pause prevents resume',
    () async {
      final pending = PendingDownloadSource('http://127.0.0.1:${server.port}');
      final controlled = DownloadRepository(library, pending);
      final priority = Track(
        id: 'priority',
        title: 'Playing',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.torrent,
        torrentHash: 'hash',
        torrentIndex: 8,
        torrentPath: 'Playing.wav',
        bytes: bytes.length,
      );
      await library.upsert([priority]);
      controlled.enqueue([track]);
      await until(
        () => controlled.jobs.single.state == DownloadState.downloading,
      );
      controlled.enqueue([priority], priority: true);
      controlled.pause(track.id);
      await until(
        () =>
            controlled.jobs
                .where((j) => j.track.id == priority.id)
                .single
                .state ==
            DownloadState.complete,
      );
      expect(controlled.jobs.first.state, DownloadState.paused);
      expect(pending.pending.isCompleted, isFalse);
      expect(requests.map((request) => request.index), [8]);
      controlled.dispose();
      pending.pending.complete(
        Uri.parse('http://127.0.0.1:${server.port}/stream?index=7'),
      );
      pending.dispose();
    },
  );
}
