import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  late Directory root;
  late LibraryRepository library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-playlist-order-');
    library = LibraryRepository(root);
    await library.load();
  });
  tearDown(() async {
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  });
  final tracks = [
    for (final id in ['a', 'b', 'c', 'd'])
      Track(
        id: id,
        title: 'Song $id',
        artist: 'Artist',
        album: 'Album',
        source: TrackSource.local,
      ),
  ];

  test('saved order survives restart and subsequent playlist edits', () async {
    await library.upsert(tracks);
    final list = await library.createPlaylist('Manual');
    final other = await library.createPlaylist('Other');
    await library.addToPlaylist(list.id, ['a', 'b', 'c']);
    await library.addToPlaylist(other.id, ['c', 'b']);
    await library.togglePlaylistLike(list.id);
    await library.toggleLike('b');
    await library.setSetting('custom', 'kept');
    await library.movePlaylistTrack(list.id, 2, 0);
    expect(library.playlists.first.trackIds, ['c', 'a', 'b']);
    await library.movePlaylistTrack(list.id, 0, 2);
    expect(library.playlists.first.trackIds, ['a', 'b', 'c']);
    await library.movePlaylistTrack(list.id, 0, 1);
    await library.renamePlaylist(list.id, 'Renamed');
    await library.addToPlaylist(list.id, ['d']);
    await library.removeFromPlaylist(list.id, 'c');

    final restored = LibraryRepository(root);
    await restored.load();
    addTearDown(restored.dispose);
    expect(restored.playlists.first.trackIds, ['b', 'a', 'd']);
    expect(restored.favoritePlaylists.single.trackIds, ['b', 'a', 'd']);
    expect(restored.playlists.first.name, 'Renamed');
    expect(restored.playlists.last.trackIds, ['c', 'b']);
    expect(restored.liked, {'b'});
    expect(restored.settings['custom'], 'kept');
    expect(
      restored.tracks.map((t) => t.toJson()),
      tracks.map((t) => t.toJson()),
    );
  });

  test(
    'legacy duplicate and missing IDs are retained as occurrences',
    () async {
      await File('${root.path}/library.json').writeAsString(
        jsonEncode({
          'tracks': tracks.map((t) => t.toJson()).toList(),
          'playlists': [
            const MusicPlaylist(
              id: 'legacy',
              name: 'Legacy',
              trackIds: ['a', 'missing', 'b', 'a', 'c'],
            ).toJson(),
          ],
        }),
      );
      await library.load();
      await library.movePlaylistTrack('legacy', 3, 1);
      expect(library.playlists.single.trackIds, [
        'a',
        'a',
        'missing',
        'b',
        'c',
      ]);
      final restored = LibraryRepository(root);
      await restored.load();
      addTearDown(restored.dispose);
      expect(restored.playlists.single.trackIds, [
        'a',
        'a',
        'missing',
        'b',
        'c',
      ]);
    },
  );

  test(
    'invalid and unchanged moves never notify or rewrite the profile',
    () async {
      final list = await library.createPlaylist('Manual');
      await library.addToPlaylist(list.id, ['a', 'b']);
      final profile = File('${root.path}/library.json');
      final before = await profile.readAsBytes();
      final snapshot = library.playlists;
      var changes = 0;
      library.addListener(() => changes++);
      for (final (id, from, to) in [
        ('missing', 0, 1),
        (list.id, -1, 1),
        (list.id, 0, -1),
        (list.id, 2, 0),
        (list.id, 0, 2),
        (list.id, 0, 0),
      ]) {
        await library.movePlaylistTrack(id, from, to);
      }
      expect(changes, 0);
      expect(identical(snapshot, library.playlists), isTrue);
      expect(await profile.readAsBytes(), before);
    },
  );

  test('rapid moves serialize the final saved order', () async {
    final list = await library.createPlaylist('Manual');
    await library.addToPlaylist(list.id, ['a', 'b', 'c', 'd']);
    await Future.wait([
      library.movePlaylistTrack(list.id, 3, 0),
      library.movePlaylistTrack(list.id, 1, 3),
      library.movePlaylistTrack(list.id, 2, 1),
    ]);
    final restored = LibraryRepository(root);
    await restored.load();
    addTearDown(restored.dispose);
    expect(restored.playlists.single.trackIds, ['d', 'c', 'b', 'a']);
  });

  test('reopening a source collection preserves its edited order', () async {
    final list = await library.openSourceCollection(
      hash: 'source',
      name: 'Collection',
      tracks: tracks,
    );
    await library.movePlaylistTrack(list.id, 0, 3);
    final reopened = await library.openSourceCollection(
      hash: 'source',
      name: 'Collection',
      tracks: tracks,
    );
    expect(reopened.trackIds, ['b', 'c', 'd', 'a']);
    expect(reopened.sourceHash, 'source');
  });

  test(
    'moving a song retains all saved variants and persists their order',
    () async {
      final list = await library.createPlaylist('Variants');
      await library.addToPlaylist(list.id, [
        'a',
        'missing',
        'b',
        'a2',
        'c',
        'd',
      ]);
      await library.movePlaylistTrackGroup(
        list.id,
        {'a', 'a2'},
        {'c'},
        after: true,
      );
      expect(library.playlists.single.trackIds, [
        'missing',
        'b',
        'c',
        'a',
        'a2',
        'd',
      ]);
      await library.movePlaylistTrackGroup(
        list.id,
        {'a', 'a2'},
        {'b'},
        after: false,
      );
      final restored = LibraryRepository(root);
      await restored.load();
      addTearDown(restored.dispose);
      expect(restored.playlists.single.trackIds, [
        'missing',
        'a',
        'a2',
        'b',
        'c',
        'd',
      ]);
    },
  );

  test(
    'filtered moves keep hidden IDs and target every saved variant',
    () async {
      final list = await library.createPlaylist('Filtered');
      await library.addToPlaylist(list.id, [
        'a',
        'b',
        'hidden',
        'b2',
        'c',
        'd',
      ]);
      await library.movePlaylistTrackGroup(
        list.id,
        {'d'},
        {'b', 'b2'},
        after: true,
      );
      expect(library.playlists.single.trackIds, [
        'a',
        'b',
        'hidden',
        'b2',
        'd',
        'c',
      ]);
      await library.movePlaylistTrackGroup(
        list.id,
        {'c'},
        {'b', 'b2'},
        after: false,
      );
      expect(library.playlists.single.trackIds, [
        'a',
        'c',
        'b',
        'hidden',
        'b2',
        'd',
      ]);
    },
  );

  test('invalid and unchanged group moves retain the same snapshot', () async {
    final list = await library.createPlaylist('Guarded');
    await library.addToPlaylist(list.id, ['a', 'b']);
    final snapshot = library.playlists;
    var changes = 0;
    library.addListener(() => changes++);
    for (final (id, moving, target) in [
      ('missing', {'a'}, {'b'}),
      (list.id, {'a'}, {'a'}),
      (list.id, {'absent'}, {'b'}),
      (list.id, {'a'}, {'absent'}),
      (list.id, <String>{}, {'b'}),
      (list.id, {'b'}, {'a'}),
    ]) {
      await library.movePlaylistTrackGroup(id, moving, target, after: true);
    }
    expect(changes, 0);
    expect(identical(library.playlists, snapshot), isTrue);
  });
}
