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
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/pages.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

const _trackOrder = ['zulu', 'middle', 'alpha'];
const _albumOrder = ['zulu', 'alpha', 'middle'];

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root, MockClient client)
    : super(
        cache: DiskMediaCache(Directory('${root.path}/metadata')),
        client: client,
      );

  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
  @override
  Future<String?> coverForGroup(String id) async => null;
  @override
  Future<String?> coverForReleaseTitle(String title) async => null;
}

class _Fixture {
  _Fixture(this.root, this.app, this.albums, this.playlists);
  final Directory root;
  final AppController app;
  final Map<String, Album> albums;
  final Map<String, MusicPlaylist> playlists;
  int httpRequests = 0;
  int engineRequests = 0;

  List<String> get playlistOrder => [
    playlists['delta']!.id,
    playlists['zephyr']!.id,
    playlists['atlas']!.id,
  ];
  List<String> get albumOrder =>
      _albumOrder.map((id) => albums[id]!.id).toList();

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'mumpa-favorites-order-ui-',
    );
    final library = LibraryRepository(root);
    await library.load();
    await library.setSetting('autoCache', false);
    final tracks = <Track>[];
    // Deliberately neither alphabetical nor the eventual favorite order.
    for (final (id, name, album) in [
      ('middle', 'Меридиан', 'Меридиан'),
      ('zulu', 'Зулу', 'Зенит'),
      ('alpha', 'Альфа', 'Альфа'),
    ]) {
      final audio = await File('${root.path}/$id.mp3').writeAsBytes([0]);
      tracks.add(
        Track(
          id: id,
          title: 'Сохранённый трек $name',
          artist: 'Группа порядка',
          album: 'Сохранённый $album',
          source: TrackSource.local,
          localPath: audio.path,
        ),
      );
    }
    await library.upsert(tracks);
    final albums = {
      for (final track in tracks) track.id: Album([track]),
    };
    final zephyr = await library.openSourceCollection(
      hash: 'isolated-order-source',
      name: 'Сохранённый архив Зефир',
      tracks: [tracks[0]],
    );
    final atlas = await library.createPlaylist('Сохранённый плейлист Атлас');
    await library.addToPlaylist(atlas.id, ['alpha']);
    final delta = await library.createPlaylist('Сохранённый плейлист Дельта');
    await library.addToPlaylist(delta.id, ['zulu']);
    for (final id in ['alpha', 'middle', 'zulu']) {
      await library.toggleLike(id);
    }
    for (final id in ['middle', 'alpha', 'zulu']) {
      await library.toggleAlbumLike(albums[id]!);
    }
    for (final playlist in [atlas, zephyr, delta]) {
      await library.togglePlaylistLike(playlist.id);
    }
    late _Fixture fixture;
    MockClient offlineClient() => MockClient((_) async {
      fixture.httpRequests++;
      throw StateError('Favorite sorting must not send HTTP');
    });
    final torrents = TorrentService(
      client: offlineClient(),
      endpoint: () async {
        fixture.engineRequests++;
        throw StateError('Favorite sorting must not start an engine');
      },
    );
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    await playback.initialize(platformAudio: false);
    final app = AppController(
      library: library,
      playback: playback,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
      indexer: IndexerService(client: offlineClient()),
      metadata: _Metadata(root, offlineClient()),
    );
    fixture = _Fixture(root, app, albums, {
      'zephyr': zephyr,
      'atlas': atlas,
      'delta': delta,
    });
    app.navigate(AppPage.liked);
    return fixture;
  }
}

Finder _album(String id) => find.byWidgetPredicate(
  (widget) => widget is AlbumCard && widget.album.id == id,
);
Finder _playlist(String id) => find.byKey(ValueKey('favorite-playlist-$id'));
Finder _row(String id) => find.byKey(ValueKey('track-row-$id'));
Finder _scroll() => find
    .descendant(of: find.byType(ContentPage), matching: find.byType(Scrollable))
    .first;

Future<void> _show(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 180, scrollable: _scroll());
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _top(WidgetTester tester) async {
  tester.state<ScrollableState>(_scroll()).position.jumpTo(0);
  await tester.pumpAndSettle();
}

