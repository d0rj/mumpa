import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:path_provider/path_provider.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/main.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/ui/app_screen.dart';

List<int> bencode(Object value) {
  if (value is int) return 'i${value}e'.codeUnits;
  if (value is String) return bencode(Uint8List.fromList(value.codeUnits));
  if (value is Uint8List) return [...'${value.length}:'.codeUnits, ...value];
  if (value is List) {
    return [108, for (final item in value) ...bencode(item as Object), 101];
  }
  if (value is Map<String, Object>) {
    final keys = value.keys.toList()..sort();
    return [
      100,
      for (final key in keys) ...[...bencode(key), ...bencode(value[key]!)],
      101,
    ];
  }
  throw ArgumentError.value(value);
}

Future<void> waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  int seconds = 30,
}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Integration condition');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A minimal original-content BitTorrent seeder. No external swarm or downloads.
TestSeeder startSeeder(
  Uint8List audio,
  Uint8List infoHash,
  int pieceSize,
  void Function() onRequest, {
  int bytesPerSecond = 0,
}) {
  return TestSeeder(audio, infoHash, pieceSize, onRequest, bytesPerSecond);
}

class TestSeeder {
  TestSeeder(
    this.audio,
    this.infoHash,
    this.pieceSize,
    this.onRequest,
    this.bytesPerSecond,
  );
  final Uint8List audio, infoHash;
  final int pieceSize;
  final void Function() onRequest;
  final int bytesPerSecond;
  Future<void> _sending = Future.value();
  final Set<int> _sentOffsets = {};
  int uniqueBytesSent = 0;
  final Set<Socket> peers = {};
  final Set<int> connecting = {};

  List<int> packet(int id, List<int> body) {
    final header = ByteData(4)..setUint32(0, body.length + 1);
    return [...header.buffer.asUint8List(), id, ...body];
  }

  Future<void> connect(int port) async {
    if (!connecting.add(port)) return;
    final peer = await Socket.connect(InternetAddress.loopbackIPv4, port);
    peers.add(peer);
    // A process restart can reset the upload side of the old connection. The
    // stream listener handles inbound errors; IOSink.done is a separate future.
    unawaited(peer.done.then<void>((_) {}, onError: (Object _) {}));
    // Initiate plaintext: the shipped engine starts outbound with MSE. Our
    // deliberately small fixture implements the standard plaintext peer wire.
    peer.add([
      19,
      ...'BitTorrent protocol'.codeUnits,
      ...List.filled(8, 0),
      ...infoHash,
      ...'-MU0001-123456789012'.codeUnits,
    ]);
    var buffer = <int>[];
    var handshake = false;
    peer.listen(
      (bytes) {
        buffer.addAll(bytes);
        if (!handshake) {
          if (buffer.length < 68) return;
          buffer = buffer.sublist(68);
          handshake = true;
          final pieces = (audio.length / pieceSize).ceil();
          final field = List.filled((pieces / 8).ceil(), 255);
          if (pieces % 8 != 0) {
            field[field.length - 1] = (255 << (8 - pieces % 8)) & 255;
          }
          peer.add(packet(5, field));
          peer.add(packet(1, []));
        }
        while (buffer.length >= 4) {
          final header = ByteData.sublistView(
            Uint8List.fromList(buffer.take(4).toList()),
          );
          final length = header.getUint32(0);
          if (buffer.length < length + 4) return;
          final body = Uint8List.fromList(buffer.sublist(4, length + 4));
          buffer = buffer.sublist(length + 4);
          if (body.isEmpty || body[0] != 6 || body.length != 13) continue;
          final request = ByteData.sublistView(body);
          final index = request.getUint32(1);
          final begin = request.getUint32(5);
          final count = request.getUint32(9);
          final start = index * pieceSize + begin;
          if (count > pieceSize || start + count > audio.length) {
            peer.destroy();
            return;
          }
          final prefix = ByteData(8)
            ..setUint32(0, index)
            ..setUint32(4, begin);
          final payload = packet(7, [
            ...prefix.buffer.asUint8List(),
            ...audio.sublist(start, start + count),
          ]);
          _sending = _sending
              .then((_) async {
                if (!peers.contains(peer)) return;
                if (bytesPerSecond > 0) {
                  await Future<void>.delayed(
                    Duration(
                      microseconds: (count * 1000000 / bytesPerSecond).ceil(),
                    ),
                  );
                }
                if (!peers.contains(peer)) return;
                peer.add(payload);
                onRequest();
                if (_sentOffsets.add(start)) uniqueBytesSent += count;
              })
              .catchError((Object _) {});
        }
      },
      onError: (Object _) {},
      onDone: () {
        peers.remove(peer);
        connecting.remove(port);
        peer.destroy();
      },
    );
  }

