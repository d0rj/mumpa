import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'support.dart';

const release = SearchRelease(
  title: 'Fixture collection',
  link: 'https://example.test/music.torrent',
);
const info = TorrentInfo(
  hash: 'fixture-hash',
  title: 'Fixture collection',
  files: [
    TorrentFile(index: 1, path: '01 - First.wav', bytes: 100),
    TorrentFile(index: 2, path: 'readme.txt', bytes: 10),
    TorrentFile(index: 3, path: '02 - Second.wav', bytes: 100),
    TorrentFile(index: 4, path: '03 - Third.wav', bytes: 100),
  ],
);

class FixtureIndexer extends IndexerService {
  @override
  Future<({String source, bool file})> resolve(
    String link,
    Directory directory, {
    SourceOperation? operation,
    bool preferCachedMetainfo = false,
  }) async => (source: 'fixture.torrent', file: true);
}

class FixtureTorrentService extends TorrentService {
  FixtureTorrentService() : super(endpoint: () async => 'http://localhost');
  @override
  Future<TorrentInfo> upload(
    String path, {
    SourceOperation? operation,
    void Function(String)? onProgress,
  }) async => info;
  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) =>
      stream(track.torrentHash!, track.torrentIndex!);
  @override
  Future<void> waitForAudio(
    Uri uri, {
    SourceOperation? operation,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    operation?.check();
  }
}

class RecordingDownloads extends DownloadRepository {
  RecordingDownloads(super.library, super.torrents);
  final requested = <String>[];
  bool priorityUsed = false;
  @override
  void enqueue(Iterable<Track> tracks, {bool priority = false}) {
    requested.addAll(tracks.map((t) => t.id));
    priorityUsed = priority;
  }
}

void main() {
  late Directory root;
  late AppController app;
  late FakeAudioBackend backend;
  late RecordingDownloads downloads;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-collection-');
    final library = LibraryRepository(root);
    await library.load();
    await library.setSetting('indexerUrl', 'http://localhost/api');
    final torrents = FixtureTorrentService();
    backend = FakeAudioBackend();
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: backend,
    );
    await playback.initialize(platformAudio: false);
    downloads = RecordingDownloads(library, torrents);
    app = AppController(
      library: library,
      playback: playback,
      downloads: downloads,
      torrents: torrents,
      engine: TorrentEngine(root),
      indexer: FixtureIndexer(),
    );
    app.sourceFeed = [release];
  });
  tearDown(() async {
    app.dispose();
    downloads.dispose();
    await app.playback.close();
    app.torrents.dispose();
    await app.library.flush();
    app.library.dispose();
    await root.delete(recursive: true);
  });

  test(
    'source creates a collection; only played track auto-downloads; current playlist extends queue',
    () async {
      await app.openRelease(release);
      expect(app.albums, isEmpty);
      expect(app.library.mediaPlaylists, isEmpty);
      app.setLocalQuery('library', 'Fixture');
      expect(app.librarySearchResults.playlists, isEmpty);
      expect(app.librarySearchResults.tracks, isEmpty);
      expect(app.error, isNull);
      expect(app.page, AppPage.playlist);
      expect(app.playlistTracks.length, 3);
      expect(app.library.playlists.length, 1);
      expect(backend.opened, isNull);
      expect(downloads.requested, isEmpty);
      final playlist = app.playlist!;
      await app.playCollection(
        app.playlistTracks,
        index: 1,
        playlistId: playlist.id,
      );
      expect(app.playback.current!.title, 'Second');
      expect(app.playback.queue.length, 3);
      expect(app.currentPlaylist!.id, playlist.id);
      expect(Uri.parse(backend.opened!).queryParameters['index'], '3');
      expect(downloads.requested, [app.playback.current!.id]);
      expect(downloads.priorityUsed, isTrue);
      expect(app.albums, hasLength(1));
      expect(app.library.mediaPlaylists.single.id, playlist.id);
      expect(app.librarySearchResults.playlists.single.id, playlist.id);
      final localFile = await File('${root.path}/extra.wav').writeAsBytes([1]);
      final extra = Track(
        id: 'extra',
        title: 'Extra',
        artist: 'Band',
        album: 'Other',
        source: TrackSource.local,
        localPath: localFile.path,
      );
      await app.library.upsert([extra]);
      await app.addToCurrentPlaylist(extra);
      await app.addToCurrentPlaylist(extra);
      expect(app.currentPlaylist!.trackIds.length, 4);
      expect(app.playback.queue.length, 4);
      expect(app.playback.current!.title, 'Second');
      await app.openRelease(release);
      expect(app.library.playlists.length, 1);
      expect(app.playlist!.id, playlist.id);
      expect(app.playlistTracks.length, 4);
    },
  );

  for (final width in [1200.0, 390.0, 320.0]) {
    testWidgets('source tap opens playable collection at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MumpaApp(controller: app));
      await tester.scrollUntilVisible(
        find.text(release.title),
        160,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text(release.title));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (app.page != AppPage.playlist &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('collection-title')), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(app.playlistTracks.length, 3);
      final inspected = app.playlist!;
      app.navigate(AppPage.library);
      await tester.pumpAndSettle();
      expect(find.text(release.title), findsNothing);
      expect(find.text('Здесь пока тихо'), findsOneWidget);
      app.openPlaylist(inspected);
      await tester.pumpAndSettle();
      final second = app.playlistTracks[1];
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('track-row-${second.id}')),
        160,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(ValueKey('track-title-${second.id}')));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (app.playback.loading && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump(const Duration(milliseconds: 250));
      expect(app.playback.current!.id, second.id);
      expect(app.playback.playing, isTrue);
      expect(downloads.requested, [second.id]);
      await tester.runAsync(() => app.playback.pause());
      app.navigate(AppPage.library);
      await tester.pumpAndSettle();
      expect(find.text('Здесь пока тихо'), findsNothing);
      expect(find.text(release.title), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
