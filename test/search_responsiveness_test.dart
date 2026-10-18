import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/pages.dart';

import 'support.dart';

class _QuietMetadata extends MusicMetadataRepository {
  _QuietMetadata(Directory root)
    : super(
        cache: DiskMediaCache(Directory('${root.path}/metadata')),
        client: MockClient((_) => throw StateError('No HTTP expected')),
      );
  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

class _CountedLibrary extends LibraryRepository {
  _CountedLibrary(super.root);
  int lookups = 0;
  @override
  Track? byId(String id) {
    lookups++;
    return super.byId(id);
  }
}

void runSearchResponsivenessTests({bool real = false}) {
  testWidgets(
    'large library input stays responsive and progress does not rebuild rows',
    (tester) async {
      late Directory root;
      late AppController app;
      late _CountedLibrary library;
      late FakeAudioBackend backend;
      late Track audio;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('mumpa-ui-perf-');
        library = _CountedLibrary(root);
        await library.load();
        await library.setSetting('searchProvider', 'torznab');
        final tracks = <Track>[];
        if (real) {
          final saved =
              jsonDecode(
                    await File(
                      '${Platform.environment['APPDATA']}/app.mumpa/mumpa/Mumpa/library.json',
                    ).readAsString(),
                  )
                  as Map<String, dynamic>;
          tracks.addAll(
            (saved['tracks'] as List).map(
              (value) =>
                  Track.fromJson(Map<String, dynamic>.from(value as Map)),
            ),
          );
        } else {
          tracks.addAll(
            List.generate(
              10000,
              (i) => Track(
                id: 'track-$i',
                title: 'Песня $i',
                artist: 'Ежемесячные',
                album: 'Альбом ${i ~/ 20}',
                source: TrackSource.local,
              ),
            ),
          );
        }
        final file = await File('${root.path}/audio.mp3').writeAsBytes([0]);
        audio = Track(
          id: 'perf-audio',
          title: 'Песня',
          artist: 'Ежемесячные',
          album: 'Fixture',
          source: TrackSource.local,
          localPath: file.path,
        );
        await library.upsert([...tracks, audio]);
        final torrents = TorrentService(
          endpoint: () async => throw StateError('No engine expected'),
        );
        backend = FakeAudioBackend();
        final playback = PlaybackController(
          library: library,
          torrents: torrents,
          backend: backend,
        );
        await playback.initialize(platformAudio: false);
        app = AppController(
          library: library,
          playback: playback,
          downloads: DownloadRepository(library, torrents),
          torrents: torrents,
          engine: TorrentEngine(root),
          metadata: _QuietMetadata(root),
        );
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await app.shutdown();
          library.dispose();
          await root.delete(recursive: true);
        });
      });
      await tester.pumpWidget(MumpaApp(controller: app));
      await tester.pumpAndSettle();
      final timings = <int>[];
      for (var i = 1; i <= 'Ежемесячные'.length; i++) {
        final watch = Stopwatch()..start();
        await tester.enterText(
          find.byKey(const ValueKey('music-search')),
          'Ежемесячные'.substring(0, i),
        );
        await tester.pump();
        timings.add(watch.elapsedMicroseconds);
        expect(app.query, 'Ежемесячные'.substring(0, i));
        expect(app.searchTracks, contains(audio));
      }
      await tester.scrollUntilVisible(
        find.byType(TrackList),
        150,
        scrollable: find
            .descendant(
              of: find.byType(ContentPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.byType(TrackList), findsOneWidget);
      expect(
        find.byKey(const ValueKey('track-row-perf-audio')),
        findsNothing,
        reason: 'A 10k list must build only rows near its visible viewport.',
      );
      expect(tester.takeException(), isNull);
      // Isolate a visible TrackList from the player bar, which legitimately
      // resolves the current ID for each seek/position update.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [TrackList(app: app, tracks: library.tracks)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => app.playback.playTracks([audio]));
      await tester.pump();
      library.lookups = 0;
      var transportChanges = 0;
      void changed() => transportChanges++;
      app.playback.trackState.addListener(changed);
      for (var i = 1; i <= 10; i++) {
        await backend.seek(Duration(milliseconds: i * 100));
        await tester.pump();
      }
      expect(
        library.lookups,
        lessThanOrEqualTo(120),
        reason: 'Position ticks must not build track rows.',
      );
      app.playback.trackState.removeListener(changed);
      expect(transportChanges, 0);
      // ignore: avoid_print
      print(
        'INPUT_PERF tracks=${library.tracks.length} edit_and_frame_us=$timings '
        'ten_position_lookup_count=${library.lookups}',
      );
    },
  );
}

void main() => runSearchResponsivenessTests();