  Future<void> close() async {
    for (final peer in peers.toList()) {
      peer.destroy();
    }
    peers.clear();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'native local, managed torrent, range seeking, download and offline playback',
    (tester) async {
      final temp = await getTemporaryDirectory();
      final root = await Directory(
        '${temp.path}/mumpa-e2e-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final app = await createApplication(
        dataDirectory: root,
        demo: true,
        catalogEnabled: false,
      );
      final evidence = <String, Object>{'platform': Platform.operatingSystem};
      HttpServer? seed;
      TestSeeder? peerSeed;
      try {
        await tester.pumpWidget(MumpaApp(controller: app));
        await tester.pumpAndSettle();
        app.openAlbum(app.albums.first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('play-album')));
        await waitUntil(
          tester,
          () =>
              app.playback.position.inMilliseconds > 500 &&
              app.playback.playing,
        );
        evidence['nativeLocalPlayback'] = true;
        debugPrint('MUMPA_STAGE local playback');
        await app.playback.seek(const Duration(seconds: 8));
        await waitUntil(tester, () => app.playback.position.inSeconds >= 8);
        evidence['localSeek'] = true;
        await app.playback.pause();
        expect(app.playback.playing, isFalse);
        final audio = await File(
          app.library.tracks.first.localPath!,
        ).readAsBytes();
        seed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final seedUrl = 'http://127.0.0.1:${seed.port}';
        final pieces = <int>[];
        const pieceSize = 16384;
        for (var start = 0; start < audio.length; start += pieceSize) {
          pieces.addAll(
            sha1
                .convert(
                  audio.sublist(
                    start,
                    (start + pieceSize).clamp(0, audio.length),
                  ),
                )
                .bytes,
          );
        }
        final infoDictionary = <String, Object>{
          'name': 'original.wav',
          'length': audio.length,
          'piece length': pieceSize,
          'pieces': Uint8List.fromList(pieces),
        };
        var seedRequests = 0;
        peerSeed = startSeeder(
          audio,
          Uint8List.fromList(sha1.convert(bencode(infoDictionary)).bytes),
          pieceSize,
          () => seedRequests++,
          bytesPerSecond: 300 * 1024,
        );
        final metainfo = Uint8List.fromList(
          bencode(<String, Object>{
            'announce': '$seedUrl/announce',
            'info': infoDictionary,
          }),
        );
        seed.listen((request) async {
          try {
            if (request.uri.path == '/album.torrent') {
              request.response.headers.contentType = ContentType(
                'application',
                'x-bittorrent',
              );
              request.response.add(metainfo);
            } else if (request.uri.path == '/announce') {
              // info_hash is raw binary and cannot be decoded as UTF-8 along
              // with the ordinary query values.
              final port = int.parse(
                Uri.splitQueryString(
                  request.uri.query,
                  encoding: latin1,
                )['port']!,
              );
              unawaited(
                peerSeed!.connect(port).catchError((Object e) {
                  debugPrint('Fixture peer connection: $e');
                }),
              );
              request.response.add(
                bencode(<String, Object>{
                  'interval': 5,
                  'complete': 1,
                  'incomplete': 0,
                  'peers': Uint8List(0),
                }),
              );
            } else {
              seedRequests++;
              final range = request.headers.value(HttpHeaders.rangeHeader);
              final match = RegExp(
                r'bytes=(\d+)-(\d*)',
              ).firstMatch(range ?? '');
              final start = match == null ? 0 : int.parse(match.group(1)!);
              final end = match == null || match.group(2)!.isEmpty
                  ? audio.length - 1
                  : int.parse(match.group(2)!).clamp(0, audio.length - 1);
              request.response.headers.contentType = ContentType(
                'audio',
                'wav',
              );
              request.response.headers.set(
                HttpHeaders.acceptRangesHeader,
                'bytes',
              );
              if (match != null) {
                request.response.statusCode = 206;
                request.response.headers.set(
                  HttpHeaders.contentRangeHeader,
                  'bytes $start-$end/${audio.length}',
                );
              }
              request.response.contentLength = end - start + 1;
              request.response.add(audio.sublist(start, end + 1));
            }
            await request.response.close();
          } catch (e) {
            debugPrint('Fixture HTTP error: $e');
            await request.response.close();
          }
        });
        evidence['engineVersion'] = await app.torrents.version();
        await app.openRelease(
          SearchRelease(
            title: 'Torrent fixture',
            link: '$seedUrl/album.torrent',
          ),
        );
        expect(app.error, isNull);
        expect(app.page, AppPage.playlist);
        expect(app.playlist!.sourceHash, isNotEmpty);
        expect(app.playlistTracks.length, 1);
        expect(app.downloads.jobs, isEmpty);
        await tester.pumpAndSettle();
        final track = app.playlistTracks.single;
        final startTime = Stopwatch()..start();
        await tester.tap(find.byKey(ValueKey('track-row-${track.id}')));
        await waitUntil(
          tester,
          () =>
              app.playback.playing &&
              app.playback.position.inMilliseconds > 500,
          seconds: 90,
        );
        expect(app.playback.error, isNull);
        expect(seedRequests, greaterThan(0));
        expect(startTime.elapsed.inSeconds, lessThan(5));
        expect(peerSeed.uniqueBytesSent, lessThan(audio.length));
        expect(app.downloads.jobs.single.state, DownloadState.downloading);
        expect(app.library.byId(track.id)!.cachedPath, isNull);
        evidence['collectionPlaylistCreated'] = true;
        evidence['playbackStartsBeforeFullTorrent'] = true;
        evidence['autoOfflineDownloadDuringPlayback'] = true;
        evidence['streamStartMs'] = startTime.elapsedMilliseconds;
        evidence['torrentBytesAtFirstAudio'] = peerSeed.uniqueBytesSent;
        evidence['nativeTorrentPlayback'] = true;
        debugPrint('MUMPA_STAGE torrent playback');
        evidence['bitTorrentPieceRequests'] = seedRequests;
        await app.playback.seek(const Duration(seconds: 12));
        await waitUntil(tester, () => app.playback.position.inSeconds >= 12);
        evidence['torrentSeek'] = true;
        await app.playback.pause();
        final http = HttpClient();
        final rangeRequest = await http.getUrl(
          await app.torrents.stream(track.torrentHash!, track.torrentIndex!),
        );
        rangeRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=100-199');
        final rangeResponse = await rangeRequest.close();
        expect(rangeResponse.statusCode, 206);
        final rangeBytes = await rangeResponse.fold<List<int>>(
          [],
          (a, b) => a..addAll(b),
        );
        expect(rangeBytes, audio.sublist(100, 200));
        http.close();
        evidence['realHttpRange'] = true;
        await waitUntil(
          tester,
          () => app.downloads.jobs.single.state == DownloadState.complete,
          seconds: 90,
        );
        final cached = app.library.byId(track.id)!;
        expect(
          sha256.convert(await File(cached.cachedPath!).readAsBytes()),
          sha256.convert(audio),
        );
        evidence['offlineSha256'] = sha256.convert(audio).toString();
        debugPrint('MUMPA_STAGE download verified');
        await app.engine.stop();
        // Read persisted metainfo after a real process restart. get() may first
        // return a DB record without a live reader; resolve must wait for files.
        final restartedHttp = HttpClient();
        final restartedRequest = await restartedHttp.getUrl(
          await app.torrents.resolve(track),
        );
        restartedRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=100-199');
        final restartedResponse = await restartedRequest.close().timeout(
          const Duration(seconds: 20),
        );
        expect(
          await restartedResponse.fold<List<int>>([], (a, b) => a..addAll(b)),
          audio.sublist(100, 200),
        );
        restartedHttp.close();
        evidence['engineRestartRestoresTorrent'] = true;
        debugPrint('MUMPA_STAGE engine restart');
        await app.engine.stop();
        await peerSeed.close();
        peerSeed = null;
        await seed.close(force: true);
        seed = null;
        await app.playback.playTracks([cached]);
        await waitUntil(
          tester,
          () =>
              app.playback.playing &&
              app.playback.position.inMilliseconds > 500,
        );
        await app.playback.seek(const Duration(seconds: 15));
        await waitUntil(tester, () => app.playback.position.inSeconds >= 15);
        evidence['offlinePlaybackWithEngineAndSeedStopped'] = true;
        if (Platform.isAndroid) {
          expect(app.playback.system, isNotNull);
          evidence['androidAudioServiceRegistered'] = true;
        }
        binding.reportData = evidence;
        debugPrint('MUMPA_E2E $evidence');
      } catch (e, stack) {
        debugPrint(
          'MUMPA_E2E_FAILURE $e\n$stack\nPlayer error: ${app.playback.error}\nFixture: ${root.path}',
        );
        rethrow;
      } finally {
        await seed?.close(force: true);
        await peerSeed?.close();
        app.dispose();
        app.downloads.dispose();
        await app.playback.close();
        await app.engine.stop();
        app.torrents.dispose();
        await app.library.flush();
        app.library.dispose();
        try {
          await root.delete(recursive: true);
        } catch (e) {
          debugPrint('Fixture cleanup: $e');
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
