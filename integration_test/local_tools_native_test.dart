import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/lan_transfer.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/audio_runtime.dart';
import 'package:mumpa/logic/playback_controller.dart';

Uint8List _pcm() {
  final bytes = Uint8List(44 + 8000 * 2 * 14),
      data = ByteData.sublistView(bytes);
  void text(int offset, String text) =>
      bytes.setRange(offset, offset + text.length, text.codeUnits);
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
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  initializeAudioRuntime();
  testWidgets(
    'real decoder, listening clock, car commands and verified LAN file transfer',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('mumpa-local-native-');
      final receiverRoot = await Directory.systemTemp.createTemp(
        'mumpa-receive-native-',
      );
      final library = LibraryRepository(root),
          receiver = LibraryRepository(receiverRoot);
      final torrents = TorrentService(
        endpoint: () async => 'http://127.0.0.1:1',
      );
      PlaybackController? playback;
      LanTransferServer? server;
      LanTransferClient? client;
      try {
        await library.load();
        await receiver.load();
        final file = File('${root.path}/audio.wav');
        await file.writeAsBytes(_pcm());
        Track track(String id) => Track(
          id: id,
          title: id,
          artist: 'Native fixture',
          album: 'Native album',
          source: TrackSource.local,
          localPath: file.path,
          bytes: awaitLength,
          durationMs: 14000,
        );
        final first = track('first'), second = track('second');
        await library.upsert([first, second]);
        final list = await library.createPlaylist('Native playlist');
        await library.addToPlaylist(list.id, [first.id, second.id]);
        playback = PlaybackController(
          library: library,
          torrents: torrents,
          backend: NativeAudioBackend(),
        );
        await playback.initialize(platformAudio: Platform.isAndroid);
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Center(child: Text('Mumpa native feature checks')),
            ),
          ),
        );
        await playback.playTracks([first, second], contextPlaylistId: list.id);
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (playback.position.inMilliseconds < 2300 &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(playback.position.inMilliseconds, greaterThanOrEqualTo(2300));
        expect(
          library.listeningSummary().milliseconds,
          greaterThanOrEqualTo(1200),
        );
        final queueKeys = playback.queueEntryKeys;
        await playback.pause();
        final before = playback.position;
        await tester.pump(const Duration(milliseconds: 400));
        await playback.play();
        await tester.pump(const Duration(milliseconds: 500));
        expect(playback.position, greaterThanOrEqualTo(before));
        expect(library.trackPlayCount('first'), 1);
        await playback.seek(const Duration(seconds: 6));
        await tester.pump(const Duration(milliseconds: 250));
        expect(playback.queueEntryKeys, queueKeys);
        expect(playback.current!.id, 'first');
        final smart = await library.saveSmartPlaylist('Unplayed', {
          'unplayed': true,
        });
        expect(smart.trackIds, ['second']);
        await library.setPinned(['first'], true);
        await library.editMetadata(first, {'title': 'Edited locally'});
        final handler = playback.system ?? SystemAudioHandler(playback);
        expect(
          (await handler.getChildren(
            'playlists',
          )).any((m) => m.id == 'playlist:${list.id}'),
          isTrue,
        );
        await handler.playFromMediaId('playlist:${list.id}');
        expect(playback.current!.id, 'first');
        expect(playback.contextPlaylistId, list.id);
        Map<String, dynamic>? conditions;
        if (Platform.isAndroid) {
          conditions = await const MethodChannel(
            'app.mumpa/device',
          ).invokeMapMethod<String, dynamic>('conditions');
          expect(conditions?['wifi'], isA<bool>());
          expect(conditions?['charging'], isA<bool>());
          handler.publish();
          await tester.pump(const Duration(milliseconds: 200));
          final device = await const MethodChannel(
            'app.mumpa/device',
          ).invokeMapMethod<String, dynamic>('diagnostics');
          expect(device?['title'], 'Edited locally');
          expect(device?['shortcuts'], contains(list.id));
        }
        server = await LanTransferServer.start(library, [
          library.byId('first')!,
        ], bindAddress: InternetAddress.loopbackIPv4);
        client = LanTransferClient(server.address('127.0.0.1').toString());
        final offer = await client.preview();
        await client.receive(receiver, offer);
        final restored = receiver.byId('first')!;
        expect(await File(restored.localPath!).length(), await file.length());
        expect(restored.title, 'Edited locally');
        expect(receiver.features.pinned, contains('first'));
        expect(receiver.playlistById(list.id)!.trackIds, ['first', 'second']);
        await playback.pause();
        await playback.saveSession();
        binding.reportData = {
          'platform': Platform.operatingSystem,
          'realDecoder': true,
          'creditedMilliseconds': library.listeningSummary().milliseconds,
          'pauseResumeCount': library.trackPlayCount('first'),
          'queueRetainedOnSeek': true,
          'smartPlaylist': smart.trackIds,
          'carBrowseAndPlay': true,
          'deviceConditions': conditions,
          'lanBytes': await File(restored.localPath!).length(),
          'lanHashVerified': true,
          'metadataAndPinTransferred': true,
        };
      } finally {
        client?.close();
        await server?.close();
        await playback?.close();
        await library.flush();
        await receiver.flush();
        library.dispose();
        receiver.dispose();
        torrents.dispose();
        await root.delete(recursive: true);
        await receiverRoot.delete(recursive: true);
      }
    },
  );
}

const awaitLength = 44 + 8000 * 2 * 14;
