import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/radio_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/logic/playlist_radio.dart';

import 'support.dart';

class TestRadioSource implements RadioSource {
  List<Track> tracks = [];
  final prepared = <String>[];
  final unavailable = <String>{};
  Completer<void>? gate;
  int calls = 0;
  List<Track> lastSeeds = [];
  @override
  Stream<Track> candidates(
    List<Track> seeds,
    Set<String> excluded,
    SourceOperation operation,
  ) async* {
    calls++;
    lastSeeds = seeds;
    for (final track in tracks) {
      operation.check();
      if (!excluded.contains(radioSongKey(track))) yield track;
    }
  }

  @override
  Future<PreparedRadioTrack> prepare(
    Track track,
    SourceOperation operation,
  ) async {
    prepared.add(track.id);
    if (gate != null) await operation.wait(gate!.future);
    operation.check();
    if (unavailable.contains(track.id)) throw const HttpException('No peers');
    return PreparedRadioTrack(track, Uri.file(track.localPath ?? '/radio.wav'));
  }
}

class FailingRadioBackend extends FakeAudioBackend {
  final failing = <String>{};
  Completer<void>? decoderGate;
  @override
  Future<void> open(String uri, {bool play = true}) async {
    if (uri.contains('4.wav') && decoderGate != null) {
      await decoderGate!.future;
    }
    if (failing.any(uri.contains)) {
      throw const FileSystemException('Bad audio');
    }
    await super.open(uri, play: play);
  }
}

