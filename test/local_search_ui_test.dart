import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/pages.dart';

import 'support.dart';

const _globalQuery = 'Глобальный запрос';
const _north = 'Северная группа';
const _polar = 'Полярный альбом';

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(cache: DiskMediaCache(Directory('${root.path}/metadata')));

  int artistRequests = 0;
  int recordingRequests = 0;
  List<MusicReleaseGroup> albums = const [];

  @override
  Future<String?> cachedCoverForAlbum(
    String artistName,
    String albumTitle,
  ) async => null;

  @override
  Future<String?> coverForAlbum(String artistName, String albumTitle) async =>
      null;

  @override
  Future<String?> coverForGroup(String id) async => null;

  @override
  Future<String?> coverForReleaseTitle(String title) async => null;

  @override
  Future<List<MusicRecording>> searchRecordings(
    String query, {
    SourceOperation? operation,
  }) async {
    recordingRequests++;
    return const [];
  }

  @override
  Future<MusicArtist?> artist(String name, {SourceOperation? operation}) async {
    artistRequests++;
    return MusicArtist(
      id: stableId(name),
      name: name,
      type: 'Group',
      albums: albums,
    );
  }
}

class _Requests {
  int indexer = 0;
}

class _Fixture {
  _Fixture(
    this.root,
    this.app,
    this.metadata,
    this.requests,
    this.playlist,
    this.collection,
    this.hiddenPlaylist,
  );

  final Directory root;
  final AppController app;
  final _Metadata metadata;
  final _Requests requests;
  final MusicPlaylist playlist, collection, hiddenPlaylist;

  Track track(String id) => app.library.byId(id)!;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'mumpa-local-search-ui-',
    );
    final library = LibraryRepository(root);
    await library.load();
    final audio = await File('${root.path}/fixture.mp3').writeAsBytes([0]);
    Track song(
      String id,
      String title,
      String artist,
      String album, {
      bool downloaded = false,
      bool local = false,
      int number = 1,
    }) => Track(
      id: id,
      title: title,
      artist: artist,
      album: album,
      source: local ? TrackSource.local : TrackSource.torrent,
      localPath: local ? audio.path : null,
      cachedPath: downloaded ? audio.path : null,
      torrentPath: local ? null : '$album/$title.mp3',
      number: number,
    );
    await library.upsert([
      song('north-one', 'Лунная дорога', _north, _polar, downloaded: true),
      song('north-two', 'Ёлки зелёные', _north, _polar, local: true, number: 2),
      song('north-other', 'Нелюбимая песня', _north, 'Другой северный альбом'),
      song(
        'road',
        'Дорожный сигнал',
        'Южная группа',
        'Дорожный альбом',
        downloaded: true,
      ),
      song(
        'road-outside',
        'Поздняя версия сигнала',
        'Южная группа',
        'Дорожный альбом',
        number: 2,
      ),
      song(
        'collection',
        'Коллекционный мотив',
        'Западная группа',
        'Архивный альбом',
        downloaded: true,
      ),
      song(
        'collection-outside',
        'Чужая версия мотива',
        'Западная группа',
        'Архивный альбом',
        number: 2,
      ),
      song(
        'individual',
        'Отдельная любовь',
        'Восточная группа',
        'Одиночный альбом',
        downloaded: true,
      ),
      song(
        'unrelated',
        'Совсем чужая песня',
        'Чужая группа',
        'Чужой альбом',
        downloaded: true,
      ),
    ]);
    await library.toggleAlbumLike(
      Album([library.byId('north-one')!, library.byId('north-two')!]),
    );
    // Favorite album membership stays the two saved files, even when another
    // copy with the same album key is imported later.
    await library.upsert([
      song('north-late', 'Поздняя копия', _north, _polar, number: 3),
    ]);
    final playlist = await library.createPlaylist('Любимый дорожный плейлист');
    await library.addToPlaylist(playlist.id, ['road', 'individual']);
    await library.togglePlaylistLike(playlist.id);
    final collection = await library.openSourceCollection(
      hash: 'local-search-fixture-source',
      name: 'Любимая архивная коллекция',
      tracks: [library.byId('collection')!],
    );
    await library.togglePlaylistLike(collection.id);
    final hiddenPlaylist = await library.createPlaylist('Нелюбимый плейлист');
    await library.addToPlaylist(hiddenPlaylist.id, [
      'north-other',
      'unrelated',
    ]);
    await library.toggleLike('individual');
    // A connected indexer makes a mistaken global search observable, while
    // MockClient ensures this test can never contact the network.
    await library.setSetting('indexerUrl', 'https://indexer.invalid/api');
    final requests = _Requests();
    final indexer = IndexerService(
      client: MockClient((_) async {
        requests.indexer++;
        return http.Response('<rss version="2.0"><channel /></rss>', 200);
      }),
    );
    final torrents = TorrentService(endpoint: () async => 'http://localhost');
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    await playback.initialize(platformAudio: false);
    final metadata = _Metadata(root);
    final app = AppController(
      library: library,
      playback: playback,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
      metadata: metadata,
      indexer: indexer,
    );
    app.query = _globalQuery;
    app.navigate(AppPage.library);
    return _Fixture(
      root,
      app,
      metadata,
      requests,
      playlist,
      collection,
      hiddenPlaylist,
    );
  }
}

