// Opt-in check of existing liked sources in an isolated library. Never prints
// tracker URLs, source links, API keys or raw engine responses.
import 'package:mumpa/logic/audio_runtime.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/main.dart';
import 'package:mumpa/ui/app_screen.dart';

void main() {
  const requirePlayback = bool.fromEnvironment('REQUIRE_FAVORITES_PLAYBACK');
  const diagnosticServer = String.fromEnvironment('FAVORITES_SERVER_URL');
  const selectedInterface = String.fromEnvironment('FAVORITES_INTERFACE');
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  initializeAudioRuntime();
  testWidgets(
    requirePlayback
        ? 'a real liked torrent plays from the network'
        : 'existing liked tracks play or report bounded network failure',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final profile = Directory('${support.path}/Mumpa');
      final data =
          jsonDecode(await File('${profile.path}/library.json').readAsString())
              as Map;
      final liked = List<String>.from(data['liked'] as List);
      final tracks = (data['tracks'] as List)
          .map(
            (value) => Track.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .where(
            (track) =>
                liked.contains(track.id) && track.source == TrackSource.torrent,
          )
          .map((track) => track.copyWith(clearCache: true))
          .toList();
      expect(tracks, isNotEmpty);
      expect(tracks.every((track) => track.localPath == null), isTrue);
      final root = await Directory(
        '${(await getTemporaryDirectory()).path}/mumpa-favorites-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final app = await createApplication(
        dataDirectory: root,
        catalogEnabled: false,
      );
      final evidence = <Map<String, Object?>>[];
      try {
        if (selectedInterface.isNotEmpty) {
          expect(diagnosticServer, isEmpty);
          await app.library.setSetting('torrentInterface', selectedInterface);
        }
        if (diagnosticServer.isNotEmpty) {
          final uri = Uri.parse(diagnosticServer);
          expect(uri.scheme, 'http');
          expect(uri.host, '127.0.0.1');
          expect(uri.userInfo, isEmpty);
          expect(uri.query, isEmpty);
          await app.library.setSetting('serverUrl', diagnosticServer);
        }
        await app.library.setSetting('autoCache', false);
        await app.library.upsert(tracks);
        await app.playback.setVolume(0);
        for (final track in tracks) {
          await app.library.toggleLike(track.id);
          final metainfo = File(
            '${profile.path}/torrents/${stableId(track.torrentHash!)}.torrent',
          );
          if (await metainfo.exists()) {
            final copy = File(
              '${root.path}/torrents/${metainfo.uri.pathSegments.last}',
            );
            await copy.parent.create(recursive: true);
            await metainfo.copy(copy.path);
          }
        }
        app.navigate(AppPage.liked);
        await tester.pumpWidget(MumpaApp(controller: app));
        await tester.pumpAndSettle();
        final hashes = <String>{};
        for (final track in tracks.where(
          (track) => hashes.add(track.torrentHash!),
        )) {
          final start = Stopwatch()..start();
          int? firstAudioMs;
          await tester.tap(find.byKey(ValueKey('track-row-${track.id}')));
          final deadline = DateTime.now().add(const Duration(seconds: 70));
          while (app.playback.error == null &&
              app.playback.position.inMilliseconds < 2500 &&
              DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 100));
            if (firstAudioMs == null &&
                app.playback.playing &&
                app.playback.position.inMilliseconds > 0) {
              firstAudioMs = start.elapsedMilliseconds;
            }
          }
          final played =
              app.playback.playing &&
              app.playback.position.inMilliseconds >= 2500;
          await tester.pump();
          if (!played) {
            expect(
              app.playback.error,
              isNotNull,
              reason: 'Failure must replace the loading state.',
            );
            expect(app.playback.loading, isFalse);
            expect(app.playback.buffering, isFalse);
            expect(find.byKey(const Key('retry-playback')), findsOneWidget);
          }
          expect(app.playback.current!.id, track.id);
          expect(app.playback.queue.length, tracks.length);
          final torrent = await app.torrents.get(track.torrentHash!);
          evidence.add({
            'title': track.title,
            'trackId': track.id,
            'nativePublicPlayback': played,
            'elapsedMs': start.elapsedMilliseconds,
            'firstAudioMs': firstAudioMs,
            'networkSelection': selectedInterface.isEmpty
                ? 'system-route'
                : 'explicit-interface',
            'positionMs': app.playback.position.inMilliseconds,
            'durationMs': app.playback.duration.inMilliseconds,
            'engineVersion': await app.torrents.version(),
            'activePeers': torrent.peers,
            'downloadSpeed': torrent.speed,
            'freshTorrentSource': (app.playback.backend as NativeAudioBackend)
                .player
                .state
                .playlist
                .medias
                .any((media) => Uri.tryParse(media.uri)?.scheme == 'http'),
            'boundedFailure': !played,
            'retryVisible': !played,
          });
          await app.playback.stop();
          if (requirePlayback && played) break;
        }
        binding.reportData = {'favorites': evidence};
        await File(
          'test-output/real-favorites-result.json',
        ).writeAsString(jsonEncode(evidence));
        debugPrint('MUMPA_FAVORITES ${jsonEncode(evidence)}');
        if (requirePlayback) {
          expect(
            evidence.any(
              (result) =>
                  result['nativePublicPlayback'] == true &&
                  result['freshTorrentSource'] == true &&
                  (result['durationMs'] as int) > 0,
            ),
            isTrue,
            reason:
                'At least one real liked torrent must play from the network.',
          );
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        app.dispose();
        app.downloads.dispose();
        await app.playback.close();
        app.torrents.dispose();
        await app.engine.stop();
        await app.library.flush();
        app.library.dispose();
        await root.delete(recursive: true);
      }
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('REAL_FAVORITES_TEST'),
  );
}
