// Opt-in native check using a read-only selection of the existing library.
// No indexer credentials, torrent requests or production library writes.
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
import 'package:mumpa/ui/pages.dart';

class _OfflineMetadata extends MusicMetadataRepository {
  _OfflineMetadata(Directory root)
    : super(cache: DiskMediaCache(Directory(p.join(root.path, 'metadata'))));
  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets(
    'favorite one real discography album, restart and play cached song',
    (tester) async {
      if (!const bool.fromEnvironment('REAL_ALBUM_FAVORITES_TEST') ||
          !Platform.isWindows) {
        return;
      }
      final support = await getApplicationSupportDirectory();
      final profile =
          jsonDecode(
                await File(
                  p.join(support.path, 'Mumpa', 'library.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final collection = (profile['playlists'] as List)
          .map(
            (value) => MusicPlaylist.fromJson(Map<String, dynamic>.from(value)),
          )
          .firstWhere(
            (list) =>
                list.sourceHash != null &&
                list.name.toLowerCase().contains('ежемесячные') &&
                list.name.contains('72'),
          );
      final ids = collection.trackIds.toSet();
      final tracks = (profile['tracks'] as List)
          .map((value) => Track.fromJson(Map<String, dynamic>.from(value)))
          .where((track) => ids.contains(track.id))
          .toList();
      final albums = groupAlbums(tracks);
      final chosen = albums.firstWhere(
        (album) => album.tracks.any(
          (track) =>
              track.cachedPath != null && File(track.cachedPath!).existsSync(),
        ),
      );
      final root = await Directory.systemTemp.createTemp(
        'mumpa-real-album-like-',
      );
      final library = LibraryRepository(root);
      await library.load();
      final saved = await library.openSourceCollection(
        hash: collection.sourceHash!,
        name: collection.name,
        tracks: tracks,
      );
      await library.setSetting('autoCache', false);
      await library.setSetting('volume', 0.0);
      final torrents = TorrentService(
        endpoint: () async =>
            throw StateError('This check must use the existing offline audio'),
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
        torrents: torrents,
        downloads: DownloadRepository(library, torrents),
        engine: TorrentEngine(root),
        metadata: _OfflineMetadata(root),
      );
      final key = GlobalKey();
      try {
        app.openPlaylist(saved);
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MumpaApp(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        final scroll = find
            .descendant(
              of: find.byType(ContentPage),
              matching: find.byType(Scrollable),
            )
            .first;
        final heart = find.byKey(ValueKey('favorite-album-${chosen.id}'));
        await tester.scrollUntilVisible(heart, 240, scrollable: scroll);
        await tester.pumpAndSettle();
        expect(heart.hitTestable(), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(heart);
          await library.flush();
        });
        await tester.pumpAndSettle();
        expect(app.page, AppPage.playlist);
        expect(playback.queue, isEmpty);
        expect(library.isPlaylistLiked(saved.id), isFalse);
        expect(
          library.favoriteAlbums.single.tracks.map((track) => track.id).toSet(),
          chosen.tracks.map((track) => track.id).toSet(),
        );
        final restarted = LibraryRepository(root);
        await restarted.load();
        expect(restarted.isAlbumLiked(chosen), isTrue);
        expect(
          restarted.favoriteAlbums.single.tracks.length,
          chosen.tracks.length,
        );
        restarted.dispose();

        app.navigate(AppPage.liked);
        await tester.pumpAndSettle();
        expect(find.text('Любимые альбомы'), findsOneWidget);
        final card = find.byType(AlbumCard);
        await tester.ensureVisible(card);
        await tester.tap(
          find.descendant(of: card, matching: find.text(chosen.title)),
        );
        await tester.pumpAndSettle();
        expect(app.album!.tracks.length, chosen.tracks.length);
        expect(find.text('В любимом'), findsOneWidget);
        final cachedIndex = app.album!.tracks.indexWhere(
          (track) =>
              track.cachedPath != null && File(track.cachedPath!).existsSync(),
        );
        await tester.runAsync(() async {
          await app.playCollection(app.album!.tracks, index: cachedIndex);
        });
        await tester.pump(const Duration(seconds: 2));
        expect(playback.playing, isTrue);
        expect(playback.position.inMilliseconds, greaterThan(500));
        expect(playback.queue.length, chosen.tracks.length);
        expect(playback.error, isNull);
        await playback.pause();
        await tester.pumpAndSettle();
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'test-output/real-favorite-album-1.2.3.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        debugPrint(
          'MUMPA_ALBUM_FAVORITE: ${albums.length} source albums; '
          '${chosen.tracks.length} saved tracks; '
          '${playback.position.inMilliseconds} ms native cached playback; restart OK',
        );
        await library.toggleAlbumLike(app.album!);
        expect(library.favoriteAlbums, isEmpty);
        expect(library.tracks.length, tracks.length);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
