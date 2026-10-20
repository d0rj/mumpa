import 'package:mumpa/logic/audio_runtime.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/main.dart';
import 'package:mumpa/ui/app_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  initializeAudioRuntime();
  testWidgets(
    'fresh Android/Windows opens the full Ежемесячные discography without helpers',
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
        const testInterface = String.fromEnvironment('TORRENT_INTERFACE');
        if (testInterface.isNotEmpty) {
          expect(Platform.isWindows, isTrue);
          await app.library.setSetting('torrentInterface', testInterface);
          evidence['explicitNetworkInterface'] = true;
        }
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
        expect(app.jackettConnection, isNull);
        expect(await Directory('${root.path}/jackett').exists(), isFalse);
        expect(await Directory('${root.path}/flaresolverr').exists(), isFalse);
        evidence['noHelpers'] = true;
        final discography = found.firstWhere(
          (release) => release.title.toLowerCase().contains('дискография'),
        );
        await app.openRelease(discography);
        expect(
          app.error,
          isNull,
          reason: 'The real release must expose its audio files',
        );
        expect(app.library.tracks.length, greaterThan(400));
        evidence['audioFiles'] = app.library.tracks.length;
        final albums = app.library.tracks.map((track) => track.album).toSet();
        expect(albums.length, greaterThan(30));
        evidence['albums'] = albums.length;
        if (!const bool.fromEnvironment('RUSSIAN_STREAM_TEST')) return;
        final selected = app.library.tracks.reduce(
          (a, b) => a.bytes < b.bytes ? a : b,
        );
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
        app.downloads.enqueue([selected], priority: true);
        final downloadDeadline = DateTime.now().add(
          const Duration(seconds: 90),
        );
        while (app.downloads.jobs
                .where((job) => job.track.id == selected.id)
                .every((job) => job.state != DownloadState.complete) &&
            DateTime.now().isBefore(downloadDeadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        final downloaded = app.library.byId(selected.id)!;
        final path = await app.library.localPathFor(downloaded);
        expect(path, isNotNull);
        expect(await File(path!).length(), selected.bytes);
        evidence['downloadedBytes'] = await File(path).length();
        await app.playback.stop();
        await app.engine.stop();
        expect(app.playback.position, Duration.zero);
        await app.playCollection([downloaded]);
        final offlineDeadline = DateTime.now().add(const Duration(seconds: 15));
        while (app.playback.position.inMilliseconds < 1000 &&
            DateTime.now().isBefore(offlineDeadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(
          app.playback.position.inMilliseconds,
          greaterThanOrEqualTo(1000),
        );
        expect(app.playback.error, isNull);
        evidence['offlinePlaybackMs'] = app.playback.position.inMilliseconds;
        evidence['offlinePlaybackWithoutEngine'] = true;
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
