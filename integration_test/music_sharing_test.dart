import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_share_link.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import '../test/support.dart';
import 'test_artifacts.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native links open exact offline music in the running Windows instance',
    (tester) async {
      if (!Platform.isWindows) return;
      final root = await Directory.systemTemp.createTemp('mumpa-native-share-');
      AppController? app;
      try {
        final library = LibraryRepository(root);
        await library.load();
        await library.setSetting('autoCache', false);
        const hash = '0123456789abcdef0123456789abcdef01234567';
        final data = await rootBundle.load(
          'assets/demo/01 - First light.wav.bin',
        );
        final file = await File(
          '${root.path}/song.wav',
        ).writeAsBytes(data.buffer.asUint8List());
        final tracks = [
          for (var i = 1; i <= 3; i++)
            Track(
              id: stableId('$hash:$i'),
              title: 'Shared song $i',
              artist: 'Mumpa Sessions',
              album: i < 3 ? 'First album' : 'Second album',
              source: TrackSource.torrent,
              torrentHash: hash,
              torrentIndex: i,
              torrentPath: 'album$i/$i.wav',
              cachedPath: file.path,
            ),
        ];
        final collection = await library.openSourceCollection(
          hash: hash,
          name: 'Sharing fixture collection',
          tracks: tracks,
        );
        final torrents = TorrentService(
          endpoint: () async =>
              throw StateError('Offline check must not use the network'),
        );
        final playback = PlaybackController(
          library: library,
          torrents: torrents,
          backend: FakeAudioBackend(),
        );
        await playback.initialize(platformAudio: false);
        app = AppController(
          library: library,
          playback: playback,
          downloads: DownloadRepository(library, torrents),
          torrents: torrents,
          engine: TorrentEngine(root),
        );
        await tester.pumpWidget(MumpaApp(controller: app));
        final earlyLink = MusicShareLink.fromTracks(
          [tracks.first],
          kind: MusicShareKind.track,
          title: 'Before Dart handler',
        )!;
        final earlyActivation = await tester.runAsync(
          () => Process.run(Platform.resolvedExecutable, [
            earlyLink.uri.toString(),
          ]),
        );
        expect(earlyActivation!.exitCode, 0);
        await app.initializeMusicLinks([]);
        await tester.pumpAndSettle();
        expect(app.album!.tracks.single.id, tracks.first.id);
        for (final kind in MusicShareKind.values) {
          final selected = kind == MusicShareKind.track
              ? [tracks.last]
              : kind == MusicShareKind.album
              ? tracks.take(2).toList()
              : tracks;
          final link = MusicShareLink.fromTracks(
            selected,
            kind: kind,
            title: 'Native sharing',
          )!;
          final activation = await tester.runAsync(
            () =>
                Process.run(Platform.resolvedExecutable, [link.uri.toString()]),
          );
          expect(activation!.exitCode, 0);
          for (var i = 0; i < 30; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(app.error, isNull);
          expect(app.downloads.jobs, isEmpty);
          if (kind == MusicShareKind.release) {
            expect(app.playlist!.id, collection.id);
          } else {
            expect(
              app.album!.tracks.map((t) => t.torrentIndex),
              selected.map((t) => t.torrentIndex),
            );
          }
        }
        final report = File(
          '${testArtifacts().path}/music-sharing-native-windows.json',
        );
        await report.parent.create(recursive: true);
        await report.writeAsString(
          jsonEncode({
            'passed': true,
            'types': MusicShareKind.values.map((v) => v.name).toList(),
            'delivery':
                'second process -> WM_COPYDATA -> Dart -> offline collection',
            'downloads': app.downloads.jobs.length,
            'productionProfileUsed': false,
          }),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        await app?.shutdown();
        app?.library.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
