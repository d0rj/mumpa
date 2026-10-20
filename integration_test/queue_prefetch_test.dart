// Isolated loopback transfers and real libmpv decoding; no public swarm/profile.
import 'package:mumpa/logic/audio_runtime.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/logic/queue_prefetch.dart';

Uint8List _silence() {
  final bytes = Uint8List(44 + 8000 * 2 * 10);
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

class _LoopbackSource extends TorrentService {
  _LoopbackSource(this.base)
    : super(endpoint: () async => throw StateError('No engine'));
  final String base;
  final calls = <String>[];
  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) async {
    operation?.check();
    calls.add(track.id);
    return Uri.parse('$base/${track.id}');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('QUEUE_PREFETCH_NATIVE');
  if (enabled && Platform.isWindows) initializeAudioRuntime();
  testWidgets(
    'native queue prefetch survives failed stream and uses completed file',
    (tester) async {
      final root = await Directory(
        'D:/Projects/mumpa/.local',
      ).createTemp('prefetch-native-');
      final library = LibraryRepository(root);
      await library.load();
      await library.setSetting('volume', 0.0);
      final bytes = _silence();
      final file = await File('${root.path}/start.wav').writeAsBytes(bytes);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        if (request.uri.path == '/unavailable') {
          request.response.statusCode = 503;
        } else {
          final range = request.headers.value(HttpHeaders.rangeHeader);
          final match = range == null
              ? null
              : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
          final start = int.tryParse(match?.group(1) ?? '') ?? 0;
          final end = int.tryParse(match?.group(2) ?? '') ?? bytes.length - 1;
          if (range != null) {
            request.response.statusCode = 206;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${bytes.length}',
            );
          }
          request.response.contentLength = end - start + 1;
          request.response.add(bytes.sublist(start, end + 1));
        }
        await request.response.close();
      });
      final source = _LoopbackSource('http://127.0.0.1:${server.port}');
      Track local(String id, String path) => Track(
        id: id,
        title: id,
        artist: 'Fixture',
        album: id,
        source: TrackSource.local,
        localPath: path,
      );
      Track remote(String id) => Track(
        id: id,
        title: id,
        artist: 'Fixture',
        album: id,
        source: TrackSource.torrent,
        torrentHash: 'hash-$id',
        torrentPath: '$id.wav',
        torrentIndex: 1,
        bytes: bytes.length,
      );
      final tracks = [
        local('missing', '${root.path}/missing.wav'),
        local('start', file.path),
        remote('unavailable'),
        remote('ready'),
        remote('later'),
        remote('last'),
      ];
      await library.upsert(tracks);
      final playlist = await library.createPlaylist('Original queue');
      await library.addToPlaylist(
        playlist.id,
        tracks.map((t) => t.id).toList(),
      );
      final backend = NativeAudioBackend();
      final player = PlaybackController(
        library: library,
        torrents: source,
        backend: backend,
      );
      await player.initialize(platformAudio: false);
      final downloads = DownloadRepository(library, source);
      await downloads.restore();
      final prefetch = QueuePrefetch(
        library: library,
        playback: player,
        downloads: downloads,
      );
      await prefetch.setCount(2);
      Future<void> waitFor(bool Function() ready) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!ready()) {
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('Native prefetch: ${player.error}');
          }
          await tester.pump(const Duration(milliseconds: 25));
        }
      }

      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Text('Mumpa prefetch verification')),
          ),
        );
        expect(backend.player.platform, isA<NativePlayer>());
        await player.playTracks(tracks, contextPlaylistId: playlist.id);
        await waitFor(
          () =>
              player.position.inMilliseconds > 100 &&
              library.byId('ready')!.cachedPath != null,
        );
        expect(player.current!.id, 'start');
        expect(downloads.jobs.map((j) => j.track.id), ['unavailable', 'ready']);
        expect(library.byId('later')!.cachedPath, isNull);
        await player.seek(player.duration - const Duration(milliseconds: 250));
        await waitFor(
          () =>
              player.current?.id == 'ready' &&
              player.position.inMilliseconds > 100 &&
              player.playing,
        );
        expect(player.error, isNull);
        expect(
          source.calls.where((id) => id == 'ready').length,
          1,
          reason: 'Prepared complete file should not resolve a stream again',
        );
        expect(
          backend.player.state.playlist.medias.single.uri,
          library.byId('ready')!.cachedPath!.replaceAll('\\', '/'),
        );
        expect(
          library.playlists.single.trackIds,
          tracks.map((t) => t.id).toList(),
        );
        await player.pause();
        await tester.pump(const Duration(milliseconds: 400));
        expect(player.playing, isFalse);
        expect(
          await File(library.byId('ready')!.cachedPath!).readAsBytes(),
          bytes,
        );
        await File(
          'D:/Projects/mumpa/test-output/prefetch-native.json',
        ).writeAsString(
          jsonEncode({
            'version': '1.2.18+26',
            'decoder': 'Windows/libmpv',
            'lookahead': 2,
            'missingFileSkipped': true,
            'http503Skipped': true,
            'naturalCompletion': true,
            'preparedFilePlayedOffline': true,
            'playlistPreserved': true,
            'pauseRetained': true,
            'bytesVerified': true,
            'resolvedIds': source.calls,
            'loopbackRequests': requests,
          }),
        );
      } finally {
        prefetch.close();
        await downloads.close();
        await player.close();
        await server.close(force: true);
        source.dispose();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !enabled || !Platform.isWindows,
  );
}