/// Check physical reading order, including grids where several cards share a row.
void _expectReadingOrder(WidgetTester tester, List<Finder> items) {
  final rectangles = items.map(tester.getRect).toList();
  for (var index = 1; index < rectangles.length; index++) {
    final previous = rectangles[index - 1];
    final next = rectangles[index];
    expect(
      next.top > previous.top + .1 ||
          ((next.top - previous.top).abs() < .1 && next.left > previous.left),
      isTrue,
      reason: 'Newest favorites must precede older ones in the actual layout',
    );
  }
}

Future<void> _expectFavoriteLayout(
  WidgetTester tester,
  _Fixture fixture,
) async {
  await _show(tester, _album(fixture.albumOrder.last));
  expect(
    tester
        .widgetList<AlbumCard>(find.byType(AlbumCard))
        .map((card) => card.album.id),
    fixture.albumOrder,
  );
  _expectReadingOrder(tester, fixture.albumOrder.map(_album).toList());
  await _show(tester, _playlist(fixture.playlistOrder.last));
  expect(
    tester
        .widgetList<PlaylistFavoriteButton>(find.byType(PlaylistFavoriteButton))
        .map((button) => button.playlistId),
    fixture.playlistOrder,
  );
  _expectReadingOrder(tester, fixture.playlistOrder.map(_playlist).toList());
  await _show(tester, _row(_trackOrder.last));
  expect(
    tester
        .widget<TrackList>(find.byType(TrackList))
        .tracks
        .map((track) => track.id),
    _trackOrder,
  );
  _expectReadingOrder(tester, _trackOrder.map(_row).toList());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'newest favorites lead cards, search and playback at $width px',
      (tester) async {
        final fixture = (await tester.runAsync(_Fixture.create))!;
        final app = fixture.app;
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await app.shutdown();
            app.library.dispose();
            await fixture.root.delete(recursive: true);
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
        expect(app.library.tracks.map((track) => track.id), [
          'middle',
          'zulu',
          'alpha',
        ]);
        expect(app.likedTracks.map((track) => track.id), _trackOrder);
        expect(
          app.library.favoriteAlbums.map((album) => album.id),
          fixture.albumOrder,
        );
        expect(
          app.library.favoritePlaylists.map((playlist) => playlist.id),
          fixture.playlistOrder,
        );
        expect(
          app.library.favoritePlaylists[1].sourceHash,
          isNotNull,
          reason:
              'Source collections share the same favorite timeline as playlists',
        );
        await _expectFavoriteLayout(tester, fixture);

        await _top(tester);
        final search = find.byKey(const ValueKey('local-search-liked'));
        await tester.enterText(search, 'сохраненный');
        await tester.pumpAndSettle();
        expect(app.page, AppPage.liked);
        expect(app.query, isEmpty);
        expect(
          app.likedSearchResults.tracks.map((track) => track.id),
          _trackOrder,
        );
        expect(
          app.likedSearchResults.albums.map((album) => album.id),
          fixture.albumOrder,
        );
        expect(
          app.likedSearchResults.playlists.map((playlist) => playlist.id),
          fixture.playlistOrder,
        );
        await _expectFavoriteLayout(tester, fixture);

        await _top(tester);
        await tester.tap(
          find.byKey(const ValueKey('local-search-liked-clear')),
        );
        await tester.pumpAndSettle();
        expect(app.localQuery('liked'), isEmpty);
        final play = find.text('Слушать');
        await _show(tester, play);
        await tester.runAsync(() async {
          await tester.tap(play);
          for (
            var attempt = 0;
            attempt < 50 && !app.playback.playing;
            attempt++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await app.library.flush();
        });
        // The current track equalizer animates while playing.
        await tester.pump(const Duration(milliseconds: 150));
        expect(app.playback.playing, isTrue);
        expect(app.playback.queue.map((track) => track.id), _trackOrder);
        expect(app.playback.current!.id, _trackOrder.first);
        expect(fixture.httpRequests, 0);
        expect(fixture.engineRequests, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
