import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/profile_transfer.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/audio_preferences.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'support.dart';

class _CrossfadeAudio extends FakeAudioBackend {
  String? prepared;
  int transitions = 0;
  Completer<void>? startGate;
  bool preparationWorks = true;
  AudioPreferences? applied;
  @override
  bool get supportsCrossfade => true;
  @override
  Future<void> applyPreferences(AudioPreferences preferences) async =>
      applied = preferences;
  @override
  Future<bool> prepareNext(String uri) async {
    if (!preparationWorks) return false;
    prepared = uri;
    return true;
  }

  @override
  Future<void> cancelPrepared() async => prepared = null;
  @override
  Future<bool> crossfade(Duration duration, bool Function() onStarted) async {
    final uri = prepared;
    await startGate?.future;
    if (uri == null || prepared != uri || !onStarted()) return false;
    transitions++;
    prepared = null;
    await super.open(uri);
    return true;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('legacy defaults bypass all DSP; imported values are bounded', () {
    expect(AudioPreferences.fromSettings({}).filterGraph, isEmpty);
    final prefs = AudioPreferences.fromSettings({
      'equalizerEnabled': true,
      'equalizerGains': [30, -30, double.nan, 'bad'],
      'crossfadeEnabled': true,
      'crossfadeSeconds': double.infinity,
    });
    expect(prefs.gains, [12, -12, 0, 0, 0, 0]);
    expect(prefs.crossfadeSeconds, 5);
    expect(prefs.outputGain, closeTo(.2511886, .00001));
    expect(prefs.filterGraph, contains('equalizer=f=60:'));
    expect(prefs.filterGraph, isNot(contains('NaN')));
  });

  late Directory root;
  late LibraryRepository library;
  late TorrentService torrents;
  late _CrossfadeAudio audio;
  late PlaybackController player;
  late List<Track> tracks;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-audio-prefs-');
    library = LibraryRepository(root);
    await library.load();
    tracks = [
      for (var i = 0; i < 3; i++)
        Track(
          id: '$i',
          title: 'Track $i',
          artist: 'Artist',
          album: 'Album',
          source: TrackSource.local,
          localPath: '${root.path}/$i.wav',
        ),
    ];
    for (final track in tracks) {
      await File(track.localPath!).writeAsBytes([0]);
    }
    await library.upsert(tracks);
    torrents = TorrentService(
      endpoint: () async => throw StateError('No torrent engine expected'),
    );
    audio = _CrossfadeAudio();
    player = PlaybackController(
      library: library,
      torrents: torrents,
      backend: audio,
    );
    await player.initialize(platformAudio: false);
  });
  tearDown(() async {
    await player.close();
    torrents.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  test(
    'DSP changes and profile roundtrip retain queue, position and user volume',
    () async {
      await player.playTracks(tracks);
      await player.seek(const Duration(seconds: 7));
      await player.pause();
      final opened = audio.opened;
      await player.setAudioSetting('equalizerGains', [
        6.0,
        4.0,
        1.0,
        0.0,
        -1.0,
        -2.0,
      ]);
      for (final key in [
        'equalizerEnabled',
        'normalizeVolume',
        'monoAudio',
        'crossfadeEnabled',
      ]) {
        await player.setAudioSetting(key, true);
      }
      await player.setAudioSetting('crossfadeSeconds', 8.0);
      await library.setSetting('language', 'en');
      await library.setSetting('downloadQuality', 'lossless');
      expect(audio.opened, opened);
      expect(player.position.inSeconds, 7);
      expect(player.playing, isFalse);
      expect(player.queue.map((t) => t.id), ['0', '1', '2']);
      expect(player.volume, .8);
      expect(audio.applied!.filterGraph, contains('loudnorm='));
      expect(audio.applied!.filterGraph, contains('pan=args=stereo'));
      await player.setAudioSetting('equalizerEnabled', false);
      expect(audio.applied!.filterGraph, isNot(contains('equalizer=')));
      expect(player.audioPreferences.gains.first, 6);
      final target = LibraryRepository(Directory('${root.path}/target'));
      try {
        await target.load();
        await target.importProfile(
          ProfileTransfer.decode(await library.exportProfile()),
        );
        expect(target.settings['language'], 'en');
        expect(target.settings['downloadQuality'], 'lossless');
        expect(
          AudioPreferences.fromSettings(target.settings).crossfadeSeconds,
          8,
        );
        expect(AudioPreferences.fromSettings(target.settings).gains.first, 6);
      } finally {
        target.dispose();
      }
    },
  );

  test(
    'crossfade advances one occurrence and preserves queue identity',
    () async {
      await player.setAudioSetting('crossfadeEnabled', true);
      await player.setAudioSetting('crossfadeSeconds', 4.0);
      await player.playTracks(tracks);
      await _settle();
      expect(audio.prepared, isNull);
      await audio.seek(const Duration(seconds: 10));
      await _settle();
      expect(audio.prepared, endsWith('1.wav'));
      await audio.seek(const Duration(seconds: 21));
      await _settle();
      expect(audio.transitions, 1);
      expect(player.current!.id, '1');
      expect(player.playing, isTrue);
      expect(player.queue.map((t) => t.id), ['0', '1', '2']);
      await library.flush();
      expect((library.settings['playback'] as Map)['index'], 1);
    },
  );

  test(
    'pause invalidates a muted incoming track before it can replace selection',
    () async {
      await player.setAudioSetting('crossfadeEnabled', true);
      await player.playTracks(tracks);
      await audio.seek(const Duration(seconds: 12));
      await _settle();
      audio.startGate = Completer<void>();
      await audio.seek(const Duration(seconds: 21));
      await _settle();
      await player.pause();
      audio.startGate!.complete();
      await _settle();
      expect(audio.transitions, 0);
      expect(player.current!.id, '0');
      expect(player.playing, isFalse);
    },
  );

  test(
    'unavailable preparation and repeat one keep normal completion behavior',
    () async {
      await player.setAudioSetting('crossfadeEnabled', true);
      audio.preparationWorks = false;
      await player.playTracks(tracks);
      await audio.seek(const Duration(seconds: 21));
      await _settle();
      expect(player.current!.id, '0');
      expect(audio.transitions, 0);
      audio.completion.add(null);
      await _settle();
      expect(player.current!.id, '1');
      audio.preparationWorks = true;
      player.setRepeat(PlayerRepeatMode.one);
      await audio.seek(const Duration(seconds: 21));
      await _settle();
      expect(audio.transitions, 0);
      audio.completion.add(null);
      await _settle();
      expect(player.current!.id, '1');
    },
  );

  test(
    'download quality selects known recordings with a source-preserving fallback',
    () async {
      Track version(String id, String ext, {int duration = 180000}) => Track(
        id: id,
        title: 'Same song',
        artist: 'Artist',
        album: 'Album',
        source: TrackSource.torrent,
        torrentPath: '$id.$ext',
        durationMs: duration,
      );
      final mp3 = version('mp3', 'mp3'),
          flac = version('flac', 'flac'),
          live = version('different', 'flac', duration: 360000);
      await library.upsert([mp3, flac, live]);
      final downloads = DownloadRepository(library, torrents);
      try {
        expect(downloads.trackForDownload(mp3), mp3);
        await library.setSetting('downloadQuality', 'lossless');
        expect(downloads.trackForDownload(mp3), flac);
        expect(downloads.trackForDownload(live), live);
        await library.setSetting('downloadQuality', 'compact');
        expect(downloads.trackForDownload(flac), mp3);
        expect(downloads.trackForDownload(live), live);
      } finally {
        await downloads.close();
      }
    },
  );
}
