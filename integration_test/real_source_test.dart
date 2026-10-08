// Opt-in native verification against the user's already configured Jackett.
// Reads credentials locally; never includes URLs, cookies or keys in evidence.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:path_provider/path_provider.dart';
import 'package:mumpa/main.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/logic/app_controller.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'real RuTracker search opens a persistent playable collection',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final profile =
          (jsonDecode(
                    await File(
                      '${support.path}/Mumpa/library.json',
                    ).readAsString(),
                  )
                  as Map)['settings']
              as Map;
      final root = await Directory(
        '${(await getTemporaryDirectory()).path}/mumpa-real-source-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final app = await createApplication(
        dataDirectory: root,
        catalogEnabled: false,
      );
      try {
        await app.library.setSetting('indexerUrl', profile['indexerUrl']);
        await app.library.setSetting('indexerKey', profile['indexerKey']);
        final configured = await app.indexer.configuredIndexers(
          profile['indexerUrl'] as String,
          profile['indexerKey'] as String,
        );
        expect(
          configured.any((i) => i.id == 'rutracker'),
          isTrue,
          reason:
              'Save RuTracker.org in Jackett before running this opt-in check.',
        );
        await tester.pumpWidget(MumpaApp(controller: app));
        app.navigate(AppPage.search);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('music-search')),
          'Ежемесячные',
        );
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (app.searching) {
          expect(
            DateTime.now().isBefore(deadline),
            isTrue,
            reason: 'Search timed out.',
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(app.error, isNull);
        expect(app.releases, isNotEmpty);
        final candidates =
            app.releases
                .where(
                  (r) => r.indexerName.toLowerCase().contains('rutracker.org'),
                )
                .toList()
              ..sort((a, b) {
                if ((a.seeders > 0) != (b.seeders > 0)) {
                  return a.seeders > 0 ? -1 : 1;
                }
                return a.bytes.compareTo(b.bytes);
              });
        expect(candidates, isNotEmpty);
        final selected = candidates.first;
        expect(selected.title.toLowerCase(), contains('ежемесячные'));
        expect(Uri.parse(selected.link).scheme, anyOf('http', 'https'));
        final elapsed = Stopwatch()..start();
        await app.openRelease(selected);
        elapsed.stop();
        expect(app.error, isNull);
        expect(app.page, AppPage.playlist);
        expect(app.library.playlists.length, 1);
        final audio = app.playlistTracks;
        expect(audio, isNotEmpty);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('collection-title')), findsOneWidget);
        expect(find.byType(CheckboxListTile), findsNothing);
        // Metainfo opening does not require live seeders. Playback is an
        // additional opt-in check whose result depends on this public swarm.
        if (const bool.fromEnvironment('REAL_PLAYBACK_TEST')) {
          await app.playback.setVolume(0);
          unawaited(app.playCollection(audio, playlistId: app.playlist!.id));
          final playbackDeadline = DateTime.now().add(
            const Duration(seconds: 90),
          );
          while (app.playback.position < const Duration(seconds: 1) &&
              app.playback.error == null &&
              DateTime.now().isBefore(playbackDeadline)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(app.playback.error, isNull);
          expect(
            app.playback.position.inMilliseconds,
            greaterThanOrEqualTo(1000),
          );
          await app.playback.pause();
        }
        final evidence = <String, Object>{
          'query': 'Ежемесячные',
          'resultCount': app.releases.length,
          'indexer': selected.indexerName,
          'album': selected.title,
          'audioFiles': audio.length,
          'openMs': elapsed.elapsedMilliseconds,
          'nativeCollectionPage': true,
          'persistentPlaylistCreated': true,
          if (const bool.fromEnvironment('REAL_PLAYBACK_TEST'))
            'nativeTorrentPlayback': true,
          if (const bool.fromEnvironment('REAL_PLAYBACK_TEST'))
            'playbackPositionMs': app.playback.position.inMilliseconds,
        };
        binding.reportData = evidence;
        await File(
          'test-output/real-source-result.json',
        ).writeAsString(jsonEncode(evidence));
        debugPrint('MUMPA_REAL_SOURCE ${jsonEncode(evidence)}');
      } finally {
        await tester.pumpWidget(const SizedBox());
        app.playback.dispose();
        app.downloads.dispose();
        app.dispose();
        await app.engine.stop();
        await root.delete(recursive: true);
      }
    },
    skip:
        !Platform.isWindows || !const bool.fromEnvironment('REAL_SOURCE_TEST'),
  );
}
