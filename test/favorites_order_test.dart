import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  late Directory root;
  late LibraryRepository library;
  const tracks = [
    Track(
      id: 'a',
      title: 'Song A',
      artist: 'Band',
      album: 'Album A',
      source: TrackSource.local,
    ),
    Track(
      id: 'b',
      title: 'Song B',
      artist: 'Band',
      album: 'Album B',
      source: TrackSource.local,
    ),
    Track(
      id: 'c',
      title: 'Song C',
      artist: 'Band',
      album: 'Album C',
      source: TrackSource.local,
    ),
  ];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-favorites-order-');
    library = LibraryRepository(root);
    await library.load();
    await library.upsert(tracks);
  });
  tearDown(() async {
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<LibraryRepository> restart() async {
    await library.flush();
    final restarted = LibraryRepository(root);
    await restarted.load();
    addTearDown(() async {
      await restarted.flush();
      restarted.dispose();
    });
    return restarted;
  }

  test(
    'track likes use addition order, relike and persist independently of edits',
    () async {
      for (final id in ['b', 'a', 'c']) {
        await library.toggleLike(id);
      }
      expect(library.favoriteTracks.map((track) => track.id), ['c', 'a', 'b']);
      expect(() => library.favoriteTracks.clear(), throwsUnsupportedError);
      await library.upsert([
        tracks[1].copyWith(title: 'Updated song', album: 'Updated album'),
      ]);
      await library.markPlayed('b');
      expect(library.favoriteTracks.map((track) => track.id), ['c', 'a', 'b']);
      await library.toggleLike('b');
      expect(library.favoriteTracks.map((track) => track.id), ['c', 'a']);
      await library.toggleLike('b');
      final restarted = await restart();
      expect(restarted.favoriteTracks.map((track) => track.id), [
        'b',
        'c',
        'a',
      ]);
      expect(restarted.favoriteTracks.first.title, 'Updated song');
      await restarted.removeTracks(['c']);
      expect(restarted.favoriteTracks.map((track) => track.id), [
        'b',
        'c',
        'a',
      ]);
      await restarted.toggleLike('c');
      await restarted.removeTracks(['c']);
      expect(restarted.favoriteTracks.map((track) => track.id), ['b', 'a']);
    },
  );

  test(
    'playlist and source-collection likes use addition order across restart',
    () async {
      final first = await library.createPlaylist('Z playlist');
      final second = await library.openSourceCollection(
        hash: 'source',
        name: 'A collection',
        tracks: tracks,
      );
      final third = await library.createPlaylist('M playlist');
      for (final playlist in [second, first, third]) {
        await library.togglePlaylistLike(playlist.id);
      }
      await library.renamePlaylist(second.id, 'New collection name');
      await library.addToPlaylist(first.id, ['c', 'a']);
      expect(library.favoritePlaylists.map((playlist) => playlist.id), [
        third.id,
        first.id,
        second.id,
      ]);
      await library.togglePlaylistLike(second.id);
      await library.togglePlaylistLike(second.id);
      final restarted = await restart();
      expect(restarted.favoritePlaylists.map((playlist) => playlist.id), [
        second.id,
        third.id,
        first.id,
      ]);
      await restarted.deletePlaylist(third.id);
      expect(restarted.favoritePlaylists.map((playlist) => playlist.id), [
        second.id,
        first.id,
      ]);
      expect(restarted.liked, isEmpty);
    },
  );

  test(
    'album favorites preserve addition order when metadata changes',
    () async {
      final albums = {
        for (final album in groupAlbums(tracks)) album.title: album,
      };
      for (final title in ['Album B', 'Album A', 'Album C']) {
        await library.toggleAlbumLike(albums[title]!);
      }
      await library.upsert([tracks.first.copyWith(album: 'Renamed A')]);
      expect(library.favoriteAlbums.map((album) => album.title), [
        'Album C',
        'Renamed A',
        'Album B',
      ]);
      await library.toggleAlbumLike(albums['Album B']!);
      await library.toggleAlbumLike(albums['Album B']!);
      final restarted = await restart();
      expect(restarted.favoriteAlbums.map((album) => album.title), [
        'Album B',
        'Album C',
        'Renamed A',
      ]);
      expect(restarted.liked, isEmpty);
      expect(restarted.likedPlaylists, isEmpty);
    },
  );

  test(
    'legacy JSON keeps saved favorite chronology and skips missing items',
    () async {
      await File('${root.path}/library.json').writeAsString(
        jsonEncode({
          'version': 1,
          'tracks': tracks.map((track) => track.toJson()).toList(),
          'playlists': [
            const MusicPlaylist(id: 'a', name: 'A').toJson(),
            const MusicPlaylist(id: 'b', name: 'B').toJson(),
            const MusicPlaylist(id: 'c', name: 'C').toJson(),
          ],
          'liked': ['c', 'missing', 'a', 'b'],
          'likedPlaylists': ['b', 'a', 'deleted', 'c'],
          'likedAlbums': [
            ['c'],
            ['missing'],
            ['a'],
            ['b'],
          ],
          'settings': {'autoCache': false},
        }),
      );
      final restarted = await restart();
      expect(restarted.favoriteTracks.map((track) => track.id), [
        'b',
        'a',
        'c',
      ]);
      expect(restarted.favoritePlaylists.map((playlist) => playlist.id), [
        'c',
        'a',
        'b',
      ]);
      expect(restarted.favoriteAlbums.map((album) => album.title), [
        'Album B',
        'Album A',
        'Album C',
      ]);
      await restarted.setSetting('theme', 'dark');
      final again = await restart();
      expect(again.favoriteTracks.map((track) => track.id), ['b', 'a', 'c']);
      expect(again.favoritePlaylists.map((playlist) => playlist.id), [
        'c',
        'a',
        'b',
      ]);
      expect(again.favoriteAlbums.map((album) => album.title), [
        'Album B',
        'Album A',
        'Album C',
      ]);
      expect(again.settings['autoCache'], isFalse);
    },
  );
}