Finder _field(String scope) => find.byKey(ValueKey('local-search-$scope'));
Finder _row(String id) => find.byKey(ValueKey('track-row-$id'));
Finder _album(String id) => find.byWidgetPredicate(
  (widget) => widget is AlbumCard && widget.album.id == id,
);

Finder _pageScroll() => find
    .descendant(of: find.byType(ContentPage), matching: find.byType(Scrollable))
    .first;

Future<void> _show(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 160, scrollable: _pageScroll());
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _top(WidgetTester tester) async {
  tester.state<ScrollableState>(_pageScroll()).position.jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> _query(WidgetTester tester, String scope, String value) async {
  await _top(tester);
  await _show(tester, _field(scope));
  await tester.enterText(_field(scope), value);
  // Let any accidental global-search debounce fire before checking the spy.
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

Future<void> _navigate(WidgetTester tester, String label) async {
  final mobile = find.byType(NavigationBar);
  final destination = mobile.evaluate().isNotEmpty
      ? find.descendant(of: mobile, matching: find.text(label))
      : find.text(label).first;
  await tester.tap(destination);
  await tester.pumpAndSettle();
}

void _assertLocal(WidgetTester tester, _Fixture fixture, AppPage page) {
  expect(fixture.app.page, page);
  expect(fixture.app.query, _globalQuery);
  expect(
    tester
        .widget<TextFormField>(find.byKey(const ValueKey('music-search')))
        .controller!
        .text,
    _globalQuery,
  );
  expect(fixture.requests.indexer, 0);
  expect(tester.takeException(), isNull);
}

Future<_Fixture> _mount(WidgetTester tester, double width) async {
  final fixture = (await tester.runAsync(_Fixture.create))!;
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await fixture.app.shutdown();
      fixture.app.library.dispose();
      await fixture.root.delete(recursive: true);
    });
  });
  await tester.pumpWidget(MumpaApp(controller: fixture.app));
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'library artist, album and song search remains local at $width px',
      (tester) async {
        final fixture = await _mount(tester, width);
        final app = fixture.app;
        await _query(tester, 'library', 'северная');
        expect(app.librarySearchResults.artists, [_north]);
        expect(
          app.librarySearchResults.albums.map((album) => album.title),
          unorderedEquals([_polar, 'Другой северный альбом']),
        );
        expect(
          app.librarySearchResults.tracks.map((track) => track.id),
          unorderedEquals([
            'north-one',
            'north-two',
            'north-other',
            'north-late',
          ]),
        );
        final artist = find.byKey(const ValueKey('local-artist-$_north'));
        await _show(tester, artist);
        await tester.tap(artist);
        await tester.pumpAndSettle();
        expect(app.selectedArtist, _north);
        expect(find.byKey(const ValueKey('artist-title')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('navigation-back')));
        await tester.pumpAndSettle();
        await _top(tester);
        expect(
          tester.widget<TextField>(_field('library')).controller!.text,
          'северная',
        );
        _assertLocal(tester, fixture, AppPage.library);

        await _query(tester, 'library', 'полярный');
        final album = app.librarySearchResults.albums.single;
        expect(album.tracks.map((track) => track.id), [
          'north-one',
          'north-two',
          'north-late',
        ]);
        final card = _album(album.id);
        await _show(tester, card);
        await tester.tap(
          find.descendant(of: card, matching: find.text(_polar)),
        );
        await tester.pumpAndSettle();
        expect(app.page, AppPage.album);
        expect(app.album!.tracks.map((track) => track.id), [
          'north-one',
          'north-two',
          'north-late',
        ]);
        await tester.tap(find.byKey(const ValueKey('navigation-back')));
        await tester.pumpAndSettle();
        await _top(tester);
        expect(
          tester.widget<TextField>(_field('library')).controller!.text,
          'полярный',
        );
        _assertLocal(tester, fixture, AppPage.library);

        await _query(tester, 'library', 'елки зеленые');
        expect(app.librarySearchResults.tracks.map((track) => track.id), [
          'north-two',
        ]);
        await _show(tester, _row('north-two'));
        expect(_row('north-one'), findsNothing);
        await _top(tester);
        await tester.tap(
          find.byKey(const ValueKey('local-search-library-clear')),
        );
        await tester.pumpAndSettle();
        expect(app.localQuery('library'), isEmpty);
        expect(
          tester.widget<TextField>(_field('library')).controller!.text,
          isEmpty,
        );
        expect(app.librarySearchResults.albums.length, app.albums.length);
        expect(
          app.librarySearchResults.tracks.length,
          app.library.tracks.length,
        );
        _assertLocal(tester, fixture, AppPage.library);
      },
    );

    testWidgets(
      'library and liked queries survive tabs and Back at $width px',
      (tester) async {
        final fixture = await _mount(tester, width);
        final app = fixture.app;
        await _query(tester, 'library', 'лунная');
        await _navigate(tester, 'Любимое');
        expect(
          tester.widget<TextField>(_field('liked')).controller!.text,
          isEmpty,
        );
        await _query(tester, 'liked', 'архивная коллекция');
        expect(app.likedSearchResults.playlists.map((list) => list.id), [
          fixture.collection.id,
        ]);
        expect(
          app.likedSearchResults.playlists.map((list) => list.id),
          isNot(contains(fixture.hiddenPlaylist.id)),
        );
        await _show(
          tester,
          find.descendant(
            of: find.byType(ContentPage),
            matching: find.text(fixture.collection.name),
          ),
        );
        _assertLocal(tester, fixture, AppPage.liked);
        await _navigate(tester, 'Медиатека');
        expect(
          tester.widget<TextField>(_field('library')).controller!.text,
          'лунная',
        );
        expect(app.localQuery('liked'), 'архивная коллекция');
        await tester.tap(find.byKey(const ValueKey('navigation-back')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(_field('liked')).controller!.text,
          'архивная коллекция',
        );
        expect(app.localQuery('library'), 'лунная');
        _assertLocal(tester, fixture, AppPage.liked);
      },
    );

    testWidgets(
      'liked search uses saved album and playlist membership at $width px',
      (tester) async {
        final fixture = await _mount(tester, width);
        final app = fixture.app;
        await _navigate(tester, 'Любимое');
        await _query(tester, 'liked', 'полярный');
        expect(
          app.likedSearchResults.albums.single.tracks.map((track) => track.id),
          ['north-one', 'north-two'],
        );
        expect(
          app.likedSearchResults.tracks.map((track) => track.id),
          unorderedEquals(['north-one', 'north-two']),
        );
        final card = _album(fixture.track('north-one').albumKey);
        await _show(tester, card);
        await tester.tap(
          find.descendant(of: card, matching: find.text(_polar)),
        );
        await tester.pumpAndSettle();
        expect(app.album!.tracks.map((track) => track.id), [
          'north-one',
          'north-two',
        ]);
        await tester.tap(find.byKey(const ValueKey('navigation-back')));
        await tester.pumpAndSettle();

        for (final absent in [
          'Поздняя копия',
          'Чужая версия мотива',
          'Поздняя версия сигнала',
          'Совсем чужая песня',
        ]) {
          await _query(tester, 'liked', absent);
          expect(app.likedSearchResults.tracks, isEmpty);
          expect(app.likedSearchResults.albums, isEmpty);
          expect(app.likedSearchResults.playlists, isEmpty);
          expect(find.text('Ничего не найдено в этом разделе'), findsOneWidget);
        }
        // These songs have no individual heart; their saved container includes
        // them in liked search, without adding the album's other files.
        expect(app.library.liked.contains('road'), isFalse);
        await _query(tester, 'liked', 'дорожный сигнал');
        expect(app.likedSearchResults.tracks.map((track) => track.id), [
          'road',
        ]);
        expect(app.likedSearchResults.playlists.map((list) => list.id), [
          fixture.playlist.id,
        ]);
        expect(app.likedSearchResults.playlists.single.trackIds, [
          'road',
          'individual',
        ]);
        await _show(tester, _row('road'));
        expect(_row('road-outside'), findsNothing);
        await _query(tester, 'liked', 'коллекционный мотив');
        expect(app.likedSearchResults.tracks.map((track) => track.id), [
          'collection',
        ]);
        expect(
          app.likedSearchResults.playlists.single.id,
          fixture.collection.id,
        );
        await _show(tester, _row('collection'));
        _assertLocal(tester, fixture, AppPage.liked);
      },
    );

    testWidgets(
      'downloads and artist filters keep separate local state at $width px',
      (tester) async {
        final fixture = await _mount(tester, width);
        final app = fixture.app;
        await _query(tester, 'library', 'полярный');
        await _navigate(tester, 'Офлайн');
        await _query(tester, 'downloads', 'лунная');
        await _show(tester, _row('north-one'));
        expect(_row('unrelated'), findsNothing);
        expect(_row('north-other'), findsNothing);
        expect(app.localQuery('library'), 'полярный');
        _assertLocal(tester, fixture, AppPage.downloads);
        await _query(tester, 'downloads', 'нелюбимая');
        expect(find.byType(TrackList), findsNothing);
        await _query(tester, 'downloads', 'лунная');

        app.openArtist(_north);
        await tester.pumpAndSettle();
        final scope = 'artist:${normalizeMusicName(_north)}';
        await _query(tester, scope, 'елки');
        await _show(tester, _row('north-two'));
        expect(_row('north-one'), findsNothing);
        expect(
          app.artistTracks.map((track) => track.id),
          unorderedEquals([
            'north-one',
            'north-two',
            'north-other',
            'north-late',
          ]),
        );
        expect(app.localQuery('downloads'), 'лунная');
        expect(fixture.metadata.artistRequests, 1);
        _assertLocal(tester, fixture, AppPage.artist);
        await _navigate(tester, 'Любимое');
        await tester.tap(find.byKey(const ValueKey('navigation-back')));
        await tester.pumpAndSettle();
        await _top(tester);
        await _show(tester, _field(scope));
        expect(
          tester.widget<TextField>(_field(scope)).controller!.text,
          'елки',
        );
        expect(fixture.metadata.artistRequests, 1);
        _assertLocal(tester, fixture, AppPage.artist);
        await tester.tap(find.byKey(const ValueKey('navigation-back')));
        await tester.pumpAndSettle();
        await _top(tester);
        expect(
          tester.widget<TextField>(_field('downloads')).controller!.text,
          'лунная',
        );
        _assertLocal(tester, fixture, AppPage.downloads);
      },
    );
  }

  testWidgets(
    'artist source and catalog searches restore the previous global query and mode',
    (tester) async {
      final fixture = await _mount(tester, 1200);
      final app = fixture.app;
      const group = MusicReleaseGroup(
        id: 'navigation-catalog-group',
        title: 'Каталожный альбом',
        artist: _north,
        year: '2020',
        type: 'Album',
      );
      fixture.metadata.albums = const [group];
      app.query = _globalQuery;
      app.trackSearchMode = true;
      app.openArtist(_north);
      await tester.pumpAndSettle();
      final artistEntry = app.navigationEntryId;

      void expectArtistRestored() {
        expect(app.page, AppPage.artist);
        expect(app.navigationEntryId, artistEntry);
        expect(app.selectedArtist, _north);
        expect(app.query, _globalQuery);
        expect(app.trackSearchMode, isTrue);
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('music-search')))
              .controller!
              .text,
          _globalQuery,
        );
        expect(fixture.metadata.artistRequests, 1);
        expect(fixture.metadata.recordingRequests, 0);
        expect(tester.takeException(), isNull);
      }

      expectArtistRestored();
      final sources = find.descendant(
        of: find.byType(ContentPage),
        matching: find.text('Найти в источниках'),
      );
      await _show(tester, sources);
      await tester.tap(sources);
      await tester.pumpAndSettle();
      expect(app.page, AppPage.search);
      expect(app.query, _north);
      expect(app.trackSearchMode, isFalse);
      await tester.tap(find.byKey(const ValueKey('navigation-back')));
      await tester.pumpAndSettle();
      expectArtistRestored();

      final catalogAlbum = find.byKey(
        const ValueKey('discography-navigation-catalog-group'),
      );
      await _show(tester, catalogAlbum);
      await tester.tap(
        find.descendant(of: catalogAlbum, matching: find.text(group.title)),
      );
      await tester.pumpAndSettle();
      expect(app.page, AppPage.search);
      expect(app.query, '${group.artist} ${group.title}');
      expect(app.trackSearchMode, isFalse);
      await tester.tap(find.byKey(const ValueKey('navigation-back')));
      await tester.pumpAndSettle();
      expectArtistRestored();
    },
  );
}
