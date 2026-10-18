import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mumpa/main.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/ui/app_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'fresh install catalogue and preserved Windows favorites',
    (tester) async {
      final temporary = await getTemporaryDirectory();
      final root = await Directory(
        '${temporary.path}/mumpa-first-run-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final evidence = <String, Object>{};
      AppController? app;
      try {
        final output = Directory('${Directory.current.path}/test-output');
        await output.create(recursive: true);
        final freshRoot = await Directory('${root.path}/fresh').create();
        app = await createApplication(
          dataDirectory: freshRoot,
          catalogEnabled: false,
        );
        expect(app.usesAutomaticSource, isTrue);
        expect(app.library.tracks, isEmpty);
        expect(app.jackettConnection, isNull);
        await app.initializeSources();
        expect(app.indexerError, isNull);
        expect(app.sourceFeed, isNotEmpty);
        expect(await Directory('${freshRoot.path}/jackett').exists(), isFalse);
        expect(
          await Directory('${freshRoot.path}/flaresolverr').exists(),
          isFalse,
        );
        app.query = 'Кино';
        await app.searchSources();
        expect(app.error, isNull);
        expect(app.releases, isNotEmpty);
        expect(
          app.releases.every((release) => release.link.startsWith('magnet:')),
          isTrue,
        );
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MumpaApp(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        evidence.addAll({
          'freshFeed': app.sourceFeed.length,
          'cyrillicSearch': app.releases.length,
          'noJackettProfile': true,
          'noFlareSolverrProfile': true,
        });
        if (const bool.fromEnvironment('PUBLIC_PLAYBACK_TEST')) {
          if (const bool.fromEnvironment('PUBLIC_USE_SAVED_NETWORK')) {
            final support = await getApplicationSupportDirectory();
            final saved =
                jsonDecode(
                      await File(
                        '${support.path}/Mumpa/library.json',
                      ).readAsString(),
                    )
                    as Map;
            await app.library.setSetting(
              'torrentInterface',
              (saved['settings'] as Map)['torrentInterface'],
            );
            evidence['usesSavedNetworkChoice'] = true;
          }
          app.query = 'Nine Inch Nails Ghosts';
          await app.searchSources();
          final candidates = app.releases
              .where((release) => release.seeders > 0)
              .take(3)
              .toList();
          var played = false;
          final attempts = <Map<String, Object?>>[];
          for (final release in candidates) {
            await app.openRelease(release);
            attempts.add({
              'tracks': app.playlistTracks.length,
              'error': app.error,
            });
            if (app.playlistTracks.isEmpty) continue;
            await app.playCollection([app.playlistTracks.first]);
            final end = DateTime.now().add(const Duration(seconds: 30));
            while (DateTime.now().isBefore(end) &&
                app.playback.error == null &&
                app.playback.position.inMilliseconds < 3000) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            played = app.playback.position.inMilliseconds >= 3000;
            await app.playback.pause();
            if (played) break;
          }
          evidence['publicSwarmPlayback'] = played;
          evidence['attempts'] = attempts;
          await File(
            '${output.path}/first-run-public-playback.json',
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
          expect(
            played,
            isTrue,
            reason:
                'Search succeeded, but public peers must also serve playable audio on the default network route.',
          );
        }
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${output.path}/first-run-catalog.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        app.library.dispose();
        app = null;

        final support = await getApplicationSupportDirectory();
        final source = File('${support.path}/Mumpa/library.json');
        final original = await source.readAsBytes();
        final saved = jsonDecode(utf8.decode(original)) as Map;
        final restoredRoot = await Directory('${root.path}/restored').create();
        await File('${restoredRoot.path}/library.json').writeAsBytes(original);
        app = await createApplication(
          dataDirectory: restoredRoot,
          catalogEnabled: false,
        );
        expect(app.library.loadWarning, isNull);
        expect(
          app.library.favoriteTracks.length,
          (saved['liked'] as List).length,
        );
        app.navigate(AppPage.liked);
        await tester.pumpWidget(MumpaApp(controller: app));
        await tester.pumpAndSettle();
        final offline = app.library.favoriteTracks
            .where((track) => track.cachedPath != null)
            .first;
        await app.library.setSetting('autoplayRadio', false);
        await app.playCollection([offline]);
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (app.playback.position.inMilliseconds < 1500) {
          expect(DateTime.now().isBefore(deadline), isTrue);
          await tester.pump(const Duration(milliseconds: 100));
        }
        evidence.addAll({
          'restoredTracks': app.library.tracks.length,
          'restoredFavorites': app.library.favoriteTracks.length,
          'savedFavoriteNativePlayback': true,
          'sourceFileUnchanged':
              (await source.readAsBytes()).length == original.length,
        });
        expect(await source.readAsBytes(), original);
        await File(
          '${output.path}/first-run-native.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
        debugPrint('MUMPA_FIRST_RUN ${jsonEncode(evidence)}');
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (app != null) {
          await app.shutdown();
          app.library.dispose();
        }
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('FIRST_RUN_NETWORK_TEST'),
  );
}
