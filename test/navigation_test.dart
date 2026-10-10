import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/rutracker_service.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/pages.dart';

import 'support.dart';

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(cache: DiskMediaCache(Directory('${root.path}/metadata')));
  final pendingArtists = <String, Completer<MusicArtist?>>{};

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
  Future<MusicArtist?> artist(String name, {SourceOperation? operation}) =>
      (pendingArtists[name] ??= Completer<MusicArtist?>()).future;
}

class _Fixture {
  _Fixture(this.root, this.app, this.metadata, this.collection, this.playlist);
  final Directory root;
  final AppController app;
  final _Metadata metadata;
  final MusicPlaylist collection, playlist;
  Album get albumA =>
      app.albums.firstWhere((album) => album.title == 'Album A');
  Album get albumB =>
      app.albums.firstWhere((album) => album.title == 'Album B');

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await app.shutdown();
      app.library.dispose();
      await root.delete(recursive: true);
    });
  }
}

Future<_Fixture> _fixture(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('mumpa-navigation-');
      final library = LibraryRepository(root);
      await library.load();
      final file = await File('${root.path}/song.mp3').writeAsBytes([0]);
      final tracks = [
        for (var number = 1; number <= 45; number++)
          Track(
            id: 'a$number',
            title: 'Song ${number.toString().padLeft(2, '0')}',
            artist: 'Band A',
            album: 'Album A',
            number: number,
            source: TrackSource.local,
            localPath: file.path,
          ),
        Track(
          id: 'b1',
          title: 'Other song',
          artist: 'Band B',
          album: 'Album B',
          source: TrackSource.local,
          localPath: file.path,
        ),
      ];
      await library.upsert(tracks);
      final collection = await library.openSourceCollection(
        hash: 'fixture-source',
        name: 'My collection',
        tracks: tracks,
      );
      final playlist = await library.createPlaylist('Second playlist');
      await library.addToPlaylist(playlist.id, ['b1']);
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
      );
      return _Fixture(root, app, metadata, collection, playlist);
    }))!;

