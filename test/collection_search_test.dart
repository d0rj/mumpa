import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/catalog_widgets.dart';
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/pages.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(cache: DiskMediaCache(Directory('${root.path}/metadata')));
  @override
  Future<String?> cachedCoverForAlbum(
    String artistName,
    String albumTitle,
  ) async => null;
  @override
  Future<String?> coverForAlbum(String artistName, String albumTitle) async =>
      null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'collection filter preserves full queue and state at $width px',
      (tester) async {
        late Directory root;
        late AppController app;
        late MusicPlaylist playlist;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp(
            'mumpa-collection-search-',
          );
          final library = LibraryRepository(root);
          await library.load();
          final file = await File('${root.path}/song.mp3').writeAsBytes([0]);
          await library.upsert([
            for (final (id, title, album) in [
              ('one', 'Первый', 'First album'),
              ('two', 'Ёлки зелёные', 'First album'),
              ('three', 'Третий', 'Second album'),
            ])
              Track(
                id: id,
                title: title,
                artist: 'Band',
                album: album,
                source: TrackSource.local,
                localPath: file.path,
              ),
          ]);
          playlist = await library.createPlaylist('My playlist');
          await library.addToPlaylist(playlist.id, ['one', 'two', 'three']);
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
          app.openPlaylist(playlist);
          app.query = 'global query';
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
        final field = find.byKey(const ValueKey('collection-search'));
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.enterText(field, 'елки band');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('track-row-two')), findsOneWidget);
        expect(find.byKey(const ValueKey('track-row-one')), findsNothing);
        expect(app.query, 'global query');
        await tester.runAsync(() async {
          await app.library.toggleLike('one');
        });
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, 'елки band');
        await tester.ensureVisible(find.byKey(const ValueKey('track-row-two')));
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('track-title-two')));
          for (var i = 0; i < 30 && !app.playback.playing; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump(const Duration(milliseconds: 100));
        expect(app.playback.queue.map((track) => track.id), [
          'one',
          'two',
          'three',
        ]);
        expect(app.playback.current!.id, 'two');
        expect(app.playback.contextPlaylistId, playlist.id);
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.enterText(field, 'missing track');
        await tester.pumpAndSettle();
        expect(find.text('Ничего не найдено'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('collection-search-clear')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'discography defaults to albums and opens only its collection subset',
    (tester) async {
      late Directory root;
      late AppController app;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('mumpa-album-collection-');
        final library = LibraryRepository(root);
        await library.load();
        final tracks = [
          for (final (id, album) in [
            ('a', 'First album'),
            ('b', 'First album'),
            ('c', 'Second album'),
          ])
            Track(
              id: id,
              title: 'Song $id',
              artist: 'Band',
              album: album,
              source: TrackSource.local,
            ),
        ];
        final collection = await library.openSourceCollection(
          hash: 'fixture',
          name: 'Band discography',
          tracks: tracks,
        );
        await library.upsert([
          const Track(
            id: 'outside',
            title: 'Another copy',
            artist: 'Band',
            album: 'First album',
            source: TrackSource.local,
          ),
        ]);
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
      await tester.scrollUntilVisible(
        find.byType(AlbumCard).first,
        160,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Альбомы · 2'), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      final firstCard = find.byType(AlbumCard).first;
      await tester.tap(firstCard);
      await tester.pumpAndSettle();
      expect(app.page, AppPage.album);
      expect(app.album!.tracks.map((track) => track.id), ['a', 'b']);
      await tester.runAsync(() async {
        await app.library.upsert([
          for (final track in app.album!.tracks)
            track.copyWith(album: 'Tagged album'),
        ]);
      });
      await tester.pumpAndSettle();
      expect(app.album!.title, 'Tagged album');
      expect(app.album!.tracks.map((track) => track.id), ['a', 'b']);
      expect(find.byKey(const ValueKey('collection-search')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source, search mode and version format live in the search options section',
    (tester) async {
      late Directory root;
      late AppController app;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('mumpa-search-options-');
        final library = LibraryRepository(root);
        await library.load();
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
      });
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
            body: SingleChildScrollView(child: SearchOptionsPanel(app: app)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-tracks-mode')), findsNothing);
      await tester.tap(find.text('Настройки поиска'));
      await tester.pumpAndSettle();
      expect(find.text('Где искать'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('search-tracks-mode')));
      await tester.pumpAndSettle();
      expect(app.trackSearchMode, isTrue);
      app.trackVariants = [
        for (final format in ['mp3', 'flac'])
          TrackVariant(
            release: const SearchRelease(
              title: 'Band - Album',
              link: 'https://example.test/file.torrent',
            ),
            track: Track(
              id: format,
              title: 'Song',
              artist: 'Band',
              album: 'Album',
              source: TrackSource.local,
              localPath: 'song.$format',
            ),
            info: const TorrentInfo(hash: 'test', title: 'Album', files: []),
            source: 'file',
            edition: '',
          ),
      ];
      app.setVersionFormat(null);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('search-format-FLAC')),
      );
      await tester.tap(find.byKey(const ValueKey('search-format-FLAC')));
      await tester.pumpAndSettle();
      expect(app.visibleTrackVariants.map((variant) => variant.format), [
        'FLAC',
      ]);
      await tester.tap(find.text('Настройки поиска'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-format-FLAC')), findsNothing);
      expect(find.textContaining('Треки · FLAC'), findsOneWidget);
    },
  );
}
