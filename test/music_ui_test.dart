import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(cache: DiskMediaCache(Directory('${root.path}/metadata')));

  @override
  Future<MusicArtist?> artist(
    String name, {
    SourceOperation? operation,
  }) async => const MusicArtist(
    id: 'artist-id',
    name: 'Band',
    type: 'Group',
    aliases: ['Band Alias'],
    albums: [
      MusicReleaseGroup(
        id: 'group-id',
        title: 'Catalog Album',
        artist: 'Band',
        year: '2020',
        type: 'Album',
      ),
    ],
  );

  @override
  Future<String?> coverForGroup(String id) async => null;

  @override
  Future<String?> coverForReleaseTitle(String title) async => null;

  @override
  Future<String?> cachedCoverForAlbum(
    String artistName,
    String albumTitle,
  ) async => null;

  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playing indicator pauses and honors reduced motion', (
    tester,
  ) async {
    Widget indicator({required bool playing, bool reducedMotion = false}) =>
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reducedMotion),
            child: Center(child: PlayingIndicator(playing: playing)),
          ),
        );

    await tester.pumpWidget(indicator(playing: true));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getSize(find.byType(PlayingIndicator)), const Size(20, 20));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(indicator(playing: false));
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(indicator(playing: true, reducedMotion: true));
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('artist link wins its gesture without playing the outer row', (
    tester,
  ) async {
    var opens = 0;
    var plays = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: InkWell(
            onTap: () => plays++,
            child: ArtistLink(artist: 'Band', onOpen: () => opens++),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Band'));
    expect(opens, 1);
    expect(plays, 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: ArtistLink(
            artist: 'Неизвестный исполнитель',
            onOpen: () => opens++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Неизвестный исполнитель'));
    expect(opens, 1);
  });

  testWidgets('long version labels fit narrow track cards', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 92,
            child: BadgePill(
              icon: Icons.info_outline_rounded,
              label: 'Без цензуры · по описанию',
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(BadgePill)).width, 92);
  });

  testWidgets('cover request stays stable while async artwork is pending', (
    tester,
  ) async {
    final pending = Completer<String?>();
    var calls = 0;
    Widget cover() => MaterialApp(
      home: Center(
        child: AsyncCoverArt(
          requestKey: 'album',
          load: () {
            calls++;
            return pending.future;
          },
          seed: 'Album',
          size: 48,
        ),
      ),
    );
    await tester.pumpWidget(cover());
    await tester.pumpWidget(cover());
    expect(calls, 1);
    expect(tester.getSize(find.byType(AsyncCoverArt)), const Size(48, 48));
    pending.complete(null);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final width in [1200.0, 320.0]) {
    testWidgets('artist and favorite collections render at width $width', (
      tester,
    ) async {
      late Directory root;
      late LibraryRepository library;
      late TorrentService torrents;
      late PlaybackController playback;
      late DownloadRepository downloads;
      late AppController app;
      const id = 'track';
      late MusicPlaylist collection;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('mumpa-music-ui-');
        library = LibraryRepository(root);
        await library.load();
        final file = await File('${root.path}/track.mp3').writeAsBytes([1]);
        await library.upsert([
          Track(
            id: id,
            title: 'Track',
            artist: 'Band Alias',
            album: 'Local Album',
            source: TrackSource.local,
            localPath: file.path,
          ),
        ]);
        collection = await library.openSourceCollection(
          hash: 'hash',
          name: 'Favorite collection',
          tracks: library.tracks,
        );
        await library.togglePlaylistLike(collection.id);
        torrents = TorrentService(endpoint: () async => 'http://localhost');
        playback = PlaybackController(
          library: library,
          torrents: torrents,
          backend: FakeAudioBackend(),
        );
        await playback.initialize(platformAudio: false);
        downloads = DownloadRepository(library, torrents);
        app = AppController(
          library: library,
          playback: playback,
          downloads: downloads,
          torrents: torrents,
          engine: TorrentEngine(root),
          metadata: _Metadata(root),
        );
      });
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await tester.runAsync(() async {
          app.openArtist('Band Alias');
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpWidget(MumpaApp(controller: app));
        await tester.pumpAndSettle();
        expect(app.artistTracks.map((t) => t.id), contains(id));
        expect(find.byKey(const ValueKey('artist-title')), findsOneWidget);
        expect(find.text('Треки в твоей медиатеке'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('discography-group-id')),
          150,
          scrollable: find
              .descendant(
                of: find.byType(ContentPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(tester.takeException(), isNull);
        app.navigate(AppPage.liked);
        await tester.pumpAndSettle();
        expect(find.text('Favorite collection'), findsWidgets);
        final button = find.descendant(
          of: find.byType(ContentPage),
          matching: find.byKey(ValueKey('favorite-playlist-${collection.id}')),
        );
        await tester.runAsync(() async {
          await tester.tap(button);
          await library.flush();
        });
        await tester.pumpAndSettle();
        expect(library.isPlaylistLiked(collection.id), isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          app.dispose();
          downloads.dispose();
          await playback.close();
          torrents.dispose();
          await library.flush();
          library.dispose();
          await root.delete(recursive: true);
        });
      }
    });
  }
}
