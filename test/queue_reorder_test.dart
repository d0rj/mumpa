import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:path/path.dart' as p;

import 'support.dart';

class _CountingAudio extends FakeAudioBackend {
  final openedUris = <String>[];
  int stops = 0, plays = 0, pauses = 0, seeks = 0;
  Completer<void>? openGate;

  ({int opens, int stops, int plays, int pauses, int seeks}) get calls => (
    opens: openedUris.length,
    stops: stops,
    plays: plays,
    pauses: pauses,
    seeks: seeks,
  );

  @override
  Future<void> open(
    String uri, {
    bool play = true,
    Duration start = Duration.zero,
  }) async {
    openedUris.add(uri);
    final gate = openGate;
    if (gate != null) await gate.future;
    await super.open(uri, play: play, start: start);
  }

  @override
  Future<void> stop() async {
    stops++;
    await super.stop();
  }

  @override
  Future<void> play() async {
    plays++;
    await super.play();
  }

  @override
  Future<void> pause() async {
    pauses++;
    await super.pause();
  }

  @override
  Future<void> seek(Duration value) async {
    seeks++;
    await super.seek(value);
  }
}

class _NoNetworkTorrents extends TorrentService {
  _NoNetworkTorrents()
    : super(endpoint: () async => throw StateError('Local fixture only'));
  int resolves = 0;

  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) async {
    resolves++;
    throw StateError('Queue edits must not contact torrent sources');
  }
}

Uint8List _originalWav() {
  final bytes = Uint8List(44 + 16000);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) {
    bytes.setRange(offset, offset + value.length, value.codeUnits);
  }

  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, 16000, Endian.little);
  return bytes;
}

Future<void> _until(bool Function() condition, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException(reason);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _Fixture {
  _Fixture(
    this.root,
    this.library,
    this.torrents,
    this.audio,
    this.player,
    this.tracks,
    this.playlist,
  );
  final Directory root;
  LibraryRepository library;
  final _NoNetworkTorrents torrents;
  _CountingAudio audio;
  PlaybackController player;
  final List<Track> tracks;
  final MusicPlaylist playlist;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('mumpa-queue-reorder-');
    final library = LibraryRepository(root);
    await library.load();
    final wav = _originalWav();
    final tracks = <Track>[];
    for (final id in ['a', 'b', 'c', 'd']) {
      final file = File(p.join(root.path, '$id.wav'));
      await file.writeAsBytes(wav, flush: true);
      tracks.add(
        Track(
          id: id,
          title: 'Original fixture $id',
          artist: 'Fixture artist',
          album: 'Fixture album',
          source: TrackSource.local,
          localPath: file.path,
          durationMs: 24000,
        ),
      );
    }
    await library.upsert(tracks);
    final playlist = await library.createPlaylist('Original fixture playlist');
    await library.addToPlaylist(playlist.id, tracks.map((track) => track.id));
    final torrents = _NoNetworkTorrents();
    final audio = _CountingAudio();
    final player = PlaybackController(
      library: library,
      torrents: torrents,
      backend: audio,
    );
    await player.initialize(platformAudio: false);
    final fixture = _Fixture(
      root,
      library,
      torrents,
      audio,
      player,
      tracks,
      playlist,
    );
    addTearDown(fixture.close);
    return fixture;
  }

  List<String> get ids => player.queue.map((track) => track.id).toList();
  Track track(String id) => tracks.singleWhere((track) => track.id == id);
  Future<void> start({int index = 1}) =>
      player.playTracks(tracks, index: index, contextPlaylistId: playlist.id);

  Future<void> restart() async {
    await player.close();
    await library.flush();
    library.dispose();
    library = LibraryRepository(root);
    await library.load();
    audio = _CountingAudio();
    player = PlaybackController(
      library: library,
      torrents: torrents,
      backend: audio,
    );
    await player.initialize(platformAudio: false);
  }

  Future<void> close() async {
    final gate = audio.openGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    await player.close();
    await library.flush();
    library.dispose();
    torrents.dispose();
    await root.delete(recursive: true);
    expect(torrents.resolves, 0);
  }
}

