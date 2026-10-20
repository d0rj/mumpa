import 'package:mumpa/logic/audio_runtime.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:mumpa/data/deezer_artwork_repository.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/torrent_metainfo.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/data/torrent_artwork_repository.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/components.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  initializeAudioRuntime();
  testWidgets(
    'real Ежемесячные album covers and native mouse Back',
    (tester) async {
      if (!const bool.fromEnvironment('REAL_ARTWORK_TEST') ||
          !Platform.isWindows) {
        return;
      }
      final support = await getApplicationSupportDirectory();
      final source = Directory(p.join(support.path, 'Mumpa'));
      final sourceLibrary = File(p.join(source.path, 'library.json'));
      final originalLibrary = await sourceLibrary.readAsString();
      final existing = jsonDecode(originalLibrary) as Map;
      final root = await Directory.systemTemp.createTemp('mumpa-real-artwork-');
      await File(p.join(root.path, 'library.json')).writeAsString(
        jsonEncode({
          'tracks': existing['tracks'],
          'playlists': existing['playlists'],
          'liked': existing['liked'],
          'likedPlaylists': existing['likedPlaylists'],
          'settings': {'volume': 0.0, 'autoCache': false},
        }),
      );
      final library = LibraryRepository(root);
      await library.load();
      final collection = library.playlists.firstWhere(
        (c) =>
            c.sourceHash != null &&
            c.name.toLowerCase().contains('ежемесячные') &&
            c.name.contains('72'),
      );
      final directory = Directory(p.join(root.path, 'torrents'));
      await directory.create();
      final hash = collection.sourceHash!;
      await File(
        p.join(source.path, 'torrents', '${stableId(hash)}.torrent'),
      ).copy(p.join(directory.path, '${stableId(hash)}.torrent'));
      final engine = TorrentEngine(
        root,
        binaryDirectory: Directory(p.join(source.path, 'runtime')),
        networkInterface: () =>
            (existing['settings'] as Map)['torrentInterface'] as String?,
      );
      final torrents = TorrentService(
        sources: directory,
        endpoint: engine.start,
      );
      final playback = PlaybackController(
        library: library,
        torrents: torrents,
        backend: NativeAudioBackend(),
      );
      await playback.initialize(platformAudio: false);
      // Run with the previous production instance closed. Warm only its artwork
      // cache, so the verified images are immediately available in the release.
      final metadata = MusicMetadataRepository(
        cache: DiskMediaCache(
          Directory(p.join(source.path, 'metadata')),
          maxBytes:
              (((existing['settings'] as Map)['metadataCacheMb'] as num?)
                      ?.toInt() ??
                  256) *
              1024 *
              1024,
        ),
      );
      final app = AppController(
        library: library,
        playback: playback,
        torrents: torrents,
        downloads: DownloadRepository(library, torrents),
        engine: engine,
        metadata: metadata,
      );
      final key = GlobalKey();
      try {
        // Show the collection before any public-network artwork probes. The
        // test window must behave like the app: covers fill in asynchronously.
        app.openPlaylist(collection);
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MumpaApp(controller: app),
          ),
        );
        await tester.pump();
        final tracks = collection.trackIds
            .map(library.byId)
            .whereType<Track>()
            .toList();
        final albums = groupAlbums(tracks);
        expect(albums.length, 72);
        final metainfo = readTorrentMetainfo(
          await File(
            p.join(directory.path, '${stableId(hash)}.torrent'),
          ).readAsBytes(),
        );
        expect(
          albums
              .where(
                (album) =>
                    selectTorrentArtwork(metainfo, album.tracks.first) != null,
              )
              .length,
          72,
          reason: 'Every album has a correctly resolved physical cover file',
        );
        // Exercise the same cover pipeline as the real album cards, using the
        // user's collection. A second pass rechecks transient network misses
        // against the already running swarm and the persistent cover cache.
        final results = await tester.runAsync(() async {
          final results = <String, int>{};
          for (var pass = 0; pass < 2; pass++) {
            await Future.wait(
              albums.where((album) => !results.containsKey(album.title)).map((
                album,
              ) async {
                final path = await app.loadTrackArtwork(album.tracks.first);
                if (path == null) return;
                final bytes = await File(path).readAsBytes();
                final codec = await ui.instantiateImageCodec(bytes);
                final frame = await codec.getNextFrame();
                expect(frame.image.width, greaterThan(20));
                frame.image.dispose();
                codec.dispose();
                results[album.title] = bytes.length;
              }),
            );
            debugPrint('MUMPA_ARTWORK_PASS ${pass + 1}: ${results.length}/72');
            if (results.length == albums.length) break;
          }
          await File(
            'test-output/artwork-cover-progress-1.2.2.json',
          ).writeAsString(
            jsonEncode({
              'decoded': results,
              'missing': albums
                  .where((album) => !results.containsKey(album.title))
                  .map((album) => album.title)
                  .toList(),
            }),
          );
          return results;
        });
        expect(
          results!.length,
          albums.length,
          reason:
              'Every real album cover in this saved discography must decode',
        );
        await tester.runAsync(() async {
          final offlineTorrents = TorrentService(
            sources: directory,
            endpoint: () async =>
                throw StateError('Cached cover must not start an engine'),
          );
          final restarted = TorrentArtworkRepository(
            torrents: offlineTorrents,
            cache: DiskMediaCache(Directory(p.join(source.path, 'metadata'))),
            clientFactory: () =>
                throw StateError('Cached cover must not use HTTP'),
          );
          try {
            Track? cachedTrack;
            for (final album in albums) {
              if (await restarted.cachedCover(album.tracks.first) != null) {
                cachedTrack = album.tracks.first;
                break;
              }
            }
            expect(cachedTrack, isNotNull);
            expect(await restarted.load(cachedTrack!), isNotNull);
          } finally {
            restarted.dispose();
            offlineTorrents.dispose();
          }
        });
        await tester.pumpAndSettle();
        final scrollable = find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.byType(AlbumCard).first,
          160,
          scrollable: scrollable,
        );
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsWidgets);
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'test-output/real-discography-covers-1.2.2.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        final before = app.navigationEntryId;
        final selected =
            (tester.widget(find.byType(AlbumCard).first) as AlbumCard).album;
        app.openAlbum(selected, playlistId: collection.id);
        await tester.pumpAndSettle();
        expect(app.page, AppPage.album);
        // LiveTestWidgetsFlutterBinding drops real device input by default.
        // Allow it only while delivering an XBUTTON message to this owned view.
        binding.shouldPropagateDevicePointerEvents = true;
        final native = await tester.runAsync(
          () => Process.run(
            Platform.environment['MUMPA_TEST_PYTHON'] ?? 'python',
            ['tools/probe-mouse-back.py', '$pid'],
          ),
        );
        expect(
          native!.exitCode,
          0,
          reason: '${native.stdout} ${native.stderr}',
        );
        for (var i = 0; i < 20 && app.page != AppPage.playlist; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(app.page, AppPage.playlist);
        expect(app.selectedPlaylist, collection.id);
        expect(app.navigationEntryId, before);
        binding.shouldPropagateDevicePointerEvents = false;
        await tester.pumpAndSettle();
        // Also prove the external fallback for two actual artist releases.
        final fallback = await tester.runAsync(() async {
          final result = <String, int>{};
          final client = http.Client();
          final repo = DeezerArtworkRepository(
            cache: metadata.cache,
            client: client,
          );
          try {
            for (final title in ['Родничок', 'Призраки Фантьета']) {
              final path = await repo.cover(
                'Ежемесячные',
                title,
                metadata.cache.generation,
              );
              expect(path, isNotNull);
              final bytes = await File(path!).readAsBytes();
              final codec = await ui.instantiateImageCodec(bytes);
              final frame = await codec.getNextFrame();
              expect(frame.image.width, greaterThan(20));
              frame.image.dispose();
              codec.dispose();
              result[title] = bytes.length;
            }
          } finally {
            repo.dispose();
            client.close();
          }
          return result;
        });
        final stats = await metadata.cache.stats();
        expect(await sourceLibrary.readAsString(), originalLibrary);
        final evidence = {
          'version': '1.2.2',
          'collectionTracks': tracks.length,
          'collectionAlbums': albums.length,
          'selectedPhysicalCovers': 72,
          'decodedAlbumCovers': results.length,
          'coverBytes': results,
          'unavailableCovers': albums
              .where((album) => !results.containsKey(album.title))
              .map((album) => album.title)
              .toList(),
          'externalCovers': fallback,
          'nativeMouseBack': true,
          'playlistContextRestored': true,
          'cacheBytes': stats.bytes,
          'cacheEntries': stats.count,
          'offlineCoverCacheRestart': true,
          'sourceLibraryWasNotWritten': true,
          'warmedUserArtworkCache': true,
        };
        await File(
          'test-output/artwork-navigation-1.2.2.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
        debugPrint('MUMPA_ARTWORK ${jsonEncode(evidence)}');
      } finally {
        binding.shouldPropagateDevicePointerEvents = false;
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
