import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/lan_transfer.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  test(
    'corrupted audio is never published and cancellation before import changes nothing',
    () async {
      final sendRoot = await Directory.systemTemp.createTemp(
        'mumpa-lan-corrupt-send-',
      );
      final receiveRoot = await Directory.systemTemp.createTemp(
        'mumpa-lan-corrupt-receive-',
      );
      final sender = LibraryRepository(sendRoot),
          receiver = LibraryRepository(receiveRoot);
      LanTransferServer? server;
      LanTransferClient? client;
      try {
        await sender.load();
        await receiver.load();
        final file = File('${sendRoot.path}/a.wav');
        await file.writeAsBytes([1, 2, 3]);
        const id = 'selected';
        final track = Track(
          id: id,
          title: 'Song',
          artist: 'Band',
          album: 'Album',
          source: TrackSource.local,
          localPath: file.path,
          bytes: 3,
        );
        await sender.upsert([track]);
        server = await LanTransferServer.start(sender, [
          track,
        ], bindAddress: InternetAddress.loopbackIPv4);
        client = LanTransferClient(server.address('127.0.0.1').toString());
        final offer = await client.preview();
        final invalid = <String, dynamic>{
          ...offer,
          'files': [
            {
              ...(offer['files'] as List).single as Map,
              'extension': '/../private.wav',
            },
          ],
        };
        expect(
          () => LanTransferClient.validateManifest(invalid),
          throwsFormatException,
        );
        final corrupted = <String, dynamic>{
          ...offer,
          'files': [
            {...(offer['files'] as List).single as Map, 'sha256': '0' * 64},
          ],
        };
        await expectLater(
          client.receive(receiver, corrupted),
          throwsFormatException,
        );
        expect(receiver.byId(id)!.localPath, isNull);
        expect(
          await receiveRoot
              .list(recursive: true)
              .where((e) => e.path.endsWith('.part'))
              .length,
          0,
        );
        await client.receive(receiver, offer);
        expect(await File(receiver.byId(id)!.localPath!).readAsBytes(), [
          1,
          2,
          3,
        ]);
        client.close();
        final snapshot = await receiver.exportProfile();
        await expectLater(client.receive(receiver, offer), throwsStateError);
        expect(
          (await receiver.exportProfile()).replaceAll(
            RegExp(r'"exportedAt":"[^"]+"'),
            '',
          ),
          snapshot.replaceAll(RegExp(r'"exportedAt":"[^"]+"'), ''),
        );
      } finally {
        client?.close();
        await server?.close();
        await sender.flush();
        await receiver.flush();
        sender.dispose();
        receiver.dispose();
        await sendRoot.delete(recursive: true);
        await receiveRoot.delete(recursive: true);
      }
    },
  );
  test(
    'LAN pairing accepts only private numeric addresses and a full capability token',
    () {
      for (final link in [
        'https://example.org/#${'a' * 43}',
        'http://8.8.8.8/#${'a' * 43}',
        'http://127.0.0.1/#short',
        'http://user@127.0.0.1/#${'a' * 43}',
      ]) {
        expect(() => LanTransferClient(link), throwsFormatException);
      }
      expect(LanTransferServer.isPrivateAddress('172.31.1.2'), isTrue);
      expect(LanTransferServer.isPrivateAddress('172.32.1.2'), isFalse);
      final client = LanTransferClient(
        'mumpa-transfer://192.168.1.2:9000/#${'a' * 43}',
      );
      client.close();
    },
  );
  test(
    'two real HTTP peers transfer profile and selected audio with stable IDs; unauthorized paths fail',
    () async {
      final sendRoot = await Directory.systemTemp.createTemp('mumpa-lan-send-');
      final receiveRoot = await Directory.systemTemp.createTemp(
        'mumpa-lan-receive-',
      );
      final sender = LibraryRepository(sendRoot),
          receiver = LibraryRepository(receiveRoot);
      LanTransferServer? server;
      LanTransferClient? client;
      final unauthorized = HttpClient();
      try {
        await sender.load();
        await receiver.load();
        final file = File('${sendRoot.path}/song.wav');
        await file.writeAsBytes(List.generate(8000, (i) => i % 251));
        final track = Track(
          id: 'stable-song',
          title: 'Song',
          artist: 'Band',
          album: 'Album',
          source: TrackSource.local,
          localPath: file.path,
          bytes: 8000,
        );
        await sender.upsert([track]);
        await sender.toggleLike(track.id);
        final list = await sender.createPlaylist('Saved');
        await sender.addToPlaylist(list.id, [track.id]);
        server = await LanTransferServer.start(sender, [
          track,
        ], bindAddress: InternetAddress.loopbackIPv4);
        final request = await unauthorized.getUrl(
          server.address('127.0.0.1').replace(fragment: '', path: '/manifest'),
        );
        final response = await request.close();
        expect(response.statusCode, 403);
        await response.drain<void>();
        client = LanTransferClient(server.address('127.0.0.1').toString());
        final offer = await client.preview();
        expect(offer.toString(), isNot(contains(sendRoot.path)));
        await client.receive(receiver, offer);
        final restored = receiver.byId(track.id)!;
        expect(
          await File(restored.localPath!).readAsBytes(),
          await file.readAsBytes(),
        );
        expect(receiver.isTrackLiked(track.id), isTrue);
        expect(receiver.playlistById(list.id)!.trackIds, [track.id]);
        await client.receive(receiver, offer);
        expect(receiver.tracks.length, 1);
        expect(
          await receiveRoot
              .list(recursive: true)
              .where((e) => e.path.endsWith('.part'))
              .length,
          0,
        );
      } finally {
        client?.close();
        unauthorized.close(force: true);
        await server?.close();
        await sender.flush();
        await receiver.flush();
        sender.dispose();
        receiver.dispose();
        await sendRoot.delete(recursive: true);
        await receiveRoot.delete(recursive: true);
      }
    },
  );
}