class SlowRefillSource extends TestRadioSource {
  final second = Completer<void>();
  @override
  Future<PreparedRadioTrack> prepare(
    Track track,
    SourceOperation operation,
  ) async {
    if (track.id == '5') await operation.wait(second.future);
    return super.prepare(track, operation);
  }
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Radio did not reach expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory root;
  late LibraryRepository library;
  late TorrentService torrents;
  late PlaybackController player;
  late FailingRadioBackend audio;
  late TestRadioSource source;
  late List<Track> tracks;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-radio-');
    library = LibraryRepository(root);
    await library.load();
    tracks = [];
    for (var i = 0; i < 12; i++) {
      final file = File('${root.path}/$i.wav');
      await file.writeAsBytes([1, 2, 3]);
      tracks.add(
        Track(
          id: '$i',
          title: 'Song $i',
          artist: i < 4 ? 'Seed' : 'Related',
          album: 'Album',
          source: TrackSource.local,
          localPath: file.path,
        ),
      );
    }
    await library.upsert(tracks);
    torrents = TorrentService(endpoint: () async => 'http://localhost:1');
    audio = FailingRadioBackend();
    source = TestRadioSource()..tracks = tracks.sublist(4);
    player = PlaybackController(
      library: library,
      torrents: torrents,
      backend: audio,
      radioSource: source,
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

  test('disabled by default: no discovery and queue stops normally', () async {
    await player.playTracks([tracks.first]);
    await player.next(automatic: true);
    expect(player.playing, isFalse);
    expect(source.calls, 0);
  });

  test(
    'radio counts the track without inflating the originating playlist',
    () async {
      final playlist = await library.createPlaylist('Seed playlist');
      await library.addToPlaylist(playlist.id, [tracks.first.id]);
      await player.setRadioEnabled(true);
      await player.playTracks([tracks.first], contextPlaylistId: playlist.id);
      await audio.seek(const Duration(seconds: 1));
      await until(() => player.radio.readyCount == 6);
      await player.next(automatic: true);
      final radioId = player.current!.id;
      expect(player.currentIsRadio, isTrue);
      await audio.seek(const Duration(seconds: 1));
      await library.flush();
      expect(library.trackPlayCount(radioId), 1);
      expect(library.playlistPlayCount(playlist.id), 1);
    },
  );

  test(
    'prepares before the end, continues without modifying the playlist',
    () async {
      final playlist = await library.createPlaylist('Manual');
      await library.addToPlaylist(playlist.id, ['0', '1', '2', '3']);
      await player.setRadioEnabled(true);
      await player.playTracks(
        tracks.take(4).toList(),
        contextPlaylistId: playlist.id,
      );
      expect(source.calls, 0);
      await player.next();
      await until(() => player.radio.readyCount == 6);
      expect(player.current!.id, '1');
      expect(player.queue.length, 4);
      expect(source.lastSeeds.map((t) => t.id), ['0', '1']);
      await player.next();
      await player.next();
      await player.next(automatic: true);
      expect(player.current!.id, '4');
      expect(player.playing, isTrue);
      expect(player.currentIsRadio, isTrue);
      expect(library.playlists.single.trackIds, ['0', '1', '2', '3']);
      expect(player.contextPlaylistId, playlist.id);
      await player.next(automatic: true);
      expect(player.current!.id, '5');
    },
  );

  test('unavailable swarm skipped once for all sibling candidates', () async {
    source.tracks = [
      tracks[4].copyWith(title: 'Dead 1'),
      tracks[5].copyWith(title: 'Dead 2'),
      tracks[6],
    ];
    // Give the two failing candidates the same actual torrent identity.
    source.tracks = [
      for (final track in source.tracks)
        if (track.id == '6')
          track
        else
          Track(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            source: TrackSource.torrent,
            torrentHash: 'dead',
            torrentIndex: int.parse(track.id),
          ),
    ];
    source.unavailable.add('4');
    await player.setRadioEnabled(true);
    await player.playTracks([tracks.first]);
    await until(() => !player.radio.preparing && player.radio.readyCount == 1);
    expect(source.prepared, ['4', '6']);
    await player.next(automatic: true);
    expect(player.current!.id, '6');
    expect(player.playing, isTrue);
  });

  test('decoder failure and later backend errors skip radio files', () async {
    audio.failing.add('4.wav');
    await player.setRadioEnabled(true);
    await player.playTracks([tracks.first]);
    await until(() => player.radio.readyCount == 6);
    await player.next(automatic: true);
    expect(player.current!.id, '5');
    expect(player.error, isNull);
    audio.failure.add('Decoder stream failed');
    await until(() => player.current!.id == '6' && player.playing);
    expect(player.error, isNull);
  });

  for (final action in [
    'stop',
    'pause',
    'disable',
    'queue',
    'sleep',
    'repeat',
  ]) {
    test(
      '$action cancels pending continuation and ignores late results',
      () async {
        source.gate = Completer<void>();
        await player.setRadioEnabled(true);
        await player.playTracks([tracks.first]);
        await until(() => source.prepared.isNotEmpty);
        final continuation = player.next(automatic: true);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        switch (action) {
          case 'stop':
            await player.stop();
          case 'pause':
            await player.pause();
          case 'disable':
            await player.setRadioEnabled(false);
          case 'queue':
            await player.playTracks([tracks[2], tracks[3]]);
          case 'sleep':
            player.setSleep(const Duration(milliseconds: 5));
            await Future<void>.delayed(const Duration(milliseconds: 15));
          case 'repeat':
            player.setRepeat(PlayerRepeatMode.all);
        }
        source.gate!.complete();
        await continuation;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(player.currentIsRadio, isFalse);
        expect(
          player.queue.map((t) => t.id),
          action == 'queue' ? ['2', '3'] : ['0'],
        );
        if (const ['stop', 'pause', 'sleep'].contains(action)) {
          expect(player.playing, isFalse);
        }
      },
    );
  }

  test('repeat modes have priority over radio', () async {
    await player.setRadioEnabled(true);
    player.setRepeat(PlayerRepeatMode.one);
    await player.playTracks([tracks.first]);
    await player.next(automatic: true);
    expect(source.calls, 0);
    expect(player.current!.id, '0');
    player.setRepeat(PlayerRepeatMode.all);
    await player.next(automatic: true);
    expect(source.calls, 0);
  });

  test(
    'starts the first prepared track while the remaining buffer is still loading',
    () async {
      final slow = SlowRefillSource()..tracks = tracks.sublist(4);
      player.setRadioSource(slow);
      await player.setRadioEnabled(true);
      await player.playTracks([tracks.first]);
      await until(() => player.radio.readyCount == 1);
      expect(player.radio.preparing, isTrue);
      await player.next(automatic: true);
      expect(player.current!.id, '4');
      expect(player.playing, isTrue);
      expect(player.radio.preparing, isTrue);
      slow.second.complete();
    },
  );

  for (final action in ['disable', 'pause', 'stop', 'queue']) {
    test(
      '$action during decoder open cannot start obsolete radio audio',
      () async {
        audio.decoderGate = Completer<void>();
        await player.setRadioEnabled(true);
        await player.playTracks([tracks.first]);
        await until(() => player.radio.readyCount == 6);
        final pending = player.next(automatic: true);
        await until(() => player.currentIsRadio && player.loading);
        switch (action) {
          case 'disable':
            await player.setRadioEnabled(false);
          case 'pause':
            await player.pause();
          case 'stop':
            await player.stop();
          case 'queue':
            final replacement = player.playTracks([tracks[2], tracks[3]]);
            await until(() => player.current?.id == '2' && player.loading);
            audio.decoderGate!.complete();
            await replacement;
        }
        if (!audio.decoderGate!.isCompleted) audio.decoderGate!.complete();
        await pending;
        await Future<void>.delayed(const Duration(milliseconds: 15));
        if (action == 'queue') {
          expect(player.current!.id, '2');
          expect(player.playing, isTrue);
        } else {
          expect(player.playing, isFalse);
        }
      },
    );
  }

  test(
    'deduplicates the song across releases and excludes recent plays',
    () async {
      final duplicate = tracks[4].copyWith(
        title: tracks.first.title,
        artist: 'SEED',
      );
      source.tracks = [duplicate, tracks[5], tracks[6]];
      await library.markPlayed('5');
      await player.setRadioEnabled(true);
      await player.playTracks([tracks.first]);
      await until(
        () => !player.radio.preparing && player.radio.readyCount == 1,
      );
      expect(source.prepared, ['6']);
    },
  );

  test(
    'opt-in and radio queue entries survive restart without network',
    () async {
      await player.setRadioEnabled(true);
      await player.playTracks([tracks.first]);
      await until(() => player.radio.readyCount == 6);
      await player.next(automatic: true);
      await player.close();
      await library.flush();
      final reloaded = LibraryRepository(root);
      await reloaded.load();
      final restoredSource = TestRadioSource();
      final restored = PlaybackController(
        library: reloaded,
        torrents: torrents,
        backend: FakeAudioBackend(),
        radioSource: restoredSource,
      );
      await restored.initialize(platformAudio: false);
      expect(restored.radioEnabled, isTrue);
      expect(restored.currentIsRadio, isTrue);
      expect(restoredSource.calls, 0);
      expect(restored.playing, isFalse);
      await restored.close();
      await reloaded.flush();
      reloaded.dispose();
    },
  );

  test(
    'bounded preparation timeout leaves the original selection intact',
    () async {
      final radio = PlaylistRadio(
        source: source,
        preparationTimeout: const Duration(milliseconds: 20),
      );
      source.gate = Completer<void>();
      radio.reset([tracks.first]);
      await radio.fill({radioSongKey(tracks.first)});
      expect(radio.preparing, isFalse);
      expect(radio.readyCount, 0);
      expect(radio.message, isNotNull);
      source.gate!.complete();
      await radio.close();
    },
  );
}
