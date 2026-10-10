// Opt-in native UI check. Read only one real collection; never copy indexer
// credentials, resolve torrent links or write the production profile.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/pages.dart';

import '../test/support.dart';

class _OfflineMetadata extends MusicMetadataRepository {
  _OfflineMetadata(Directory root, MockClient client)
    : super(
        cache: DiskMediaCache(Directory(p.join(root.path, 'metadata'))),
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

Finder _libraryField() => find.byKey(const ValueKey('local-search-library'));
Finder _globalField() => find.byKey(const ValueKey('music-search'));
Finder _pageScroll() => find
    .descendant(of: find.byType(ContentPage), matching: find.byType(Scrollable))
    .first;

Future<void> _show(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 180, scrollable: _pageScroll());
  await tester.ensureVisible(target);
  // The native window must finish its last scroll animation before a tap.
  await tester.pumpAndSettle();
}

Future<void> _top(WidgetTester tester) async {
  tester.state<ScrollableState>(_pageScroll()).position.jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> _query(WidgetTester tester, String query) async {
  await _top(tester);
  await _show(tester, _libraryField());
  await tester.enterText(_libraryField(), query);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real local library search preserves full albums and one global field',
    (tester) async {
      if (!const bool.fromEnvironment('REAL_LOCAL_SEARCH_TEST') ||
          !Platform.isWindows) {
        return;
      }
      final support = await getApplicationSupportDirectory();
      final sourceLibrary = File(p.join(support.path, 'Mumpa', 'library.json'));
      final originalProfile = await sourceLibrary.readAsString();
      final profile = jsonDecode(originalProfile) as Map<String, dynamic>;
      final collection = (profile['playlists'] as List)
          .map(
            (value) => MusicPlaylist.fromJson(Map<String, dynamic>.from(value)),
          )
          .firstWhere(
            (playlist) =>
                playlist.sourceHash != null &&
                normalizeMusicName(playlist.name).contains('ежемесячные') &&
                playlist.name.contains('72'),
          );
      final ids = collection.trackIds.toSet();
      final tracks = (profile['tracks'] as List)
          .map((value) {
            final json = Map<String, dynamic>.from(value);
            // Download URLs can carry private tracker or Jackett credentials.
            json.remove('torrentLink');
            return Track.fromJson(json);
          })
          .where((track) => ids.contains(track.id))
          .toList();
      final originalAlbums = groupAlbums(tracks);
      expect(tracks.length, 493);
      expect(originalAlbums.length, 72);
      final limbo = originalAlbums.singleWhere(
        (album) => normalizeMusicName(album.title) == 'лимбо',
      );
      expect(limbo.tracks.length, 6);
      final song = tracks.singleWhere(
        (track) => normalizeMusicName(track.title) == 'твои уши',
      );
      expect(song.albumKey, limbo.id);

      final root = await Directory.systemTemp.createTemp(
        'mumpa-real-local-search-',
      );
      final library = LibraryRepository(root);
      await library.load();
      await library.openSourceCollection(
        hash: collection.sourceHash!,
        name: collection.name,
        tracks: tracks,
      );
      await library.setSetting('autoCache', false);
      var httpRequests = 0;
      var engineRequests = 0;
      MockClient offlineClient() => MockClient((_) async {
        httpRequests++;
        throw StateError('This local-search check must never send HTTP');
      });
      final torrents = TorrentService(
        client: offlineClient(),
        endpoint: () async {
          engineRequests++;
          throw StateError(
            'This local-search check must never start an engine',
          );
        },
      );
      final backend = FakeAudioBackend();
      final playback = PlaybackController(
        library: library,
        torrents: torrents,
        backend: backend,
      );
      await playback.initialize(platformAudio: false);
      final app = AppController(
        library: library,
        playback: playback,
        downloads: DownloadRepository(library, torrents),
        torrents: torrents,
        engine: TorrentEngine(root),
        indexer: IndexerService(client: offlineClient()),
        metadata: _OfflineMetadata(root, offlineClient()),
      );
      final screenshot = GlobalKey();
      try {
        app.navigate(AppPage.library);
        await tester.pumpWidget(
          RepaintBoundary(
            key: screenshot,
            child: MumpaApp(controller: app),
          ),
        );
        await tester.pumpAndSettle();

        await _query(tester, 'Ежемесячные');
        final artistResults = app.librarySearchResults;
        expect(artistResults.albums.length, 72);
        expect(artistResults.tracks.length, 493);
        for (final album in artistResults.albums) {
          final original = originalAlbums.singleWhere(
            (item) => item.id == album.id,
          );
          expect(
            album.tracks.map((track) => track.id).toSet(),
            original.tracks.map((track) => track.id).toSet(),
            reason: 'An album result must retain every original track',
          );
        }
        expect(app.page, AppPage.library);
        expect(app.query, isEmpty);

        await _query(tester, 'Лимбо');
        final albumResult = app.librarySearchResults.albums.single;
        expect(albumResult.id, limbo.id);
        expect(albumResult.tracks.length, 6);
        expect(
          albumResult.tracks.map((track) => track.id).toSet(),
          limbo.tracks.map((track) => track.id).toSet(),
        );
        expect(app.librarySearchResults.tracks.length, 6);
        expect(albumResult.artPath, limbo.artPath);
        expect(albumResult.artPath, isNotNull);
        expect(await File(albumResult.artPath!).exists(), isTrue);
        final albumCard = find.byWidgetPredicate(
          (widget) => widget is AlbumCard && widget.album.id == limbo.id,
        );
        await _show(tester, albumCard);
        await tester.runAsync(() async {
          await precacheImage(
            FileImage(File(albumResult.artPath!)),
            screenshot.currentContext!,
          );
        });
        await _top(tester);
        await tester.pumpAndSettle();
        final image =
            await (screenshot.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory(
            p.join(Directory.current.path, 'test-output'),
          );
          await output.create(recursive: true);
          await File(
            p.join(output.path, 'real-local-search-1.2.4.png'),
          ).writeAsBytes(png!.buffer.asUint8List());
        } finally {
          image.dispose();
        }

        await _show(tester, albumCard);
        await tester.tap(
          find.descendant(of: albumCard, matching: find.text(limbo.title)),
        );
        await tester.pumpAndSettle();
        expect(app.page, AppPage.album);
        expect(app.album!.tracks.length, 6);
        expect(
          app.album!.tracks.map((track) => track.id).toSet(),
          limbo.tracks.map((track) => track.id).toSet(),
        );
        await tester.tap(find.byKey(const ValueKey('navigation-back')));
        await tester.pumpAndSettle();
        await _top(tester);
        expect(app.page, AppPage.library);
        expect(app.localQuery('library'), 'Лимбо');
        expect(
          tester.widget<TextField>(_libraryField()).controller!.text,
          'Лимбо',
        );

        await _query(tester, 'твои уши');
        expect(app.librarySearchResults.albums, isEmpty);
        expect(app.librarySearchResults.tracks.single.id, song.id);
        final songRow = find.byKey(ValueKey('track-row-${song.id}'));
        await _show(tester, songRow);
        expect(
          find.descendant(of: songRow, matching: find.text(song.title)),
          findsOneWidget,
        );
        expect(backend.opened, isNull);

        await _query(tester, 'Лимбо');
        expect(_globalField(), findsOneWidget);
        await tester.tap(_globalField());
        await tester.pumpAndSettle();
        expect(
          app.page,
          AppPage.library,
          reason: 'Focusing the shared field is not navigation',
        );
        expect(app.localQuery('library'), 'Лимбо');
        await tester.enterText(_globalField(), 'Ежемесячные');
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(app.page, AppPage.search);
        expect(app.query, 'Ежемесячные');
        expect(_globalField(), findsOneWidget);
        expect(find.byType(TextFormField), findsOneWidget);
        expect(
          tester.widget<TextFormField>(_globalField()).controller!.text,
          'Ежемесячные',
        );
        expect(app.localQuery('library'), 'Лимбо');
        await tester.tap(find.byKey(const ValueKey('navigation-back')));
        await tester.pumpAndSettle();
        await _top(tester);
        expect(app.page, AppPage.library);
        expect(app.localQuery('library'), 'Лимбо');
        expect(
          tester.widget<TextField>(_libraryField()).controller!.text,
          'Лимбо',
        );
        expect(_globalField(), findsOneWidget);
        expect(app.query, isEmpty);
        expect(httpRequests, 0);
        expect(engineRequests, 0);
        expect(library.settings.containsKey('indexerKey'), isFalse);
        expect(
          library.tracks.every((track) => track.torrentLink == null),
          isTrue,
        );
        // Avoid including any profile contents in a failed assertion report.
        expect(
          await sourceLibrary.readAsString() == originalProfile,
          isTrue,
          reason: 'The production profile must remain unchanged',
        );
        expect(tester.takeException(), isNull);
        debugPrint(
          'MUMPA_LOCAL_SEARCH: 72 full albums / 493 tracks; '
          'Лимбо 6/6; твои уши 1; album Back and shared field OK; '
          'HTTP 0 / engine 0 / production profile unchanged',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
