import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/playback_controller.dart';

import 'support.dart';

class _DeferredTimeline extends FakeAudioBackend {
  final acknowledgements = <Completer<void>>[];
  bool delayAcknowledgement = false;
  bool failSeek = false;
  Completer<void>? openGate;
  bool openStarted = false;
  Future<void> publishPosition(Duration value) => super.seek(value);

  @override
  Future<void> open(
    String uri, {
    bool play = true,
    Duration start = Duration.zero,
  }) async {
    openStarted = true;
    await openGate?.future;
    await super.open(uri, play: play, start: start);
  }

  @override
  Future<void> seek(Duration value) async {
    if (failSeek) throw StateError('Decoder rejected seek');
    // Native mpv acknowledges the command before publishing the new timeline.
    if (delayAcknowledgement) {
      final gate = Completer<void>();
      acknowledgements.add(gate);
      await gate.future;
    }
  }
}

void main() {
  late Directory root;
  late LibraryRepository library;
  late TorrentService torrents;
  late _DeferredTimeline audio;
  late PlaybackController player;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-seek-save-');
    library = LibraryRepository(root);
    await library.load();
    final file = await File('${root.path}/local.wav').writeAsBytes([1, 2, 3]);
    await library.upsert([
      Track(
        id: 'one',
        title: 'One',
        artist: 'Fixture',
        album: 'Fixture',
        source: TrackSource.local,
        localPath: file.path,
        durationMs: 24000,
      ),
      Track(
        id: 'two',
        title: 'Two',
        artist: 'Fixture',
        album: 'Fixture',
        source: TrackSource.local,
        localPath: file.path,
        durationMs: 24000,
      ),
    ]);
    torrents = TorrentService(
      endpoint: () async => throw StateError('No network'),
    );
    audio = _DeferredTimeline();
    player = PlaybackController(
      library: library,
      torrents: torrents,
      backend: audio,
    );
    await player.initialize(platformAudio: false);
  });
  tearDown(() async {
    if (audio.openGate case final gate? when !gate.isCompleted) gate.complete();
    for (final gate in audio.acknowledgements) {
      if (!gate.isCompleted) gate.complete();
    }
    await player.close();
    await library.flush();
    library.dispose();
    torrents.dispose();
    await root.delete(recursive: true);
  });
  Future<int> savedPosition() async {
    await library.flush();
    final saved =
        jsonDecode(await File('${root.path}/library.json').readAsString())
            as Map;
    return (saved['settings']['playback']['position'] as num).toInt();
  }

  test(
    'paused seek persists the requested position before native timeline arrives',
    () async {
      await player.playTracks(library.tracks);
      await player.pause();
      await player.seek(const Duration(milliseconds: 7250));
      expect(audio.position, Duration.zero);
      expect(player.position.inMilliseconds, 7250);
      await player.saveSession();
      expect(await savedPosition(), 7250);
    },
  );

  test(
    'seeking a restored but unopened track is durable without Play or Close',
    () async {
      await player.playTracks(library.tracks);
      await player.pause();
      await player.close();
      audio = _DeferredTimeline();
      player = PlaybackController(
        library: library,
        torrents: torrents,
        backend: audio,
      );
      await player.initialize(platformAudio: false);
      await player.seek(const Duration(milliseconds: 11250));
      expect(audio.opened, isNull);
      expect(await savedPosition(), 11250);
    },
  );

  test(
    'manual seek during a restored open is saved before that open completes',
    () async {
      await player.playTracks(library.tracks);
      await player.pause();
      await player.seek(const Duration(seconds: 5));
      await player.close();
      audio = _DeferredTimeline()..openGate = Completer<void>();
      player = PlaybackController(
        library: library,
        torrents: torrents,
        backend: audio,
      );
      await player.initialize(platformAudio: false);
      final opening = player.play();
      while (!audio.openStarted) {
        await Future<void>.delayed(Duration.zero);
      }
      await player.seek(const Duration(milliseconds: 11250));
      expect(await savedPosition(), 11250);
      audio.openGate!.complete();
      await opening;
      expect(await savedPosition(), 11250);
    },
  );

  test(
    'volume events cannot confirm a small seek before its timeline update',
    () async {
      await player.playTracks(library.tracks);
      await player.pause();
      await player.seek(const Duration(milliseconds: 100));
      await audio.setVolume(.5);
      await player.saveSession();
      expect(await savedPosition(), 100);
      await audio.publishPosition(const Duration(milliseconds: 96));
      await audio.publishPosition(const Duration(milliseconds: 400));
      expect(player.position.inMilliseconds, 400);
    },
  );

  test('a rejected native seek releases the pending position', () async {
    await player.playTracks(library.tracks);
    await player.pause();
    audio.failSeek = true;
    await expectLater(
      player.seek(const Duration(seconds: 7)),
      throwsStateError,
    );
    expect(player.position, Duration.zero);
    await player.saveSession();
    expect(await savedPosition(), 0);
  });

  test('seek intents are bounded by the playable timeline', () async {
    await player.playTracks(library.tracks);
    await player.pause();
    await player.seek(const Duration(seconds: -1));
    expect(await savedPosition(), 0);
    await player.seek(const Duration(seconds: 90));
    expect(await savedPosition(), player.duration.inMilliseconds);
    await audio.publishPosition(player.duration);
    expect(player.position, player.duration);
  });

  test('late acknowledgement cannot replace a newer manual seek', () async {
    await player.playTracks(library.tracks);
    await player.pause();
    audio.delayAcknowledgement = true;
    final first = player.seek(const Duration(seconds: 7));
    while (audio.acknowledgements.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final second = player.seek(const Duration(seconds: 12));
    while (audio.acknowledgements.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    audio.acknowledgements[1].complete();
    await second;
    audio.acknowledgements[0].complete();
    await first;
    expect(await savedPosition(), 12000);
  });

  test(
    'late seek acknowledgement cannot overwrite a replacement queue',
    () async {
      await player.playTracks(library.tracks);
      await player.pause();
      audio.delayAcknowledgement = true;
      final seeking = player.seek(const Duration(seconds: 7));
      while (audio.acknowledgements.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await player.playTracks([library.byId('two')!]);
      audio.acknowledgements.single.complete();
      await seeking;
      expect(await savedPosition(), 0);
      expect(player.current!.id, 'two');
    },
  );
}
