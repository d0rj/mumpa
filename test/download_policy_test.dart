import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_conditions.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/domain/models.dart';

class _Source extends TorrentService {
  _Source(this.uri) : super(endpoint: () async => uri.toString());
  final Uri uri;
  int calls = 0;
  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) async {
    calls++;
    return uri;
  }
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Download did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Track _track(String id, {String? cached, int bytes = 0}) => Track(
  id: id,
  title: id,
  artist: 'Band',
  album: id,
  source: TrackSource.torrent,
  torrentHash: 'fixture',
  torrentPath: '$id.wav',
  torrentIndex: 1,
  cachedPath: cached,
  bytes: bytes,
);

void main() {
  test(
    'playing a queued manual download never converts it into evictable automatic cache',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mumpa-download-ownership-',
      );
      final library = LibraryRepository(root);
      await library.load();
      await library.setSetting('downloadsWifiOnly', true);
      final source = _Source(Uri.parse('http://127.0.0.1:1/audio'));
      final downloads = DownloadRepository(
        library,
        source,
        conditionReader: () async =>
            const DownloadConditions(wifi: false, charging: false),
      );
      try {
        final manual = _track('manual'), automatic = _track('automatic');
        await library.upsert([manual, automatic]);
        downloads.enqueue([manual]);
        downloads.enqueue([manual], priority: true, automatic: true);
        expect(library.features.automatic, isNot(contains('manual')));
        downloads.enqueue([automatic], automatic: true);
        expect(library.features.automatic, contains('automatic'));
        downloads.enqueue([automatic]);
        expect(library.features.automatic, isNot(contains('automatic')));
        expect(source.calls, 0);
      } finally {
        await downloads.close();
        source.dispose();
        await library.flush();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'Wi-Fi and charging restrictions hold queued downloads and resume them',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-policy-');
      final library = LibraryRepository(root);
      await library.load();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.contentLength = 3;
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      final source = _Source(
        Uri.parse('http://127.0.0.1:${server.port}/audio'),
      );
      var state = const DownloadConditions(wifi: false, charging: true);
      await library.setSetting('downloadsWifiOnly', true);
      await library.setSetting('downloadsChargingOnly', true);
      final downloads = DownloadRepository(
        library,
        source,
        conditionReader: () async => state,
      );
      try {
        final track = _track('a', bytes: 3);
        await library.upsert([track]);
        await downloads.refreshConditions();
        downloads.enqueue([track]);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(source.calls, 0);
        expect(downloads.waitingForConditions, isTrue);
        state = const DownloadConditions(wifi: true, charging: false);
        await downloads.refreshConditions();
        expect(source.calls, 0);
        state = const DownloadConditions(wifi: true, charging: true);
        await downloads.refreshConditions();
        await _until(
          () => downloads.jobs.any((j) => j.state == DownloadState.complete),
        );
        expect(source.calls, 1);
        expect(library.byId('a')!.cachedPath, isNotNull);
      } finally {
        await downloads.close();
        source.dispose();
        await server.close(force: true);
        await library.flush();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'quota eviction removes only automatic unprotected files and retains pinned/manual copies',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-eviction-');
      final library = LibraryRepository(root);
      await library.load();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = List<int>.filled(700000, 0);
      server.listen((request) async {
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final source = _Source(
        Uri.parse('http://127.0.0.1:${server.port}/audio'),
      );
      final downloads = DownloadRepository(library, source);
      try {
        await library.downloads.create(recursive: true);
        final automatic = File('${library.downloads.path}/automatic.wav');
        await automatic.writeAsBytes(List.filled(300000, 1));
        final pinned = File('${library.downloads.path}/pinned.wav');
        await pinned.writeAsBytes(List.filled(100000, 2));
        final manual = File('${library.downloads.path}/manual.wav');
        await manual.writeAsBytes(List.filled(100000, 3));
        final next = _track('next', bytes: bytes.length);
        await library.upsert([
          _track('automatic', cached: automatic.path),
          _track('pinned', cached: pinned.path),
          _track('manual', cached: manual.path),
          next,
        ]);
        library.features.automatic.addAll(['automatic', 'pinned']);
        await library.setPinned(['pinned'], true);
        await library.setSetting('cacheLimitMb', 1);
        await library.setSetting('evictAutomaticCache', true);
        downloads.enqueue([next]);
        await _until(
          () => downloads.jobs.any(
            (j) =>
                j.track.id == 'next' &&
                [
                  DownloadState.complete,
                  DownloadState.failed,
                ].contains(j.state),
          ),
        );
        expect(
          downloads.jobs.firstWhere((j) => j.track.id == 'next').error,
          isNull,
        );
        expect(await automatic.exists(), isFalse);
        expect(await pinned.exists(), isTrue);
        expect(await manual.exists(), isTrue);
        expect(library.byId('automatic')!.cachedPath, isNull);
      } finally {
        await downloads.close();
        source.dispose();
        await server.close(force: true);
        await library.flush();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
