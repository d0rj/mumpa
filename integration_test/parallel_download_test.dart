// Opt-in Windows UI + local HTTP transport proof. No production profile,
// public tracker, torrent engine, firewall changes or copyrighted audio.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/pages.dart';
import 'package:path/path.dart' as p;

import '../test/support.dart';

const _prefixBytes = 32 * 1024;
const _progressBytes = 16 * 1024;
const _heldBytes = _prefixBytes + _progressBytes;
const _payloadLength = 256 * 1024;

/// Original mono PCM WAV generated in memory for exact transport checks.
Uint8List _originalWav(int seed) {
  final bytes = Uint8List(_payloadLength);
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
  data.setUint32(24, 22050, Endian.little);
  data.setUint32(28, 44100, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  for (var offset = 44; offset < bytes.length; offset += 2) {
    final sample = (offset - 44) ~/ 2;
    final time = sample / 22050;
    final tone = math.sin(2 * math.pi * (180 + seed * 37) * time);
    data.setInt16(offset, (tone * 6000).round(), Endian.little);
  }
  return bytes;
}

class _NetworkGuard {
  int unexpectedHttp = 0;
  int engineStarts = 0;

  MockClient client() => MockClient((_) async {
    unexpectedHttp++;
    throw StateError('Only the fixture loopback HTTP server is permitted');
  });
}

class _OfflineMetadata extends MusicMetadataRepository {
  _OfflineMetadata(Directory root, _NetworkGuard guard)
    : super(
        cache: DiskMediaCache(Directory(p.join(root.path, 'metadata'))),
        client: guard.client(),
      );

  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
  @override
  Future<String?> coverForGroup(String id) async => null;
  @override
  Future<String?> coverForReleaseTitle(String title) async => null;
}

class _LoopbackTorrents extends TorrentService {
  _LoopbackTorrents(this.base, _NetworkGuard guard)
    : super(
        client: guard.client(),
        endpoint: () async {
          guard.engineStarts++;
          throw StateError(
            'The native transport fixture must not start an engine',
          );
        },
      );

  final Uri base;
  final List<String> resolved = [];

  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) async {
    operation?.check();
    resolved.add(track.id);
    return base.resolve(track.id);
  }
}

class _Transfer {
  _Transfer(this.id, this.offset);
  final String id;
  final int offset;
  final gate = Completer<void>();
  bool prefixSent = false;

  void release() {
    if (!gate.isCompleted) gate.complete();
  }
}

class _GatedHttpServer {
  _GatedHttpServer(this.server, this.payloads) {
    _subscription = server.listen((request) {
      final pending = _serve(request);
      _handlers.add(pending);
      unawaited(
        pending.whenComplete(() {
          _handlers.remove(pending);
        }),
      );
    });
  }

