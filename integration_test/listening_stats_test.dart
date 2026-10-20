import 'package:mumpa/logic/audio_runtime.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/playback_controller.dart';

Uint8List _silence() {
  final bytes = Uint8List(44 + 8000 * 2 * 12);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
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
  data.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('LISTENING_STATS_NATIVE');
  if (enabled && Platform.isWindows) initializeAudioRuntime();
  testWidgets(
    'native audio counts listens once and saves the device top',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'mumpa-native-listens-',
      );
      final library = LibraryRepository(root);
      final torrents = TorrentService(
        endpoint: () async => throw StateError('No network'),
      );
      PlaybackController? player;
      try {
        await library.load();
        await library.setSetting('volume', 0.0);
        final file = await File(
          '${root.path}/silence.wav',
        ).writeAsBytes(_silence());
        Track track(String id, String path) => Track(
          id: id,
          title: id,
          artist: 'Fixture',
          album: 'Fixture',
          source: TrackSource.local,
          localPath: path,
        );
        final good = track('played', file.path);
        final missing = track('missing', '${root.path}/missing.wav');
        await library.upsert([good, missing]);
        final playlist = await library.createPlaylist('Native listening');
        await library.addToPlaylist(playlist.id, [missing.id, good.id]);
        player = PlaybackController(
          library: library,
          torrents: torrents,
          backend: NativeAudioBackend(),
        );
        await player.initialize(platformAudio: false);
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await player.playTracks([
          missing,
          good,
        ], contextPlaylistId: playlist.id);
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (library.trackPlayCount(good.id) == 0 &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(library.trackPlayCount(good.id), 1);
        expect(library.trackPlayCount(missing.id), 0);
        expect(library.playlistPlayCount(playlist.id), 1);
        await player.pause();
        await player.play();
        await tester.pump(const Duration(seconds: 1));
        expect(library.trackPlayCount(good.id), 1);
        await player.close();
        player = null;
        await library.load();
        expect(library.topTracksPlaylist.trackIds, [good.id]);
        expect(library.frequentPlaylists.single.id, playlist.id);
        await Directory('test-output').create();
        await File('test-output/listening-stats-native.json').writeAsString(
          jsonEncode({
            'decoder': 'Windows/libmpv',
            'count': library.trackPlayCount(good.id),
            'failedFileCount': library.trackPlayCount(missing.id),
            'pauseResumeNoDuplicate': true,
            'persistedTop': library.topTracksPlaylist.trackIds,
            'playlistCount': library.playlistPlayCount(playlist.id),
          }),
        );
      } finally {
        await player?.close();
        await library.flush();
        library.dispose();
        torrents.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !enabled || !Platform.isWindows,
  );
}
