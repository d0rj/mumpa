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
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/pages.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

const _artist = 'Главная группа';
const _alias = 'Альтернативное имя';

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(cache: DiskMediaCache(Directory('${root.path}/metadata')));

  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
  @override
  Future<String?> coverForGroup(String id) async => null;
}

class _Playback extends PlaybackController {
  _Playback(LibraryRepository library, TorrentService torrents)
    : super(library: library, torrents: torrents, backend: FakeAudioBackend());

  List<Track> requestedTracks = [];
  int? requestedIndex;

  @override
  Future<void> playTracks(
    List<Track> tracks, {
    int index = 0,
    String? contextPlaylistId,
  }) async {
    requestedTracks = List.of(tracks);
    requestedIndex = index;
  }
}

class _Fixture {
  _Fixture(this.root, this.app, this.playback);
  final Directory root;
  final AppController app;
  final _Playback playback;

  static Future<_Fixture> create({bool likeArtistTracks = true}) async {
    final root = await Directory.systemTemp.createTemp(
      'mumpa-artist-likes-ui-',
    );
    final library = LibraryRepository(root);
    await library.load();
    Track song(String id, String artist, {String? albumArtist}) => Track(
      id: id,
      title: 'Песня $id',
      artist: artist,
      albumArtist: albumArtist,
      album: 'Альбом $id',
      source: TrackSource.local,
    );
    await library.upsert([
      song('early', _artist),
      song('alias', _alias),
      song('guest', 'Приглашённый певец', albumArtist: _artist),
      song('unliked', _artist),
      song('album-only', _artist),
      song('other', 'Другая группа'),
    ]);
    if (likeArtistTracks) {
      for (final id in ['early', 'alias', 'guest']) {
        await library.toggleLike(id);
      }
    }
    await library.toggleLike('other');
    await library.toggleAlbumLike(
      groupAlbums([library.byId('album-only')!]).single,
    );
    final torrents = TorrentService(endpoint: () async => 'http://localhost');
    final playback = _Playback(library, torrents);
    await playback.initialize(platformAudio: false);
    final app = AppController(
      library: library,
      playback: playback,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
      metadata: _Metadata(root),
    );
    app.selectedArtist = _artist;
    app.artistProfile = const MusicArtist(
      id: 'artist-fixture',
      name: _artist,
      aliases: [_alias],
      albums: [
        MusicReleaseGroup(
          id: 'release-fixture',
          title: 'Каталожный альбом',
          artist: _artist,
        ),
      ],
    );
    app.navigate(AppPage.artist);
    return _Fixture(root, app, playback);
  }
}

Finder _likedList() => find.byKey(const ValueKey('artist-liked-tracks'));
Finder _likedRow(String id) => find.descendant(
  of: _likedList(),
  matching: find.byKey(ValueKey('track-row-$id')),
);
Finder _scroll() => find.byType(Scrollable).first;

Future<void> _show(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 150, scrollable: _scroll());
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<double> _sectionOffset(WidgetTester tester, String title) async {
  final section = find.text(title);
  await _show(tester, section);
  return tester.state<ScrollableState>(_scroll()).position.pixels +
      tester.getTopLeft(section).dy;
}

Future<_Fixture> _mount(
  WidgetTester tester,
  double width, {
  bool likeArtistTracks = true,
}) async {
  final fixture = (await tester.runAsync(
    () => _Fixture.create(likeArtistTracks: likeArtistTracks),
  ))!;
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
  await tester.pumpWidget(
    MaterialApp(
      theme: mumpaTheme(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: fixture.app,
          builder: (_, _) => ContentPage(app: fixture.app),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  for (final width in [320.0, 1200.0]) {
    testWidgets('artist likes lead the page at $width px', (tester) async {
      final fixture = await _mount(tester, width);
      final liked = tester.widget<TrackList>(_likedList());
      expect(liked.tracks.map((track) => track.id), [
        'guest',
        'alias',
        'early',
      ]);
      expect(liked.queueTracks!.map((track) => track.id), [
        'guest',
        'alias',
        'early',
      ]);
      expect(
        tester.widgetList<SectionTitle>(find.byType(SectionTitle)).first.title,
        'Любимые треки',
      );
      // Lower sections are intentionally built only when scrolled into view.
      // Compare their document positions instead of requiring every section
      // to have an element in the initial viewport.
      final likedOffset = await _sectionOffset(tester, 'Любимые треки');
      final albumsOffset = await _sectionOffset(tester, 'Твои альбомы');
      final discographyOffset = await _sectionOffset(tester, 'Дискография');
      final tracksOffset = await _sectionOffset(
        tester,
        'Треки в твоей медиатеке',
      );
      expect(albumsOffset, greaterThan(likedOffset));
      expect(discographyOffset, greaterThan(albumsOffset));
      expect(tracksOffset, greaterThan(discographyOffset));

      tester.state<ScrollableState>(_scroll()).position.jumpTo(0);
      await tester.pumpAndSettle();
      await _show(tester, _likedRow('alias'));
      await tester.tap(
        find.descendant(
          of: _likedRow('alias'),
          matching: find.byKey(const ValueKey('track-title-alias')),
        ),
      );
      await tester.pumpAndSettle();
      expect(fixture.playback.requestedTracks.map((track) => track.id), [
        'guest',
        'alias',
        'early',
      ]);
      expect(fixture.playback.requestedIndex, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('artist liked filter retains its queue at $width px', (
      tester,
    ) async {
      final fixture = await _mount(tester, width);
      final field = find.byKey(
        ValueKey('local-search-${fixture.app.artistSearchScope}'),
      );
      await _show(tester, field);
      await tester.enterText(field, 'alias');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(tester.widget<TrackList>(_likedList()).tracks.single.id, 'alias');
      await _show(tester, _likedRow('alias'));
      await tester.tap(
        find.descendant(
          of: _likedRow('alias'),
          matching: find.byKey(const ValueKey('track-title-alias')),
        ),
      );
      await tester.pumpAndSettle();
      expect(fixture.playback.requestedTracks.map((track) => track.id), [
        'guest',
        'alias',
        'early',
      ]);
      expect(fixture.playback.requestedIndex, 1);

      await tester.runAsync(() => fixture.app.library.toggleLike('alias'));
      await tester.pumpAndSettle();
      expect(_likedList(), findsNothing);
      expect(find.byKey(const ValueKey('artist-liked-section')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'artist liked block is absent without song likes at $width px',
      (tester) async {
        await _mount(tester, width, likeArtistTracks: false);
        expect(_likedList(), findsNothing);
        expect(
          find.byKey(const ValueKey('artist-liked-section')),
          findsNothing,
        );
        expect(find.text('Твои альбомы'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
