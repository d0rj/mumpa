import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'support.dart';

class PendingTorrentService extends TorrentService {
  PendingTorrentService() : super(endpoint: () async => 'http://localhost');
  final ready = Completer<Uri>();
  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) =>
      ready.future;
}

class HangingAudioBackend extends FakeAudioBackend {
  final release = Completer<void>();
  bool? requestedPlay;
  int stops = 0;
  @override
  Future<void> open(String uri, {bool play = true}) async {
    requestedPlay = play;
    await release.future;
    await super.open(uri, play: play);
  }

  @override
  Future<void> stop() async {
    if (++stops > 1) await release.future;
    await super.stop();
  }
}

class SelectiveAudioBackend extends FakeAudioBackend {
  final rejected = <String>{};
  final attempts = <String>[];
  @override
  Future<void> open(String uri, {bool play = true}) async {
    attempts.add(uri);
    if (rejected.any(uri.contains)) throw StateError('Decoder rejected file');
    await super.open(uri, play: play);
  }
}

void main() {
  late Directory root;
  late LibraryRepository library;
  late TorrentService torrents;
  late PlaybackController player;
  late FakeAudioBackend audio;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-player-');
    library = LibraryRepository(root);
    await library.load();
    final tracks = <Track>[];
    for (var i = 0; i < 3; i++) {
      final file = File('${root.path}/$i.wav');
      await file.writeAsBytes([1, 2, 3]);
      tracks.add(
        Track(
          id: '$i',
          title: 'Song $i',
          artist: 'Band',
          album: 'Album',
          source: TrackSource.local,
          localPath: file.path,
        ),
      );
    }
    await library.upsert(tracks);
    torrents = TorrentService(endpoint: () async => 'http://localhost:1');
    audio = FakeAudioBackend();
    player = PlaybackController(
      library: library,
      torrents: torrents,
      backend: audio,
    );
    await player.initialize(platformAudio: false);
  });
  tearDown(() async {
    await player.close();
    await library.flush();
    library.dispose();
    torrents.dispose();
    await root.delete(recursive: true);
  });
  test(
    'restoring a paused session does not count; failed files do not count',
    () async {
      await player.playTracks([library.byId('0')!]);
      await player.pause();
      await player.saveSession();
      await player.close();
      audio = FakeAudioBackend();
      player = PlaybackController(
        library: library,
        torrents: torrents,
        backend: audio,
      );
      await player.initialize(platformAudio: false);
      expect(library.trackPlayCount('0'), 0);
      await player.play();
      await audio.seek(const Duration(seconds: 1));
      await library.flush();
      expect(library.trackPlayCount('0'), 1);
      await File(library.byId('1')!.localPath!).delete();
      await player.playTracks([library.byId('1')!, library.byId('2')!]);
      await audio.seek(const Duration(seconds: 1));
      await library.flush();
      expect(library.trackPlayCount('1'), 0);
      expect(library.trackPlayCount('2'), 1);
    },
  );

  test('queue controls shuffle without losing the current track', () async {
    await player.playTracks(library.tracks, index: 1);
    expect(player.current!.id, '1');
    expect(player.playing, isTrue);
    player.toggleShuffle();
    expect(player.current!.id, '1');
    expect(player.queue.map((t) => t.id).toSet(), {'0', '1', '2'});
    player.toggleShuffle();
    expect(player.index, 1);
    await player.next();
    expect(player.current!.id, '2');
    await player.next();
    expect(player.playing, isFalse);
    player.repeat = PlayerRepeatMode.all;
    await player.next();
    expect(player.current!.id, '0');
    player.repeat = PlayerRepeatMode.one;
    await player.next(automatic: true);
    expect(player.current!.id, '0');
  });

  test(
    'counts advancing audio once per occurrence, preserving playlist context',
    () async {
      final playlist = await library.createPlaylist('Listening');
      await library.addToPlaylist(playlist.id, ['0', '1']);
      await player.playTracks(
        library.tracks.take(2).toList(),
        contextPlaylistId: playlist.id,
      );
      expect(library.trackPlayCount('0'), 0);
      await audio.seek(const Duration(seconds: 1));
      await library.flush();
      expect(library.trackPlayCount('0'), 1);
      await player.pause();
      await player.play();
      await audio.seek(const Duration(seconds: 2));
      expect(library.trackPlayCount('0'), 1);
      await player.next();
      await audio.seek(const Duration(seconds: 1));
      await library.flush();
      expect(library.trackPlayCount('1'), 1);
      expect(library.playlistPlayCount(playlist.id), 2);
      await player.playTracks([library.byId('0')!]);
      await audio.seek(const Duration(seconds: 1));
      await library.flush();
      expect(library.trackPlayCount('0'), 2);
      expect(library.playlistPlayCount(playlist.id), 2);
    },
  );

  test(
    'missing files are skipped without changing playlist membership',
    () async {
      final tracks = List<Track>.of(library.tracks);
      final playlist = await library.createPlaylist('Skip');
      await library.addToPlaylist(
        playlist.id,
        tracks.map((t) => t.id).toList(),
      );
      await File(tracks[0].localPath!).delete();
      await File(tracks[1].localPath!).delete();
      player.setRepeat(PlayerRepeatMode.one);
      await player.playTracks(tracks, contextPlaylistId: playlist.id);
      expect(player.current!.id, '2');
      expect(player.playing, isTrue);
      expect(player.error, isNull);
      expect(player.queue.map((t) => t.id), ['0', '1', '2']);
      expect(library.playlists.single.trackIds, ['0', '1', '2']);
    },
  );

  test(
    'all failed files stop after one bounded traversal with repeat all',
    () async {
      final backend = SelectiveAudioBackend()..rejected.add('.wav');
      final controller = PlaybackController(
        library: library,
        torrents: torrents,
        backend: backend,
      );
      try {
        controller.setRepeat(PlayerRepeatMode.all);
        await controller.playTracks(library.tracks, index: 1);
        expect(backend.attempts.length, 3);
        expect(controller.stopped, isTrue);
        expect(controller.loading, isFalse);
        expect(controller.error, contains('Decoder rejected'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(backend.attempts.length, 3);
      } finally {
        await controller.close();
      }
    },
  );

  test(
    'decoder rejection and later stream error advance to the next entry',
    () async {
      final backend = SelectiveAudioBackend()..rejected.add('0.wav');
      final controller = PlaybackController(
        library: library,
        torrents: torrents,
        backend: backend,
      );
      try {
        await controller.playTracks(library.tracks);
        expect(controller.current!.id, '1');
        backend.failure.add('Stream disconnected');
        for (var i = 0; i < 100 && controller.current?.id != '2'; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(controller.current!.id, '2');
        expect(controller.playing, isTrue);
        expect(controller.error, isNull);
      } finally {
        await controller.close();
      }
    },
  );

  test('decoder startup watchdog skips to a working successor', () async {
    final backend = FakeAudioBackend();
    final controller = PlaybackController(
      library: library,
      torrents: torrents,
      backend: backend,
      decoderStartupTimeout: const Duration(milliseconds: 50),
    );
    try {
      await controller.playTracks(library.tracks);
      for (var i = 0; i < 100 && controller.current?.id != '1'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await backend.seek(const Duration(milliseconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(controller.current!.id, '1');
      expect(controller.playing, isTrue);
      expect(controller.error, isNull);
    } finally {
      await controller.close();
    }
  });

  test(
    'late decoder failures also stop repeat-all after one traversal',
    () async {
      final backend = SelectiveAudioBackend();
      final controller = PlaybackController(
        library: library,
        torrents: torrents,
        backend: backend,
        decoderStartupTimeout: const Duration(milliseconds: 25),
      );
      try {
        controller.setRepeat(PlayerRepeatMode.all);
        await controller.playTracks(library.tracks);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        // A failed decoder is stopped briefly before the next attempt opens.
        // Wait for the complete bounded traversal, not that intermediate state.
        while ((backend.attempts.length < 3 || !controller.stopped) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(backend.attempts.length, 3);
        expect(controller.stopped, isTrue);
        expect(controller.error, isNotNull);
      } finally {
        await controller.close();
      }
    },
  );

  test(
    'late stream failure or completion after Pause cannot restart the queue',
    () async {
      await player.playTracks(library.tracks);
      await player.pause();
      audio.failure.add('Late stream error');
      audio.completion.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(player.current!.id, '0');
      expect(player.playing, isFalse);
      await player.play();
      expect(player.current!.id, '0');
      expect(player.playing, isTrue);
    },
  );

  test(
    'source metadata deadline advances; Stop cancels the successor attempt',
    () async {
      final pending = PendingTorrentService();
      final controller = PlaybackController(
        library: library,
        torrents: pending,
        backend: FakeAudioBackend(),
        audioStartupTimeout: const Duration(milliseconds: 30),
      );
      final remote = Track(
        id: 'pending',
        title: 'Pending',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.torrent,
        torrentHash: 'hash',
        torrentIndex: 1,
      );
      try {
        await controller.playTracks([remote, ...library.tracks]);
        expect(controller.current!.id, '0');
        expect(controller.playing, isTrue);
        final opening = controller.playTracks([remote, ...library.tracks]);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await controller.stop();
        await opening;
        pending.ready.complete(Uri.parse('http://localhost/late'));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(controller.current!.id, 'pending');
        expect(controller.playing, isFalse);
        expect(controller.stopped, isTrue);
      } finally {
        await controller.close();
        pending.dispose();
      }
    },
  );

  test(
    'intentional pause before the first position event cancels watchdog',
    () async {
      final controller = PlaybackController(
        library: library,
        torrents: torrents,
        backend: FakeAudioBackend(),
        decoderStartupTimeout: const Duration(milliseconds: 30),
      );
      try {
        await controller.playTracks(library.tracks);
        await controller.pause();
        await Future<void>.delayed(const Duration(milliseconds: 70));
        expect(controller.error, isNull);
        expect(controller.current!.id, '0');
        expect(controller.playing, isFalse);
        expect(controller.stopped, isFalse);
      } finally {
        await controller.close();
      }
    },
  );

  test(
    'stalled native open cannot block failure UI or start obsolete audio',
    () async {
      final backend = HangingAudioBackend();
      final controller = PlaybackController(
        library: library,
        torrents: torrents,
        backend: backend,
        decoderStartupTimeout: const Duration(milliseconds: 30),
      );
      try {
        await controller
            .playTracks(library.tracks)
            .timeout(const Duration(seconds: 1));
        expect(controller.error, contains('Не удалось запустить'));
        expect(controller.loading, isFalse);
        expect(controller.buffering, isFalse);
        expect(backend.requestedPlay, isFalse);
        backend.release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(backend.playing, isFalse);
        expect(controller.playing, isFalse);
        expect(controller.error, isNotNull);
      } finally {
        if (!backend.release.isCompleted) backend.release.complete();
        await controller.close();
      }
    },
  );
  test(
    'liked torrent times out, skips to successor, and can be retried manually',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var deliver = false;
      server.listen((request) async {
        if (request.uri.path == '/torrents') {
          request.response.write(
            jsonEncode({
              'hash': 'liked-hash',
              'name': 'Liked collection',
              'active_peers': 0,
              'file_stats': [
                {'id': 7, 'path': 'liked.flac', 'length': 4096},
              ],
            }),
          );
          await request.response.close();
        } else {
          request.response.statusCode = 206;
          request.response.contentLength = 4;
          if (deliver) {
            request.response.add([1, 2, 3, 4]);
            await request.response.close();
          } else {
            await request.response.flush();
          }
        }
      });
      final source = TorrentService(
        endpoint: () async => 'http://127.0.0.1:${server.port}',
      );
      final backend = FakeAudioBackend();
      final controller = PlaybackController(
        library: library,
        torrents: source,
        backend: backend,
        audioStartupTimeout: const Duration(milliseconds: 120),
        torrentStatusInterval: const Duration(milliseconds: 20),
      );
      const track = Track(
        id: 'liked-torrent',
        title: 'Liked',
        artist: 'Band',
        album: 'Collection',
        source: TrackSource.torrent,
        torrentHash: 'liked-hash',
        torrentIndex: 7,
      );
      try {
        await library.upsert([track]);
        await library.toggleLike(track.id);
        final states = <String?>[];
        controller.addListener(() => states.add(controller.connectionStatus));
        await controller.playTracks([track, library.tracks.first]);
        expect(controller.error, isNull);
        expect(controller.loading, isFalse);
        expect(controller.buffering, isFalse);
        expect(controller.connectionStatus, isNull);
        expect(controller.current!.id, library.tracks.first.id);
        expect(controller.playing, isTrue);
        expect(states.whereType<String>(), contains(contains('подключено: 0')));
        deliver = true;
        await controller.jump(0);
        expect(controller.error, isNull);
        expect(controller.current!.id, track.id);
        expect(controller.queue.length, 2);
        expect(controller.playing, isTrue);
        expect(controller.connectionStatus, isNull);
        expect(Uri.parse(backend.opened!).queryParameters['index'], '7');
      } finally {
        await controller.close();
        source.dispose();
        await server.close(force: true);
      }
    },
  );
  test(
    'system stop publishes idle and the selected queue can resume',
    () async {
      final system = SystemAudioHandler(player);
      player.system = system;
      await player.playTracks(library.tracks);
      expect(
        system.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
      await system.stop();
      expect(player.playing, isFalse);
      expect(
        system.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      await system.play();
      expect(player.playing, isTrue);
      expect(
        system.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
      player.system = null;
    },
  );
  test('pause cancels a pending source without starting it later', () async {
    final pending = PendingTorrentService();
    final backend = FakeAudioBackend();
    final controller = PlaybackController(
      library: library,
      torrents: pending,
      backend: backend,
    );
    await controller.initialize(platformAudio: false);
    final opening = controller.playTracks([
      const Track(
        id: 'pending',
        title: 'Pending',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.torrent,
        torrentHash: 'hash',
        torrentIndex: 1,
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.loading, isTrue);
    await controller.toggle();
    expect(controller.loading, isFalse);
    pending.ready.complete(Uri.parse('http://localhost/stream'));
    await opening;
    expect(backend.opened, isNull);
    expect(controller.playing, isFalse);
    await controller.close();
    pending.dispose();
  });
  test(
    'offline torrent chooses cached file and never contacts the engine',
    () async {
      final local = library.tracks.first.localPath!;
      final track = Track(
        id: 'offline',
        title: 'Cached',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.torrent,
        cachedPath: local,
        torrentHash: 'none',
        torrentIndex: 1,
      );
      expect(await player.resolve(track), Uri.file(local).toString());
    },
  );
  test('restores session paused, then seeks when the user plays', () async {
    await player.playTracks(library.tracks, index: 2);
    await player.seek(const Duration(seconds: 7));
    await player.pause();
    final fresh = PlaybackController(
      library: library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    await fresh.initialize(platformAudio: false);
    expect(fresh.current!.id, '2');
    expect(fresh.playing, isFalse);
    await fresh.play();
    expect(fresh.position.inSeconds, 7);
    await fresh.close();
  });
  test('removing current queue item selects a valid successor', () async {
    await player.playTracks(library.tracks, index: 1);
    await player.removeQueue(1);
    expect(player.current!.id, '2');
    expect(player.queue.length, 2);
    await player.removeQueue(1);
    expect(player.current!.id, '0');
    await player.removeQueue(0);
    expect(player.current, isNull);
    expect(player.playing, isFalse);
  });

  test(
    'a newly selected collection clears the restored track position and origin',
    () async {
      await player.playTracks(
        library.tracks,
        index: 2,
        contextPlaylistId: 'old-playlist',
      );
      await player.seek(const Duration(seconds: 7));
      await player.pause();
      final fresh = PlaybackController(
        library: library,
        torrents: torrents,
        backend: FakeAudioBackend(),
      );
      await fresh.initialize(platformAudio: false);
      expect(fresh.position.inSeconds, 7);
      expect(fresh.contextPlaylistId, 'old-playlist');
      await fresh.playTracks(library.tracks, index: 0);
      expect(fresh.current!.id, '0');
      expect(fresh.position, Duration.zero);
      expect(fresh.contextPlaylistId, isNull);
      await fresh.close();
    },
  );

  test(
    'pending source exposes new metadata and ignores completion from the old decoder',
    () async {
      final pending = PendingTorrentService();
      final backend = FakeAudioBackend();
      final controlled = PlaybackController(
        library: library,
        torrents: pending,
        backend: backend,
      );
      await controlled.initialize(platformAudio: false);
      await controlled.playTracks(library.tracks);
      await controlled.seek(const Duration(seconds: 12));
      const track = Track(
        id: 'pending',
        title: 'Pending',
        artist: 'Band',
        album: 'New collection',
        source: TrackSource.torrent,
        torrentHash: 'hash',
        torrentIndex: 1,
        durationMs: 180000,
      );
      final opening = controlled.playTracks([
        track,
        library.tracks.last,
      ], contextPlaylistId: 'collection');
      await Future<void>.delayed(Duration.zero);
      expect(controlled.position, Duration.zero);
      expect(controlled.duration, const Duration(minutes: 3));
      expect(controlled.playing, isFalse);
      backend.completion.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(controlled.current!.id, 'pending');
      await controlled.playTracks(
        library.tracks,
        index: 1,
        contextPlaylistId: 'newer',
      );
      pending.ready.complete(Uri.parse('http://localhost/obsolete-stream'));
      await opening;
      expect(controlled.current!.id, '1');
      expect(backend.opened, Uri.file(library.tracks[1].localPath!).toString());
      expect(controlled.contextPlaylistId, 'newer');
      expect(controlled.position, Duration.zero);
      await controlled.close();
      pending.dispose();
    },
  );

  test(
    'session restores shuffled queue edits and playlist origin without resurrecting removed entries',
    () async {
      await player.playTracks(
        library.tracks,
        index: 1,
        contextPlaylistId: 'playlist',
      );
      player.toggleShuffle();
      await player.removeQueue(player.queue.indexWhere((t) => t.id == '0'));
      player.enqueue(library.byId('0')!);
      await player.seek(const Duration(seconds: 7));
      await player.pause();
      final queueIds = player.queue.map((track) => track.id).toList();
      final fresh = PlaybackController(
        library: library,
        torrents: torrents,
        backend: FakeAudioBackend(),
      );
      await fresh.initialize(platformAudio: false);
      expect(fresh.queue.map((t) => t.id), queueIds);
      expect(fresh.current!.id, '1');
      expect(fresh.shuffle, isTrue);
      expect(fresh.contextPlaylistId, 'playlist');
      await fresh.play();
      expect(fresh.position.inSeconds, 7);
      fresh.toggleShuffle();
      expect(fresh.queue.map((t) => t.id), ['1', '2', '0']);
      expect(fresh.current!.id, '1');
      await fresh.close();
    },
  );

  test(
    'restore preserves the selected track when an earlier library entry was removed',
    () async {
      await player.playTracks(library.tracks, index: 2);
      await player.seek(const Duration(seconds: 7));
      await player.pause();
      await library.removeTracks(['0']);
      final fresh = PlaybackController(
        library: library,
        torrents: torrents,
        backend: FakeAudioBackend(),
      );
      await fresh.initialize(platformAudio: false);
      expect(fresh.queue.map((t) => t.id), ['1', '2']);
      expect(fresh.current!.id, '2');
      await fresh.play();
      expect(fresh.position.inSeconds, 7);
      await fresh.close();
    },
  );

  test(
    'tracks added to an empty queue can play and stop resumes their position',
    () async {
      player.enqueue(library.tracks.first);
      await player.play();
      expect(player.playing, isTrue);
      await player.seek(const Duration(seconds: 7));
      await player.stop();
      expect(player.playing, isFalse);
      await player.play();
      expect(player.position.inSeconds, 7);
    },
  );
}