void main() {
  test(
    'moving an entry across current in either direction preserves audio',
    () async {
      final fixture = await _Fixture.create();
      await fixture.start(index: 2);
      await fixture.player.seek(const Duration(seconds: 7));
      final calls = fixture.audio.calls;
      final uri = fixture.audio.opened;

      await fixture.player.moveQueue(0, 3);
      expect(fixture.ids, ['b', 'c', 'd', 'a']);
      expect(fixture.player.index, 1);
      expect(fixture.player.current!.id, 'c');
      await fixture.player.moveQueue(3, 0);
      expect(fixture.ids, ['a', 'b', 'c', 'd']);
      expect(fixture.player.index, 2);
      expect(fixture.player.current!.id, 'c');
      expect(fixture.player.position, const Duration(seconds: 7));
      expect(fixture.player.playing, isTrue);
      expect(fixture.audio.opened, uri);
      expect(fixture.audio.calls, calls);
    },
  );

  test(
    'moving current uses the final destination index and never reopens it',
    () async {
      final fixture = await _Fixture.create();
      await fixture.start();
      await fixture.player.seek(const Duration(seconds: 9));
      final calls = fixture.audio.calls;

      await fixture.player.moveQueue(1, 3);
      expect(fixture.ids, ['a', 'c', 'd', 'b']);
      expect(fixture.player.index, 3);
      await fixture.player.moveQueue(3, 0);
      expect(fixture.ids, ['b', 'a', 'c', 'd']);
      expect(fixture.player.index, 0);
      expect(fixture.player.current!.id, 'b');
      expect(fixture.player.position, const Duration(seconds: 9));
      expect(fixture.player.playing, isTrue);
      expect(fixture.audio.calls, calls);
    },
  );

  test(
    'duplicate tracks retain the selected occurrence through moves and restart',
    () async {
      final fixture = await _Fixture.create();
      await fixture.player.playTracks(
        [
          fixture.track('a'),
          fixture.track('b'),
          fixture.track('a'),
          fixture.track('c'),
        ],
        index: 2,
        contextPlaylistId: fixture.playlist.id,
      );
      await fixture.player.seek(const Duration(seconds: 9));
      final calls = fixture.audio.calls;

      // Move the first A past the selected second A, then move that selected A.
      await fixture.player.moveQueue(0, 3);
      expect(fixture.ids, ['b', 'a', 'c', 'a']);
      expect(fixture.player.index, 1);
      await fixture.player.moveQueue(1, 3);
      expect(fixture.ids, ['b', 'c', 'a', 'a']);
      expect(fixture.player.index, 3);
      expect(fixture.player.position, const Duration(seconds: 9));
      expect(fixture.audio.calls, calls);

      await fixture.restart();
      expect(fixture.ids, ['b', 'c', 'a', 'a']);
      expect(fixture.player.index, 3);
      expect(fixture.player.current!.id, 'a');
      expect(fixture.player.position, const Duration(seconds: 9));
      expect(fixture.player.contextPlaylistId, fixture.playlist.id);
      expect(fixture.audio.openedUris, isEmpty);
      await fixture.player.play();
      await fixture.player.seek(Duration.zero);
      await fixture.player.previous();
      expect(fixture.player.index, 2);
      expect(fixture.player.current!.id, 'a');
      await fixture.player.next();
      expect(fixture.player.index, 3);
      expect(fixture.player.current!.id, 'a');
    },
  );

  test(
    'next and previous follow the edited queue rather than its old order',
    () async {
      final fixture = await _Fixture.create();
      await fixture.start();
      await fixture.player.seek(const Duration(seconds: 2));
      final calls = fixture.audio.calls;
      await fixture.player.moveQueue(3, 0);
      expect(fixture.ids, ['d', 'a', 'b', 'c']);
      expect(fixture.player.index, 2);
      expect(fixture.audio.calls, calls);

      await fixture.player.next();
      expect(fixture.player.current!.id, 'c');
      expect(fixture.player.index, 3);
      await fixture.player.previous();
      expect(fixture.player.current!.id, 'b');
      expect(fixture.player.index, 2);
      await fixture.player.previous();
      expect(fixture.player.current!.id, 'a');
      expect(fixture.player.index, 1);
      expect(
        fixture.audio.openedUris.last,
        Uri.file(fixture.track('a').localPath!).toString(),
      );
    },
  );

  test(
    'moving while paused preserves the decoder and resumes the same position',
    () async {
      final fixture = await _Fixture.create();
      await fixture.start();
      await fixture.player.seek(const Duration(seconds: 11));
      await fixture.player.pause();
      final calls = fixture.audio.calls;
      final uri = fixture.audio.opened;

      await fixture.player.moveQueue(1, 3);
      await fixture.player.moveQueue(0, 2);
      expect(fixture.ids, ['c', 'd', 'a', 'b']);
      expect(fixture.player.index, 3);
      expect(fixture.player.current!.id, 'b');
      expect(fixture.player.position, const Duration(seconds: 11));
      expect(fixture.player.playing, isFalse);
      expect(fixture.player.stopped, isFalse);
      expect(fixture.audio.opened, uri);
      expect(fixture.audio.calls, calls);
      await fixture.player.play();
      expect(fixture.player.playing, isTrue);
      expect(fixture.player.position, const Duration(seconds: 11));
      expect(fixture.audio.calls.opens, calls.opens);
      expect(fixture.audio.calls.stops, calls.stops);
      expect(fixture.audio.calls.seeks, calls.seeks);
      expect(fixture.audio.calls.plays, calls.plays + 1);
    },
  );

  test(
    'invalid and same-index moves are no-ops including an empty queue',
    () async {
      final fixture = await _Fixture.create();
      await fixture.player.moveQueue(0, 0);
      await fixture.player.moveQueue(0, 1);
      expect(fixture.player.queue, isEmpty);
      expect(fixture.player.current, isNull);
      expect(fixture.audio.openedUris, isEmpty);
      await fixture.start();
      await fixture.player.seek(const Duration(seconds: 4));
      final calls = fixture.audio.calls;
      var playerNotifications = 0;
      var libraryNotifications = 0;
      void changedPlayer() => playerNotifications++;
      void changedLibrary() => libraryNotifications++;
      fixture.player.addListener(changedPlayer);
      fixture.library.addListener(changedLibrary);

      for (final move in [(-1, 0), (0, -1), (4, 0), (0, 4), (1, 1), (99, 99)]) {
        await fixture.player.moveQueue(move.$1, move.$2);
      }
      expect(fixture.ids, ['a', 'b', 'c', 'd']);
      expect(fixture.player.index, 1);
      expect(fixture.player.position, const Duration(seconds: 4));
      expect(fixture.player.playing, isTrue);
      expect(fixture.audio.calls, calls);
      expect(playerNotifications, 0);
      expect(libraryNotifications, 0);
      fixture.player.removeListener(changedPlayer);
      fixture.library.removeListener(changedLibrary);
    },
  );

  test(
    'manual order becomes the persisted shuffle base and preserves playlist origin',
    () async {
      final fixture = await _Fixture.create();
      await fixture.start();
      await fixture.player.seek(const Duration(seconds: 7));
      final calls = fixture.audio.calls;
      await fixture.player.moveQueue(0, 3);
      await fixture.player.moveQueue(2, 1);
      await fixture.player.moveQueue(0, 2);
      const manual = ['d', 'c', 'b', 'a'];
      expect(fixture.ids, manual);
      expect(fixture.player.index, 2);
      fixture.player.toggleShuffle();
      expect(fixture.player.shuffle, isTrue);
      expect(fixture.player.current!.id, 'b');
      fixture.player.toggleShuffle();
      expect(fixture.player.shuffle, isFalse);
      expect(fixture.ids, manual);
      expect(fixture.player.index, 2);
      expect(fixture.player.position, const Duration(seconds: 7));
      expect(fixture.audio.calls, calls);

      await fixture.restart();
      expect(fixture.ids, manual);
      expect(fixture.player.index, 2);
      expect(fixture.player.contextPlaylistId, fixture.playlist.id);
      expect(fixture.player.shuffle, isFalse);
      expect(fixture.player.position, const Duration(seconds: 7));
      expect(fixture.player.playing, isFalse);
      expect(fixture.audio.openedUris, isEmpty);
      expect(fixture.library.playlists.single.trackIds, ['a', 'b', 'c', 'd']);
      await fixture.player.play();
      expect(fixture.player.position, const Duration(seconds: 7));
      final restoredCalls = fixture.audio.calls;
      fixture.player.toggleShuffle();
      fixture.player.toggleShuffle();
      expect(fixture.ids, manual);
      expect(fixture.player.index, 2);
      expect(fixture.player.playing, isTrue);
      expect(fixture.audio.calls, restoredCalls);
    },
  );

  test(
    'moves while shuffled preserve the flag and exact active order after restart',
    () async {
      final fixture = await _Fixture.create();
      await fixture.start(index: 2);
      await fixture.player.seek(const Duration(seconds: 5));
      fixture.player.toggleShuffle();
      final expected = List<String>.of(fixture.ids);
      expect(expected.first, 'c');
      final calls = fixture.audio.calls;

      expected.insert(0, expected.removeAt(3));
      await fixture.player.moveQueue(3, 0);
      expect(fixture.ids, expected);
      expect(fixture.player.index, 1);
      expected.insert(3, expected.removeAt(1));
      await fixture.player.moveQueue(1, 3);
      expect(fixture.ids, expected);
      expect(fixture.player.index, 3);
      expect(fixture.player.current!.id, 'c');
      expect(fixture.player.shuffle, isTrue);
      expect(fixture.player.position, const Duration(seconds: 5));
      expect(fixture.audio.calls, calls);

      await fixture.restart();
      expect(fixture.ids, expected);
      expect(fixture.player.index, 3);
      expect(fixture.player.current!.id, 'c');
      expect(fixture.player.shuffle, isTrue);
      expect(fixture.player.contextPlaylistId, fixture.playlist.id);
      expect(fixture.player.position, const Duration(seconds: 5));
      expect(fixture.player.playing, isFalse);
      expect(fixture.audio.openedUris, isEmpty);
      await fixture.player.play();
      expect(fixture.player.position, const Duration(seconds: 5));
      expect(
        fixture.audio.openedUris.single,
        Uri.file(fixture.track('c').localPath!).toString(),
      );
      expect(fixture.player.index, 3);
    },
  );

  test(
    'legacy sessions infer the shuffle base without losing active order or position',
    () async {
      for (final wasShuffled in [false, true]) {
        final fixture = await _Fixture.create();
        // Stop the empty controller before writing the old schema, so its
        // shutdown save cannot replace the fixture with a modern session.
        await fixture.player.close();
        await fixture.library.setSetting('playback', {
          'ids': ['c', 'b', 'a', 'd'],
          'originalIds': ['a', 'b', 'c', 'd'],
          'order': [2, 1, 0, 3],
          'index': 1,
          'position': 7000,
          'repeat': 'off',
          'shuffle': wasShuffled,
          'contextPlaylistId': fixture.playlist.id,
        });
        await fixture.restart();
        expect(
          (fixture.library.settings['playback'] as Map).containsKey(
            'unshuffledOrder',
          ),
          isFalse,
        );
        expect(fixture.ids, ['c', 'b', 'a', 'd']);
        expect(fixture.player.index, 1);
        expect(fixture.player.current!.id, 'b');
        expect(fixture.player.position, const Duration(seconds: 7));
        expect(fixture.player.contextPlaylistId, fixture.playlist.id);
        expect(fixture.player.shuffle, wasShuffled);
        expect(fixture.player.playing, isFalse);
        final calls = fixture.audio.calls;

        if (!wasShuffled) {
          fixture.player.toggleShuffle();
          expect(fixture.player.current!.id, 'b');
        }
        fixture.player.toggleShuffle();
        final expected = wasShuffled
            ? ['a', 'b', 'c', 'd']
            : ['c', 'b', 'a', 'd'];
        expect(fixture.ids, expected);
        expect(fixture.player.shuffle, isFalse);
        expect(fixture.player.index, 1);
        expect(fixture.player.current!.id, 'b');
        expect(fixture.player.position, const Duration(seconds: 7));
        expect(fixture.audio.calls, calls);
        expect(fixture.audio.openedUris, isEmpty);

        await fixture.restart();
        expect(fixture.ids, expected);
        expect(fixture.player.index, 1);
        expect(fixture.player.current!.id, 'b');
        expect(fixture.player.position, const Duration(seconds: 7));
        expect(fixture.player.contextPlaylistId, fixture.playlist.id);
        expect(fixture.player.shuffle, isFalse);
        expect(fixture.audio.openedUris, isEmpty);
        expect(fixture.library.playlists.single.trackIds, ['a', 'b', 'c', 'd']);
      }
    },
  );

  test(
    'moving a pending decoder open keeps its request and deferred position',
    () async {
      final fixture = await _Fixture.create();
      final gate = fixture.audio.openGate = Completer<void>();
      final opening = fixture.start();
      await _until(
        () => fixture.audio.openedUris.length == 1,
        'The decoder must be waiting inside its initial open',
      );
      expect(fixture.player.loading, isTrue);
      await fixture.player.seek(const Duration(seconds: 7));
      final calls = fixture.audio.calls;

      await fixture.player.moveQueue(0, 3);
      await fixture.player.moveQueue(0, 2);
      expect(fixture.ids, ['c', 'd', 'b', 'a']);
      expect(fixture.player.index, 2);
      expect(fixture.player.current!.id, 'b');
      expect(fixture.player.position, const Duration(seconds: 7));
      expect(fixture.player.loading, isTrue);
      expect(fixture.audio.calls, calls);

      gate.complete();
      await opening;
      expect(fixture.player.loading, isFalse);
      expect(fixture.player.error, isNull);
      expect(fixture.player.playing, isTrue);
      expect(fixture.player.current!.id, 'b');
      expect(fixture.player.index, 2);
      expect(fixture.player.position, const Duration(seconds: 7));
      expect(fixture.audio.openedUris.length, 1);
      expect(fixture.audio.stops, 1);
      expect(fixture.audio.plays, 1);
      expect(fixture.audio.seeks, 1);
    },
  );
}