  final HttpServer server;
  final Map<String, Uint8List> payloads;
  final List<_Transfer> requests = [];
  final Set<Future<void>> _handlers = {};
  final _closing = Completer<void>();
  late final StreamSubscription<HttpRequest> _subscription;
  bool _releaseFutureRequests = false;

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}/');
  List<_Transfer> forId(String id) =>
      requests.where((request) => request.id == id).toList();

  Future<void> _serve(HttpRequest request) async {
    unawaited(request.response.done.then<void>((_) {}, onError: (Object _) {}));
    final id = request.uri.pathSegments.single;
    final payload = payloads[id]!;
    final range = request.headers.value(HttpHeaders.rangeHeader) ?? '';
    final offset =
        int.tryParse(
          RegExp(r'^bytes=(\d+)-$').firstMatch(range)?.group(1) ?? '',
        ) ??
        0;
    final transfer = _Transfer(id, offset);
    requests.add(transfer);
    if (_releaseFutureRequests) transfer.release();
    try {
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType('audio', 'wav');
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.contentLength = payload.length - offset;
      if (offset > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $offset-${payload.length - 1}/${payload.length}',
        );
      }
      final firstEnd = math.min(payload.length, offset + _prefixBytes);
      request.response.add(payload.sublist(offset, firstEnd));
      await request.response.flush();
      // The repository deliberately throttles progress notifications to 150ms.
      // A second real chunk makes the screenshot show nonzero progress.
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (_closing.isCompleted) return;
      final prefixEnd = math.min(payload.length, firstEnd + _progressBytes);
      request.response.add(payload.sublist(firstEnd, prefixEnd));
      await request.response.flush();
      transfer.prefixSent = true;
      await Future.any([transfer.gate.future, _closing.future]);
      if (_closing.isCompleted) return;
      request.response.add(payload.sublist(prefixEnd));
      await request.response.close();
    } catch (_) {
      // A paused downloader closes its HTTP client before the gate is released.
    }
  }

  void release(String id) {
    for (final transfer in forId(id)) {
      transfer.release();
    }
  }

  void releaseAll() {
    _releaseFutureRequests = true;
    for (final transfer in requests) {
      transfer.release();
    }
  }

  Future<void> close() async {
    if (!_closing.isCompleted) _closing.complete();
    await server.close(force: true);
    await _subscription.cancel();
    await Future.wait(_handlers.toList());
  }
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String reason, {
  int seconds = 20,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException(reason);
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _jobAction(WidgetTester tester, String title, String tooltip) {
  final text = find.descendant(
    of: find.byType(ContentPage),
    matching: find.text(title),
  );
  final row = tester.element(text).findAncestorWidgetOfExactType<Row>()!;
  return find.descendant(
    of: find.byWidgetPredicate((widget) => identical(widget, row)),
    matching: find.byTooltip(tooltip),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'three real HTTP downloads share slots, resume, and complete exact WAV files',
    (tester) async {
      if (!const bool.fromEnvironment('PARALLEL_DOWNLOAD_TEST') ||
          !Platform.isWindows) {
        return;
      }
      final root = await Directory.systemTemp.createTemp(
        'mumpa-native-parallel-',
      );
      final library = LibraryRepository(root);
      await library.load();
      await library.setSetting('autoCache', false);
      final payloads = {
        for (var index = 1; index <= 4; index++)
          'parallel-$index': _originalWav(index),
      };
      final tracks = [
        for (var index = 1; index <= 4; index++)
          Track(
            id: 'parallel-$index',
            title: 'Параллельный трек $index',
            artist: 'Оригинальные тестовые волны',
            album: 'Параллельный альбом',
            source: TrackSource.torrent,
            torrentHash: 'isolated-local-transport-fixture',
            torrentIndex: index,
            torrentPath:
                'Параллельный альбом/0$index. Параллельный трек $index.wav',
            bytes: payloads['parallel-$index']!.length,
            number: index,
          ),
      ];
      await library.upsert(tracks);
      final server = _GatedHttpServer(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        payloads,
      );
      final guard = _NetworkGuard();
      final torrents = _LoopbackTorrents(server.base, guard);
      final downloads = DownloadRepository(library, torrents);
      await downloads.restore();
      final playback = PlaybackController(
        library: library,
        torrents: torrents,
        backend: FakeAudioBackend(),
      );
      await playback.initialize(platformAudio: false);
      final app = AppController(
        library: library,
        playback: playback,
        downloads: downloads,
        torrents: torrents,
        engine: TorrentEngine(root),
        indexer: IndexerService(client: guard.client()),
        metadata: _OfflineMetadata(root, guard),
      );
      final screenshot = GlobalKey();
      DownloadJob job(String id) =>
          downloads.jobs.singleWhere((item) => item.track.id == id);
      bool held(String id) =>
          server.forId(id).any((request) => request.prefixSent) &&
          job(id).received >= _heldBytes &&
          job(id).state == DownloadState.downloading;

      try {
        expect(downloads.maxConcurrentDownloads, 3);
        for (final limit in [1, 3]) {
          await downloads.setMaxConcurrentDownloads(limit);
          final reloadedLibrary = LibraryRepository(root);
          await reloadedLibrary.load();
          final reloadedDownloads = DownloadRepository(
            reloadedLibrary,
            torrents,
          );
          try {
            expect(library.settings['downloadConcurrency'], limit);
            expect(downloads.maxConcurrentDownloads, limit);
            expect(reloadedDownloads.maxConcurrentDownloads, limit);
          } finally {
            await reloadedDownloads.close();
            reloadedLibrary.dispose();
          }
        }
        app.openAlbum(app.albums.single);
        await tester.pumpWidget(
          RepaintBoundary(
            key: screenshot,
            child: MumpaApp(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Скачать альбом'));
        app.navigate(AppPage.downloads);
        await _until(
          tester,
          () => held('parallel-1') && held('parallel-2') && held('parallel-3'),
          'All three first workers must deliver real audio bytes together',
        );
        expect(job('parallel-4').state, DownloadState.queued);
        expect(server.requests.map((request) => request.id).toSet(), {
          'parallel-1',
          'parallel-2',
          'parallel-3',
        });
        expect(torrents.resolved, isNot(contains('parallel-4')));
        await tester.pump(const Duration(milliseconds: 300));
        final progress = find.descendant(
          of: find.byType(ContentPage),
          matching: find.byType(LinearProgressIndicator),
        );
        expect(progress, findsNWidgets(3));
        for (final indicator in tester.widgetList<LinearProgressIndicator>(
          progress,
        )) {
          expect(indicator.value, allOf(greaterThan(0), lessThan(1)));
        }
        await tester.ensureVisible(progress.last);
        await tester.pump(const Duration(milliseconds: 300));
        final viewport = tester.getRect(
          find.descendant(
            of: find.byType(ContentPage),
            matching: find.byType(CustomScrollView),
          ),
        );
        for (var index = 0; index < 3; index++) {
          expect(
            viewport.contains(tester.getRect(progress.at(index)).center),
            isTrue,
            reason:
                'Every active progress bar must be visible in the native PNG',
          );
        }
        final output = await Directory(
          p.join(Directory.current.path, 'test-output'),
        ).create(recursive: true);
        final image =
            await (screenshot.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            p.join(output.path, 'parallel-downloads-1.2.5.png'),
          ).writeAsBytes(png!.buffer.asUint8List());
        } finally {
          image.dispose();
        }

        server.release('parallel-1');
        await _until(
          tester,
          () =>
              job('parallel-1').state == DownloadState.complete &&
              held('parallel-4'),
          'The queued fourth stream must start when only the first worker finishes',
        );
        expect(job('parallel-2').state, DownloadState.downloading);
        expect(job('parallel-3').state, DownloadState.downloading);
        final retained = job('parallel-2').received;
        await tester.ensureVisible(
          _jobAction(tester, tracks[1].title, 'Приостановить'),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(_jobAction(tester, tracks[1].title, 'Приостановить'));
        await _until(
          tester,
          () =>
              job('parallel-2').state == DownloadState.paused &&
              job('parallel-2').client == null,
          'Pause must close its own HTTP client and partial-file writer',
        );
        final partial = File(
          p.join(library.downloads.path, 'parallel-2.wav.part'),
        );
        expect(await partial.length(), retained);
        expect(job('parallel-3').state, DownloadState.downloading);
        expect(job('parallel-4').state, DownloadState.downloading);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.ensureVisible(
          _jobAction(tester, tracks[1].title, 'Продолжить'),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(_jobAction(tester, tracks[1].title, 'Продолжить'));
        await _until(
          tester,
          () =>
              server.forId('parallel-2').length == 2 &&
              server.forId('parallel-2').last.prefixSent &&
              job('parallel-2').received >= retained + _heldBytes,
          'Resume must request a Range while its two neighbors remain active',
        );
        expect(server.forId('parallel-2').last.offset, retained);
        expect(job('parallel-3').state, DownloadState.downloading);
        expect(job('parallel-4').state, DownloadState.downloading);
        server.releaseAll();
        await _until(
          tester,
          () => downloads.jobs.every(
            (item) => item.state == DownloadState.complete,
          ),
          'Every generated WAV must finish as a complete offline track',
          seconds: 30,
        );
        final proofs = <String, Object>{};
        for (final track in tracks) {
          final cached = library.byId(track.id)!.cachedPath;
          expect(cached, isNotNull);
          final bytes = await File(cached!).readAsBytes();
          final expected = payloads[track.id]!;
          expect(bytes.length, expected.length);
          expect(sha256.convert(bytes), sha256.convert(expected));
          expect(bytes, expected);
          expect(await File('$cached.part').exists(), isFalse);
          expect(job(track.id).received, expected.length);
          proofs[track.id] = {
            'bytes': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
            'rangeOffsets': server
                .forId(track.id)
                .map((request) => request.offset)
                .toList(),
          };
        }
        expect(guard.unexpectedHttp, 0);
        expect(guard.engineStarts, 0);
        expect(tester.takeException(), isNull);
        await File(
          p.join(output.path, 'parallel-downloads-1.2.5.json'),
        ).writeAsString(
          jsonEncode({
            'transport': 'isolated loopback HTTP; no BitTorrent engine',
            'concurrentStreams': 3,
            'fourthWaitedForSlot': true,
            'pauseResumeRetainedBytes': retained,
            'persistedConcurrency': downloads.maxConcurrentDownloads,
            'tracks': proofs,
          }),
        );
        debugPrint(
          'MUMPA_PARALLEL_DOWNLOADS: 3 streams + queue, Range resume, 4/4 exact WAV SHA256',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        server.releaseAll();
        await app.shutdown();
        await server.close();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
