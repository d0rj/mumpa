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

// Test collection layout without starting hundreds of unrelated cover requests.
// Actual matching and persistent artwork are checked separately below.
class _NoBackgroundCovers extends MusicMetadataRepository {
  _NoBackgroundCovers(Directory root)
    : super(cache: DiskMediaCache(Directory(p.join(root.path, 'metadata'))));
  @override
  Future<String?> coverForAlbum(String artistName, String albumTitle) async =>
      null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'existing discography migration, filter and native cached playback',
    (tester) async {
      if (!const bool.fromEnvironment('REAL_COLLECTION_TEST') ||
          !Platform.isWindows) {
        return;
      }
      final sourceFile = File(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'Mumpa',
          'library.json',
        ),
      );
      final existing = jsonDecode(await sourceFile.readAsString()) as Map;
      final root = await Directory.systemTemp.createTemp(
        'mumpa-collection-proof-',
      );
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
      final torrents = TorrentService(
        endpoint: () async => throw StateError('Offline proof'),
      );
      final playback = PlaybackController(
        library: library,
        torrents: torrents,
        backend: NativeAudioBackend(),
      );
      await playback.initialize(platformAudio: false);
      final app = AppController(
        library: library,
        playback: playback,
        downloads: DownloadRepository(library, torrents),
        torrents: torrents,
        engine: TorrentEngine(root),
        metadata: _NoBackgroundCovers(root),
      );
      final key = GlobalKey();
      Future<void> preview(String name) async {
        await tester.pump(const Duration(milliseconds: 250));
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'test-output/$name-1.2.1.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      try {
        final originalIds = (existing['tracks'] as List)
            .map((t) => (t as Map)['id'])
            .toSet();
        expect(library.tracks.map((t) => t.id).toSet(), originalIds);
        expect(library.liked, (existing['liked'] as List).toSet());
        final collection = library.playlists.firstWhere(
          (c) =>
              c.sourceHash != null &&
              c.name.toLowerCase().contains('ежемесячные') &&
              c.name.contains('72'),
        );
        app.openPlaylist(collection);
        final tracks = app.playlistTracks;
        final albums = groupAlbums(tracks);
        expect(tracks.length, 493);
        expect(albums.length, 72);
        final selected = tracks.firstWhere(
          (t) =>
              t.title.toLowerCase().contains('роженица в метро') && t.offline,
        );
        expect(selected.album.toLowerCase(), contains('мультивселенная'));
        expect(selected.albumSource, TrackAlbumSource.tags);
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MumpaApp(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        final scrollable = find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.byType(AlbumCard).first,
          180,
          scrollable: scrollable,
        );
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(find.byType(AlbumCard), findsWidgets);
        await preview('collection-albums');
        final firstCard = find.byType(AlbumCard).first;
        await tester.tap(firstCard);
        await tester.pumpAndSettle();
        expect(app.page, AppPage.album);
        expect(app.album!.tracks.length, lessThan(tracks.length));
        expect(
          app.album!.tracks.every((t) => collection.trackIds.contains(t.id)),
          isTrue,
        );
        app.openPlaylist(collection);
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('collection-search'));
        await tester.scrollUntilVisible(field, 160, scrollable: scrollable);
        await tester.enterText(field, 'роженица метро');
        await tester.pumpAndSettle();
        final row = find.byKey(ValueKey('track-row-${selected.id}'));
        expect(row, findsOneWidget);
        await tester.scrollUntilVisible(row, 150, scrollable: scrollable);
        await tester.tap(row);
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (app.playback.position.inMilliseconds < 2500 &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(app.playback.error, isNull);
        expect(app.playback.playing, isTrue);
        expect(app.playback.current!.id, selected.id);
        expect(app.playback.queue.map((t) => t.id), tracks.map((t) => t.id));
        expect(app.playback.contextPlaylistId, collection.id);
        expect(
          app.playback.position.inMilliseconds,
          greaterThanOrEqualTo(2500),
        );
        expect(tester.takeException(), isNull);
        await preview('collection-filter');
        await app.playback.pause();
        final metadata = MusicMetadataRepository(
          cache: DiskMediaCache(Directory(p.join(root.path, 'cover-proof'))),
        );
        final cover = await metadata.coverForAlbum('Daft Punk', 'Discovery');
        expect(cover, isNotNull);
        expect(await File(cover!).exists(), isTrue);
        final reused = await metadata.coverForAlbum('Daft Punk', 'Discovery');
        expect(reused, cover);
        final coverBytes = await File(cover).length();
        metadata.dispose();
        final evidence = {
          'version': '1.2.1',
          'collectionTracks': tracks.length,
          'collectionAlbums': albums.length,
          'favoriteIdsPreserved': true,
          'trackIdsPreserved': true,
          'favoriteTrack': selected.title,
          'albumFromTags': selected.album,
          'nativeCachedPlayback': true,
          'positionMs': playback.position.inMilliseconds,
          'durationMs': playback.duration.inMilliseconds,
          'filteredQueueContainsFullCollection':
              playback.queue.length == tracks.length,
          'coverBytes': coverBytes,
          'coverReused': reused == cover,
          'sourceProfileWasNotWritten': true,
        };
        await File(
          'test-output/collection-1.2.1.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
        debugPrint('MUMPA_COLLECTION ${jsonEncode(evidence)}');
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
