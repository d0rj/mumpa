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

void main() {
  late Directory root;
  late LibraryRepository library;
  late TorrentService torrents;
  late DownloadRepository downloads;
  late HttpServer server;
  final bytes = List<int>.generate(256000, (i) => i % 251);
  String? range;
  bool slow = false;
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
          range = request.headers.value(HttpHeaders.rangeHeader);
          final offset =
              int.tryParse(
                RegExp(r'bytes=(\d+)-').firstMatch(range ?? '')?.group(1) ?? '',
              ) ??
              0;
          if (offset > 0) {
            request.response.statusCode = 206;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $offset-${bytes.length - 1}/${bytes.length}',
            );
          }
          request.response.contentLength = bytes.length - offset;
          if (slow) {
            for (var i = offset; i < bytes.length; i += 1024) {
              request.response.add(
                bytes.sublist(i, (i + 1024).clamp(0, bytes.length)),
              );
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 3));
            }
          } else {
            request.response.add(bytes.sublist(offset));
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
}
