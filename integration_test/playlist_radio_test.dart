// Opt-in proof of natural queue completion with the real Windows decoder.
// Uses original silent WAVs in a temporary profile; no external services.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/radio_repository.dart';
import 'package:mumpa/data/rutracker_service.dart';
import 'package:mumpa/data/similar_artists_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/logic/playback_controller.dart';

Uint8List _silence() {
  const rate = 8000;
  final bytes = Uint8List(44 + rate * 2 * 3);
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
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}

class _OfflineMetadata extends MusicMetadataRepository {
  _OfflineMetadata(DiskMediaCache cache, MockClient client)
    : super(cache: cache, client: client);
  @override
  Future<MusicArtist?> artist(
    String name, {
    SourceOperation? operation,
  }) async => null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('PLAYLIST_RADIO_TEST');
  if (enabled && Platform.isWindows) {
    MediaKit.ensureInitialized();
  }
  testWidgets(
    'native completion starts prepared radio and pause remains paused',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('mumpa-native-radio-');
      final library = LibraryRepository(root);
      await library.load();
      await library.setSetting('autoCache', false);
      await library.setSetting('volume', 0.0);
      var networkCalls = 0;
      final client = MockClient((_) async {
        networkCalls++;
        throw StateError('Offline radio must not call external HTTP');
      });
      final torrents = TorrentService(
        client: client,
        endpoint: () async {
          networkCalls++;
          throw StateError('Offline radio must not start the torrent engine');
        },
      );
      final metadata = _OfflineMetadata(
        DiskMediaCache(Directory('${root.path}/metadata')),
        client,
      );
      final similar = SimilarArtistsRepository(
        cache: metadata.cache,
        client: client,
      );
      final indexer = IndexerService(client: client);
      final catalog = RuTrackerService(
        transport: HttpCatalogTransport(client: client),
      );
      final tracks = <Track>[];
      for (var index = 0; index < 9; index++) {
        final file = File('${root.path}/$index.wav');
        await file.writeAsBytes(_silence());
        tracks.add(
          Track(
            id: 'native-$index',
            title: 'Original silence $index',
            artist: 'Radio fixture',
            album: 'Original fixture',
            source: TrackSource.local,
            localPath: file.path,
            durationMs: 3000,
          ),
        );
      }
      await library.upsert(tracks);
      final playlist = await library.createPlaylist('Original playlist');
      await library.addToPlaylist(playlist.id, [tracks.first.id]);
      final backend = NativeAudioBackend();
      expect(backend.player.platform, isA<NativePlayer>());
      final player = PlaybackController(
        library: library,
        torrents: torrents,
        backend: backend,
        radioSource: RadioRepository(
          library: library,
          torrents: torrents,
          metadata: metadata,
          similar: similar,
          indexer: indexer,
          catalog: catalog,
        ),
      );
      await player.initialize(platformAudio: false);
      Future<void> waitFor(bool Function() done) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!done()) {
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('Native radio');
          }
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Text('Native playlist radio verification')),
          ),
        );
        await player.setRadioEnabled(true);
        await player.playTracks([tracks.first], contextPlaylistId: playlist.id);
        await waitFor(() => player.radio.readyCount >= 2);
        expect(player.currentIsRadio, isFalse);
        await waitFor(
          () =>
              player.currentIsRadio &&
              player.playing &&
              player.position.inMilliseconds > 200,
        );
        final radioId = player.current!.id;
        expect(player.queue.length, 2);
        expect(library.playlists.single.trackIds, [tracks.first.id]);
        await player.pause();
        final pausedPosition = player.position;
        await tester.pump(const Duration(seconds: 4));
        expect(player.playing, isFalse);
        expect(player.current!.id, radioId);
        expect(
          (player.position - pausedPosition).inMilliseconds.abs(),
          lessThan(150),
        );
        expect(networkCalls, 0);
        final output = Directory('${Directory.current.path}/test-output');
        await output.create(recursive: true);
        await File('${output.path}/native-radio-1.2.9.json').writeAsString(
          jsonEncode({
            'version': '1.2.9+17',
            'backend': 'NativePlayer/libmpv',
            'naturalQueueCompletion': true,
            'preparedBeforeCompletion': true,
            'playlistUnchanged': true,
            'pauseRetained': true,
            'externalHttpOrEngineCalls': networkCalls,
          }),
        );
      } finally {
        await player.close();
        await library.flush();
        library.dispose();
        similar.dispose();
        metadata.dispose();
        indexer.dispose();
        torrents.dispose();
        await catalog.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await root.delete(recursive: true);
      }
    },
    skip: !enabled || !Platform.isWindows,
  );
}
