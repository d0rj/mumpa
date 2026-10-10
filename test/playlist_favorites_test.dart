import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  late Directory root;
  late LibraryRepository library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-playlist-favorites-');
    library = LibraryRepository(root);
    await library.load();
  });
  tearDown(() async {
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  });
  const track = Track(
    id: 'track',
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    source: TrackSource.local,
  );

  test(
    'old profiles accept playlist favorites without losing other data',
    () async {
      final file = File('${root.path}/library.json');
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'tracks': [track.toJson()],
          'playlists': [
            const MusicPlaylist(
              id: 'playlist',
              name: 'Road',
              trackIds: ['track'],
            ).toJson(),
          ],
          'liked': ['track'],
          'recent': ['track'],
          'settings': {'autoCache': false, 'customSetting': 'preserved'},
        }),
      );
      final migrated = LibraryRepository(root);
      await migrated.load();
      expect(migrated.likedPlaylists, isEmpty);
      await migrated.togglePlaylistLike('playlist');
      migrated.dispose();

      final restarted = LibraryRepository(root);
      await restarted.load();
      expect(restarted.likedPlaylists, {'playlist'});
      expect(restarted.favoritePlaylists.single.name, 'Road');
      expect(restarted.tracks.single.id, 'track');
      expect(restarted.liked, {'track'});
      expect(restarted.recent, ['track']);
      expect(restarted.settings['autoCache'], isFalse);
      expect(restarted.settings['customSetting'], 'preserved');
      restarted.dispose();
    },
  );

  test(
    'source collection favorite survives edits, reopen and restart',
    () async {
      final collection = await library.openSourceCollection(
        hash: 'source',
        name: 'Collection',
        tracks: [track],
      );
      await library.togglePlaylistLike(collection.id);
      await library.renamePlaylist(collection.id, 'My collection');
      await library.addToPlaylist(collection.id, ['another-track']);
      final reopened = await library.openSourceCollection(
        hash: 'source',
        name: 'Original title',
        tracks: [track],
      );
      expect(reopened.id, collection.id);
      expect(library.favoritePlaylists.single.name, 'My collection');
      expect(library.favoritePlaylists.single.trackIds, [
        'track',
        'another-track',
      ]);

      final restarted = LibraryRepository(root);
      await restarted.load();
      expect(restarted.isPlaylistLiked(collection.id), isTrue);
      expect(restarted.favoritePlaylists.single.sourceHash, 'source');
      await restarted.togglePlaylistLike(collection.id);
      restarted.dispose();
      final unliked = LibraryRepository(root);
      await unliked.load();
      expect(unliked.favoritePlaylists, isEmpty);
      expect(unliked.playlists.single.id, collection.id);
      unliked.dispose();
    },
  );

  test(
    'deleting a favorite playlist keeps its tracks and track favorites',
    () async {
      await library.upsert([track]);
      await library.toggleLike(track.id);
      final playlist = await library.createPlaylist('Road');
      await library.addToPlaylist(playlist.id, [track.id]);
      await library.togglePlaylistLike(playlist.id);
      await library.deletePlaylist(playlist.id);
      expect(library.likedPlaylists, isEmpty);

      final restarted = LibraryRepository(root);
      await restarted.load();
      expect(restarted.playlists, isEmpty);
      expect(restarted.likedPlaylists, isEmpty);
      expect(restarted.tracks.single.id, track.id);
      expect(restarted.liked, {track.id});
      restarted.dispose();
    },
  );

  test(
    'favorites reference existing playlists and expose immutable snapshots',
    () async {
      final playlist = await library.createPlaylist('Road');
      await library.togglePlaylistLike('missing');
      expect(library.likedPlaylists, isEmpty);
      await library.togglePlaylistLike(playlist.id);
      expect(() => library.likedPlaylists.clear(), throwsUnsupportedError);
      expect(() => library.favoritePlaylists.clear(), throwsUnsupportedError);

      final file = File('${root.path}/library.json');
      final contents =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      contents['likedPlaylists'] = [playlist.id, 'deleted-playlist'];
      await file.writeAsString(jsonEncode(contents));
      final restarted = LibraryRepository(root);
      await restarted.load();
      expect(restarted.likedPlaylists, {playlist.id});
      restarted.dispose();
    },
  );
}
