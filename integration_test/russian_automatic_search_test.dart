import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/main.dart';
import 'package:mumpa/ui/app_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'fresh Android/Windows finds Ежемесячные without helpers',
    (tester) async {
      final temporary = await getTemporaryDirectory();
      final root = await Directory(
        '${temporary.path}/mumpa-russian-source-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final evidence = <String, dynamic>{'platform': Platform.operatingSystem};
      AppController? app;
      try {
        app = await createApplication(
          dataDirectory: root,
          catalogEnabled: false,
        );
        expect(app.usesAutomaticSource, isTrue);
        expect(app.library.tracks, isEmpty);
        expect(app.library.settings['indexerKey'], isNull);
        await app.library.setSetting('autoplayRadio', false);
        app.query = 'Ежемесячные';
        await app.searchSources();
        expect(app.error, isNull);
        final found = app.releases
            .where((item) => item.title.toLowerCase().contains('ежемесячные'))
            .toList();
        expect(found, isNotEmpty);
        evidence['results'] = found
            .map(
              (item) => {
                'title': item.title,
                'source': item.indexerName,
                'seeders': item.seeders,
              },
            )
            .toList();
        app.navigate(AppPage.search);
        await tester.pumpWidget(MumpaApp(controller: app));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('ДУШЕВНО И КРЕПКО'), findsWidgets);
        expect(app.jackettConnection, isNull);
        expect(await Directory('${root.path}/jackett').exists(), isFalse);
        expect(await Directory('${root.path}/flaresolverr').exists(), isFalse);
        evidence['noHelpers'] = true;
        if (!const bool.fromEnvironment('RUSSIAN_STREAM_TEST')) return;
        await app.openRelease(found.first);
        expect(
          app.error,
          isNull,
          reason: 'The real release must expose its audio files',
        );
        expect(app.library.tracks, isNotEmpty);
        evidence['audioFiles'] = app.library.tracks.length;
        final selected = app.library.tracks.first;
        await app.playCollection([selected]);
        final deadline = DateTime.now().add(const Duration(seconds: 75));
        while (app.playback.position.inMilliseconds < 3000 &&
            DateTime.now().isBefore(deadline) &&
            app.playback.error == null) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        evidence['playbackMs'] = app.playback.position.inMilliseconds;
        evidence['playbackError'] = app.playback.error;
        expect(
          app.playback.position.inMilliseconds,
          greaterThanOrEqualTo(3000),
          reason: 'Real peers must serve playable audio',
        );
        await app.playback.pause();
      } finally {
        debugPrint('MUMPA_RUSSIAN_SOURCE ${jsonEncode(evidence)}');
        await tester.pumpWidget(const SizedBox());
        if (app != null) {
          await app.shutdown();
          app.library.dispose();
        }
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('RUSSIAN_AUTOMATIC_TEST'),
  );
}
