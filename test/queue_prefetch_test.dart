import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/logic/queue_prefetch.dart';

import 'support.dart';

class _Source extends TorrentService {
  _Source() : super(endpoint: () async => throw StateError('No engine'));
  final calls = <String>[];
  String? base;
  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) async {
    calls.add(track.id);
    if (base != null) return Uri.parse('$base/${track.id}');
    final pending = Completer<Uri>().future;
    return operation == null ? pending : operation.wait(pending);
  }
}

Future<void> _until(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Prefetch did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Track _remote(String id, {String? path, String? cachedPath}) => Track(
  id: id,
  title: 'Song $id',
  artist: 'Band',
  album: 'Album',
  source: TrackSource.torrent,
  torrentHash: 'hash',
  torrentPath: path ?? '$id.wav',
  torrentIndex: 1,
  bytes: 4,
  cachedPath: cachedPath,
);

void main() {
  late Directory root;
  late LibraryRepository library;
  late _Source source;
  late PlaybackController player;
  late DownloadRepository downloads;
  late QueuePrefetch prefetch;
  late Track local;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-prefetch-');
    library = LibraryRepository(root);
    await library.load();
    final file = File('${root.path}/local.wav');
    await file.writeAsBytes([1, 2, 3, 4]);
    local = Track(
      id: 'local',
      title: 'Local',
      artist: 'Band',
      album: 'Album',
      source: TrackSource.local,
      localPath: file.path,
    );
    await library.upsert([local, for (var i = 0; i < 6; i++) _remote('$i')]);
    source = _Source();
    player = PlaybackController(
      library: library,
      torrents: source,
      backend: FakeAudioBackend(),
    );
    await player.initialize(platformAudio: false);
    downloads = DownloadRepository(library, source);
    await downloads.restore();
    prefetch = QueuePrefetch(
      library: library,
      playback: player,
      downloads: downloads,
    );
  });

  tearDown(() async {
    prefetch.close();
    await downloads.close();
    await player.close();
    source.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  test(
    'prepares exactly n missing files, skips actual shared copies and duplicates',
    () async {
      final shared = _remote(
        'shared',
        path: '1.wav',
        cachedPath: local.localPath,
      );
      final stale = _remote('2', cachedPath: '${root.path}/removed.wav');
      await library.upsert([shared, stale]);
      await player.playTracks([
        local,
        library.byId('0')!,
        local,
        library.byId('1')!,
        library.byId('0')!,
        stale,
        library.byId('3')!,
        library.byId('4')!,
      ]);
      await _until(() => source.calls.length == 3);
      expect(source.calls, unorderedEquals(['0', '2', '3']));
      expect(downloads.jobs.map((j) => j.track.id), ['0', '2', '3']);
      // Metadata saves/progress notifications cannot extend this fixed window.
      await library.setSetting('unrelated', 1);
      await player.backend.seek(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(source.calls.length, 3);
    },
  );

  test(
    'queue replacement pauses owned tasks, preserves manual jobs, and resumes owned tasks',
    () async {
      await prefetch.setCount(2);
      await player.playTracks([local, library.byId('0')!, library.byId('1')!]);
      await _until(() => source.calls.length == 2);
      downloads.enqueue([library.byId('0')!]); // promote to a manual transfer
      await player.playTracks([local, library.byId('2')!, library.byId('3')!]);
      await _until(() => source.calls.contains('3'));
      DownloadState state(String id) =>
          downloads.jobs.firstWhere((j) => j.track.id == id).state;
      expect(state('0'), DownloadState.downloading);
      expect(state('1'), DownloadState.paused);
      await player.pause();
      await _until(
        () =>
            state('2') == DownloadState.paused &&
            state('3') == DownloadState.paused,
      );
      expect(state('0'), DownloadState.downloading);
      final calls = source.calls.length;
      await player.play();
      await _until(() => source.calls.length == calls + 2);
      expect(state('2'), DownloadState.downloading);
      expect(state('3'), DownloadState.downloading);
      await prefetch.setCount(0);
      expect(state('2'), DownloadState.paused);
      expect(state('0'), DownloadState.downloading);
      await library.flush();
      final restored = LibraryRepository(root);
      await restored.load();
      expect(restored.settings['prefetchTracks'], 0);
      restored.dispose();
    },
  );

  test(
    'reordering and shuffle refresh the actual upcoming order; manual pause is respected',
    () async {
      await prefetch.setCount(1);
      await player.playTracks([
        local,
        library.byId('0')!,
        library.byId('1')!,
        library.byId('2')!,
      ]);
      await _until(() => source.calls.length == 1);
      await player.moveQueue(3, 1);
      await _until(() => source.calls.length == 2);
      expect(source.calls, ['0', '2']);
      downloads.pause('2');
      await library.setSetting('unrelated', true);
      expect(downloads.active('2'), isFalse);
      player.toggleShuffle();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final next = player.queue[1].id;
      if (next != '2') expect(downloads.active(next), isTrue);
      player.toggleShuffle();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(downloads.active('2'), isFalse);
    },
  );

  test(
    'completed files do not expand the window, failed downloads do not retry in a loop',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      source.base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        if (request.uri.path == '/1') {
          request.response.statusCode = 503;
        } else {
          request.response.contentLength = 4;
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      try {
        await prefetch.setCount(2);
        await player.playTracks([
          local,
          for (var i = 0; i < 6; i++) library.byId('$i')!,
        ]);
        await _until(
          () =>
              downloads.jobs.length == 2 &&
              downloads.jobs.every(
                (j) =>
                    j.state == DownloadState.complete ||
                    j.state == DownloadState.failed,
              ),
        );
        expect(source.calls, unorderedEquals(['0', '1']));
        expect(await library.localPathFor(library.byId('0')!), isNotNull);
        expect(downloads.jobs.last.state, DownloadState.failed);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(source.calls, unorderedEquals(['0', '1']));
        await player
            .next(); // already complete: no network for the current file
        await _until(() => source.calls.contains('2'));
        expect(source.calls.where((id) => id == '1').length, 1);
        expect(source.calls, unorderedEquals(['0', '1', '2']));
      } finally {
        await downloads.close();
        await server.close(force: true);
      }
    },
  );

  test('restored paused queue starts no transfers until Play', () async {
    await library.setSetting('playback', {
      'ids': ['local', '0', '1'],
      'index': 0,
    });
    await player.initialize(platformAudio: false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(source.calls, isEmpty);
    await player.play();
    await _until(() => source.calls.length == 2);
  });
}