void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'Back restores albums and their latest enriched library context',
    (tester) async {
      final f = await _fixture(tester);
      _viewport(tester);
      try {
        final a = f.albumA;
        f.app.navigate(AppPage.library);
        f.app.openAlbum(a, playlistId: f.collection.id);
        final aEntry = f.app.navigationEntryId;
        f.app.openAlbum(f.albumB, playlistId: f.playlist.id);
        await tester.pumpWidget(MumpaApp(controller: f.app));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => f.app.library.upsert([
            for (final track in a.tracks)
              track.copyWith(
                album: 'Retagged Album A',
                albumArtist: 'Canonical A',
              ),
          ]),
        );
        await tester.tap(find.byKey(const ValueKey('navigation-back')));
        await tester.pumpAndSettle();
        expect(f.app.page, AppPage.album);
        expect(f.app.navigationEntryId, aEntry);
        expect(f.app.album?.title, 'Retagged Album A');
        expect(f.app.album?.artist, 'Canonical A');
        expect(f.app.albumPlaylistId, f.collection.id);
        expect(f.app.album?.tracks.length, 45);
        expect(find.text('Retagged Album A'), findsWidgets);
        f.app.back();
        await tester.pumpAndSettle();
        expect(f.app.page, AppPage.library);
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    },
  );

  testWidgets('same-page playlists create entries and repeated opens do not', (
    tester,
  ) async {
    final f = await _fixture(tester);
    try {
      f.app.openPlaylist(f.collection);
      final first = f.app.navigationEntryId;
      f.app.openPlaylist(f.collection);
      expect(f.app.navigationEntryId, first);
      f.app.openPlaylist(f.playlist);
      expect(f.app.navigationEntryId, isNot(first));
      f.app.back();
      expect(f.app.playlist?.id, f.collection.id);
      expect(f.app.navigationEntryId, first);
      f.app.back();
      expect(f.app.page, AppPage.home);
      expect(f.app.canGoBack, isFalse);
      f.app.back();
      expect(f.app.page, AppPage.home);
    } finally {
      await f.close(tester);
    }
  });

  testWidgets('mouse Back restores collection filter once per button press', (
    tester,
  ) async {
    final f = await _fixture(tester);
    _viewport(tester);
    try {
      f.app.navigate(AppPage.library);
      f.app.openPlaylist(f.collection);
      final entry = f.app.navigationEntryId;
      await tester.pumpWidget(MumpaApp(controller: f.app));
      await tester.pumpAndSettle();
      final allTracks = find.byKey(const ValueKey('collection-tracks-view'));
      await tester.ensureVisible(allTracks);
      await tester.tap(allTracks);
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('collection-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, 'Song 05');
      await tester.pumpAndSettle();
      f.app.openAlbum(f.albumB);
      await tester.pumpAndSettle();
      final secondary = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await secondary.down(const Offset(60, 45));
      await secondary.up();
      expect(f.app.page, AppPage.album);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      );
      await mouse.down(const Offset(60, 45));
      await tester.pumpAndSettle();
      expect(f.app.page, AppPage.playlist);
      expect(f.app.playlist?.id, f.collection.id);
      expect(f.app.navigationEntryId, entry);
      expect(tester.widget<TextField>(search).controller?.text, 'Song 05');
      expect(find.byKey(const ValueKey('track-row-a5')), findsOneWidget);
      await mouse.moveTo(const Offset(65, 45));
      await tester.pumpAndSettle();
      expect(f.app.page, AppPage.playlist);
      await mouse.up();
      await mouse.down(const Offset(60, 45));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(f.app.page, AppPage.library);
      expect(tester.takeException(), isNull);
    } finally {
      await f.close(tester);
    }
  });

  testWidgets('collection scroll and album view survive leaving the page', (
    tester,
  ) async {
    final f = await _fixture(tester);
    _viewport(tester);
    try {
      f.app.openPlaylist(f.collection);
      await tester.pumpWidget(MumpaApp(controller: f.app));
      await tester.pumpAndSettle();
      final allTracks = find.byKey(const ValueKey('collection-tracks-view'));
      await tester.ensureVisible(allTracks);
      await tester.tap(allTracks);
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byType(ContentPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.drag(scrollable, const Offset(0, -900));
      await tester.pumpAndSettle();
      final previous = tester
          .state<ScrollableState>(scrollable)
          .position
          .pixels;
      expect(previous, greaterThan(300));
      f.app.openAlbum(f.albumB);
      await tester.pumpAndSettle();
      f.app.back();
      await tester.pumpAndSettle();
      final restored = tester
          .state<ScrollableState>(scrollable)
          .position
          .pixels;
      expect(restored, closeTo(previous, 1));
      // The header is lazy and was disposed while below the viewport. Return
      // to the top before asking ensureVisible to resolve its element.
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.ensureVisible(allTracks);
      expect(tester.widget<ChoiceChip>(allTracks).selected, isTrue);
      final albums = find.byKey(const ValueKey('collection-albums-view'));
      await tester.tap(albums);
      await tester.pumpAndSettle();
      f.app.openAlbum(f.albumB);
      await tester.pumpAndSettle();
      f.app.back();
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(albums).selected, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await f.close(tester);
    }
  });

  testWidgets(
    'BrowserBack key restores the previous artist and rejects late data',
    (tester) async {
      final f = await _fixture(tester);
      _viewport(tester);
      try {
        f.app.openArtist('Band A');
        f.metadata.pendingArtists['Band A']!.complete(
          const MusicArtist(id: 'a', name: 'Band A'),
        );
        await tester.pumpWidget(MumpaApp(controller: f.app));
        await tester.pumpAndSettle();
        f.app.openArtist('Band B');
        await tester.pump();
        await tester.sendKeyEvent(
          LogicalKeyboardKey.browserBack,
          platform: 'windows',
          physicalKey: PhysicalKeyboardKey.browserBack,
        );
        await tester.pumpAndSettle();
        expect(f.app.selectedArtist, 'Band A');
        expect(f.app.artistProfile?.id, 'a');
        f.metadata.pendingArtists['Band B']!.complete(
          const MusicArtist(id: 'b', name: 'Band B'),
        );
        await tester.pumpAndSettle();
        expect(f.app.artistProfile?.id, 'a');
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    },
  );

  testWidgets('Back restores search results, formats and correction context', (
    tester,
  ) async {
    final f = await _fixture(tester);
    _viewport(tester);
    try {
      f.app.navigate(AppPage.search);
      f.app.query = 'Original query';
      f.app.trackSearchMode = true;
      f.app.recordingResults = const [
        MusicRecording(id: 'recording', title: 'Song', artist: 'Band A'),
      ];
      f.app.selectedRecording = f.app.recordingResults.single;
      f.app.versionFormat = 'FLAC';
      f.app.searchCompleted = true;
      f.app.correctedSearchQuery = 'Corrected query';
      f.app.searchCorrectionSuggestions = ['Alternate query'];
      f.app.navigate(AppPage.liked);
      f.app.query = 'Different query';
      f.app.recordingResults = [];
      f.app.versionFormat = null;
      f.app.correctedSearchQuery = null;
      f.app.searchCorrectionSuggestions = [];
      f.app.back();
      await tester.pumpWidget(MumpaApp(controller: f.app));
      await tester.pumpAndSettle();
      expect(f.app.query, 'Original query');
      expect(f.app.recordingResults.single.id, 'recording');
      expect(f.app.selectedRecording?.id, 'recording');
      expect(f.app.versionFormat, 'FLAC');
      expect(f.app.correctedSearchQuery, 'Corrected query');
      expect(f.app.searchCorrectionSuggestions, ['Alternate query']);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('music-search')))
            .controller
            ?.text,
        'Original query',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await f.close(tester);
    }
  });

  testWidgets('Back traverses nested catalog sections without HTTP', (
    tester,
  ) async {
    final f = await _fixture(tester);
    try {
      const leaf = CatalogSection(title: 'Leaf', path: '/leaf');
      const child = CatalogSection(
        title: 'Child',
        path: '/child',
        children: [leaf],
      );
      const parent = CatalogSection(
        title: 'Parent',
        path: '/parent',
        children: [child],
      );
      await f.app.browseCatalog(parent);
      final parentEntry = f.app.navigationEntryId;
      await f.app.browseCatalog(child);
      expect(f.app.catalogTrail.map((section) => section.title), [
        'Parent',
        'Child',
      ]);
      await f.app.catalogBack();
      expect(f.app.navigationEntryId, parentEntry);
      expect(f.app.catalogTrail.single.title, 'Parent');
      expect(f.app.catalogSections.single.title, 'Child');
      f.app.back();
      expect(f.app.page, AppPage.home);
      expect(f.app.canGoBack, isFalse);
    } finally {
      await f.close(tester);
    }
  });
}
