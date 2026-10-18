import 'dart:async';
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
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

// Dialog callbacks run in the widget fake clock; keep disk writes in the
// real I/O zone so persistence checks and teardown can await them.
class _UiLibrary extends LibraryRepository {
  _UiLibrary(super.root) : _ioZone = Zone.current;
  final Zone _ioZone;

  @override
  Future<MusicPlaylist> createPlaylist(String name) =>
      _ioZone.run(() => super.createPlaylist(name));
  @override
  Future<void> addToPlaylist(String id, Iterable<String> tracks) =>
      _ioZone.run(() => super.addToPlaylist(id, tracks));
}

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(cache: DiskMediaCache(Directory('${root.path}/metadata')));

  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

const _track = Track(
  id: 'song',
  title: 'Песня',
  artist: 'Группа',
  album: 'Альбом',
  source: TrackSource.local,
);

class _Fixture {
  _Fixture(this.root, this.app);
  final Directory root;
  final AppController app;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'mumpa-playlist-picker-',
    );
    final library = _UiLibrary(root);
    await library.load();
    await library.setSetting('autoCache', false);
    await library.upsert([_track]);
    await library.openSourceCollection(
      hash: 'opened',
      name: 'Открытая коллекция',
      tracks: [],
    );
    final favorite = await library.openSourceCollection(
      hash: 'favorite',
      name: 'Избранная коллекция',
      tracks: [],
    );
    await library.togglePlaylistLike(favorite.id);
    final torrents = TorrentService(
      endpoint: () async => throw StateError('No engine expected'),
    );
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    await playback.initialize(platformAudio: false);
    return _Fixture(
      root,
      AppController(
        library: library,
        playback: playback,
        downloads: DownloadRepository(library, torrents),
        torrents: torrents,
        engine: TorrentEngine(root),
        metadata: _Metadata(root),
      ),
    );
  }

  Future<void> close() async {
    try {
      await app.shutdown();
      app.library.dispose();
    } finally {
      await root.delete(recursive: true);
    }
  }
}

Future<void> _mount(WidgetTester tester, _Fixture fixture) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(fixture.close);
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: mumpaTheme(),
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            TrackList(app: fixture.app, tracks: [_track]),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('track-actions-song')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Добавить в плейлист'));
  await tester.pumpAndSettle();
}

Finder _options() => find.descendant(
  of: find.byType(SimpleDialog),
  matching: find.byType(SimpleDialogOption),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('track menu offers only user-created playlists', (tester) async {
    final fixture = (await tester.runAsync(_Fixture.create))!;
    await _mount(tester, fixture);
    final library = fixture.app.library;
    late MusicPlaylist empty, used;
    await tester.runAsync(() async {
      empty = await library.createPlaylist('Мой пустой плейлист');
      used = await library.createPlaylist('Мой плейлист с треками');
      await library.addToPlaylist(used.id, [_track.id]);
    });

    await _openPicker(tester);
    expect(find.text(empty.name), findsOneWidget);
    expect(find.text(used.name), findsOneWidget);
    expect(find.text('Открытая коллекция'), findsNothing);
    expect(find.text('Избранная коллекция'), findsNothing);
    expect(find.text('+ Новый плейлист'), findsOneWidget);
    expect(_options(), findsNWidgets(3));

    await tester.tap(find.text(empty.name));
    await tester.pumpAndSettle();
    await tester.runAsync(library.flush);
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(library.playlists.singleWhere((p) => p.id == empty.id).trackIds, [
      _track.id,
    ]);
    expect(
      library.playlists
          .where((p) => p.sourceHash != null)
          .every((p) => p.trackIds.isEmpty),
      isTrue,
    );

    await tester.runAsync(() async {
      final restarted = LibraryRepository(fixture.root);
      try {
        await restarted.load();
        expect(
          restarted.playlists.singleWhere((p) => p.id == empty.id).trackIds,
          [_track.id],
        );
        expect(restarted.playlists, hasLength(4));
      } finally {
        restarted.dispose();
      }
    });
  });

  testWidgets(
    'picker can create a playlist when only opened collections exist',
    (tester) async {
      final fixture = (await tester.runAsync(_Fixture.create))!;
      await _mount(tester, fixture);
      final library = fixture.app.library;

      await _openPicker(tester);
      expect(_options(), findsOneWidget);
      expect(find.text('+ Новый плейлист'), findsOneWidget);
      await tester.tap(find.text('+ Новый плейлист'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Новый личный плейлист');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      await tester.runAsync(library.flush);
      await tester.pumpAndSettle();
      await tester.runAsync(library.flush);
      await tester.pumpAndSettle();

      final personal = library.playlists.singleWhere(
        (p) => p.sourceHash == null,
      );
      expect(personal.name, 'Новый личный плейлист');
      expect(personal.trackIds, [_track.id]);
      await _openPicker(tester);
      expect(find.text(personal.name), findsOneWidget);
      expect(_options(), findsNWidgets(2));
      expect(find.text('Открытая коллекция'), findsNothing);
      expect(find.text('Избранная коллекция'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    },
  );
}
