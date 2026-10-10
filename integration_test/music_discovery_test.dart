import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/main.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'real artist, track versions, native playback and persistent cover',
    (tester) async {
      if (!const bool.fromEnvironment('REAL_MUSIC_METADATA_TEST')) return;
      final sourceRoot = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'Mumpa'),
      );
      final root = await Directory.systemTemp.createTemp(
        'mumpa-music-discovery-',
      );
      final existing =
          jsonDecode(
                await File(
                  p.join(sourceRoot.path, 'library.json'),
                ).readAsString(),
              )
              as Map;
      final settings = Map<String, dynamic>.from(existing['settings'] as Map);
      final library = LibraryRepository(root);
      await library.load();
      for (final key in ['indexerUrl', 'indexerKey', 'torrentInterface']) {
        if (settings[key] != null) await library.setSetting(key, settings[key]);
      }
      await library.setSetting('autoCache', false);
      await library.setSetting('volume', 0.0);
      await library.flush();
      library.dispose();
      final app = await createApplication(
        dataDirectory: root,
        catalogEnabled: false,
      );
      try {
        final previewKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: previewKey,
            child: MumpaApp(controller: app),
          ),
        );
        final artist = await app.metadata.artist('Ежемесячные');
        expect(artist, isNotNull);
        expect(artist!.albums, isNotEmpty);
        final recordings = await app.metadata.searchRecordings(
          'Роженица в метро',
        );
        final song = recordings.firstWhere(
          (song) => song.catalogArtist == 'Ежемесячные',
        );
        await app.findRecordingVersions(song);
        expect(app.versionError, isNull, reason: app.versionError);
        expect(app.trackVariants, isNotEmpty);
        final selected = app.trackVariants.first;
        if (Platform.isWindows) {
          await tester.pump(const Duration(milliseconds: 300));
          final boundary =
              previewKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final preview = File('test-output/music-versions-1.2.0.png');
          await preview.parent.create(recursive: true);
          await preview.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        }
        await app.playback.setVolume(0);
        final start = DateTime.now();
        await app.playTrackVariant(selected);
        final deadline = DateTime.now().add(const Duration(seconds: 35));
        while (DateTime.now().isBefore(deadline) &&
            app.playback.position < const Duration(milliseconds: 2500)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(app.playback.error, isNull);
        expect(app.playback.playing, isTrue);
        expect(
          app.playback.position.inMilliseconds,
          greaterThanOrEqualTo(2500),
        );
        expect(app.playback.duration.inMilliseconds, greaterThan(0));
        final openAndProbeMs = DateTime.now().difference(start).inMilliseconds;
        debugPrint('MUMPA_DISCOVERY_STAGE native network playback passed');
        const groupId = '48117b90-a16e-34ca-a514-19c702df1158';
        final cover = await app.metadata.coverForGroup(groupId);
        expect(cover, isNotNull);
        expect(await File(cover!).exists(), isTrue);
        final size = await File(cover).length();
        final reused = await app.metadata.coverForGroup(groupId);
        expect(reused, cover);
        final evidence = <String, Object>{
          'artist': artist.name,
          'artistAlbums': artist.albums.length,
          'recording': song.title,
          'matchedVariants': app.trackVariants.length,
          'formats': app.trackVariants.map((v) => v.format).toSet().toList(),
          'nativePlaying': app.playback.playing,
          'positionMs': app.playback.position.inMilliseconds,
          'durationMs': app.playback.duration.inMilliseconds,
          'openAndProbeMs': openAndProbeMs,
          'httpSource': (app.playback.backend as NativeAudioBackend)
              .player
              .state
              .playlist
              .medias
              .any((media) => Uri.tryParse(media.uri)?.scheme == 'http'),
          'coverBytes': size,
          'coverReused': reused == cover,
          'queueContainsCollection': app.playback.queue.length > 1,
        };
        // Only public metadata and booleans; never tracker URLs, hashes or keys.
        debugPrint('MUMPA_DISCOVERY ${jsonEncode(evidence)}');
        if (Platform.isWindows) {
          final target = File(
            p.join(
              Directory.current.path,
              'test-output',
              'music-discovery-1.2.0.json',
            ),
          );
          await target.parent.create(recursive: true);
          await target.writeAsString(
            const JsonEncoder.withIndent('  ').convert(evidence),
          );
        }
        await tester.pumpWidget(const SizedBox());
      } finally {
        await app.shutdown();
        app.library.dispose();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
