import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'support.dart';

class PendingTorrentService extends TorrentService {
  PendingTorrentService() : super(endpoint: () async => 'http://localhost');
  final ready = Completer<Uri>();
  @override
  Future<Uri> resolve(Track track) => ready.future;
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
}
