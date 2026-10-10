import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/pages.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(cache: DiskMediaCache(Directory('${root.path}/metadata')));
  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'save, open, play and unlike a discography album at $width px',
      (tester) async {
        late Directory root;
        late AppController app;
        late MusicPlaylist collection;
        late Album first;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('mumpa-album-ui-');
          final library = LibraryRepository(root);
          await library.load();
          final audio = await File('${root.path}/cached.mp3').writeAsBytes([0]);
          final tracks = [
            for (final (id, album, number) in [
              ('one', 'First album', 1),
              ('two', 'First album', 2),
              ('other', 'Second album', 1),
            ])
              Track(
                id: id,
                title: 'Song $id',
                artist: 'Band',
                album: album,
                source: TrackSource.torrent,
                torrentHash: 'source',
                torrentPath: 'Root/$album/$number.mp3',
                torrentAlbumPath: album,
                albumSource: TrackAlbumSource.directory,
                cachedPath: audio.path,
                number: number,
              ),
          ];
          collection = await library.openSourceCollection(
            hash: 'source',
            name: 'Discography',
            tracks: tracks,
          );
          first = groupAlbums(tracks).first;
          final torrents = TorrentService(
            endpoint: () async => 'http://localhost',
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
            metadata: _Metadata(root),
          );
          app.openPlaylist(collection);
        });
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await app.shutdown();
            app.library.dispose();
            await root.delete(recursive: true);
          });
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: mumpaTheme(),
            home: Scaffold(
              body: ListenableBuilder(
                listenable: app,
                builder: (_, _) => ContentPage(app: app),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final heart = find.byKey(ValueKey('favorite-album-${first.id}'));
        await tester.ensureVisible(heart);
        await tester.runAsync(() async {
          await tester.tap(heart);
          await app.library.flush();
        });
        await tester.pumpAndSettle();
        expect(app.page, AppPage.playlist);
        expect(app.playback.queue, isEmpty);
        expect(app.library.isPlaylistLiked(collection.id), isFalse);
        expect(app.library.liked, isEmpty);
        expect(
          app.library.favoriteAlbums.single.tracks.map((track) => track.id),
          ['one', 'two'],
        );
        expect(tester.takeException(), isNull);

        app.navigate(AppPage.liked);
        await tester.pumpAndSettle();
        expect(find.text('Любимые альбомы'), findsOneWidget);
        expect(find.text('Second album'), findsNothing);
        final card = find.byType(AlbumCard);
        await tester.ensureVisible(card);
        await tester.tap(find.text('First album'));
        await tester.pumpAndSettle();
        expect(app.page, AppPage.album);
        expect(app.album!.tracks.map((track) => track.id), ['one', 'two']);
        expect(find.text('В любимом'), findsOneWidget);
        final play = find.byKey(const Key('play-album'));
        await tester.ensureVisible(play);
        await tester.runAsync(() async {
          await tester.tap(play);
          for (var i = 0; i < 30 && !app.playback.playing; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump(const Duration(milliseconds: 100));
        expect(app.playback.playing, isTrue);
        expect(app.playback.queue.map((track) => track.id), ['one', 'two']);
        await tester.ensureVisible(heart);
        await tester.runAsync(() async {
          await tester.tap(heart);
          await app.library.flush();
        });
        await tester.pump(const Duration(milliseconds: 100));
        expect(app.library.favoriteAlbums, isEmpty);
        expect(app.library.tracks, hasLength(3));
        expect(app.library.playlists.single.trackIds, ['one', 'two', 'other']);
        app.navigate(AppPage.liked);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Любимые альбомы'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
