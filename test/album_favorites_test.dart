import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  late Directory root;
  late LibraryRepository library;
  late TorrentService torrents;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-album-favorites-');
    library = LibraryRepository(root);
    await library.load();
    torrents = TorrentService(endpoint: () async => 'http://localhost');
  });
  tearDown(() async {
    await library.flush();
    library.dispose();
    torrents.dispose();
    await root.delete(recursive: true);
  });

  List<Track> discography(String hash) => torrents.tracks(
    TorrentInfo(
      hash: hash,
      title: 'Band - Discography',
      files: [
        for (final (index, path) in [
          (1, 'Root/Band/2020 - First/CD1/01 - One.mp3'),
          (2, 'Root/Band/2020 - First/CD2/01 - Two.mp3'),
          (3, 'Root/Band/2021 - Second/01 - Other.mp3'),
        ])
          TorrentFile(index: index, path: path, bytes: 100),
      ],
    ),
  );

  test(
    'one discography album survives restart without liking the collection',
    () async {
      final tracks = discography('source');
      final collection = await library.openSourceCollection(
        hash: 'source',
        name: 'Band - Discography',
        tracks: tracks,
      );
      await library.togglePlaylistLike(collection.id);
      await library.toggleLike(tracks.last.id);
      final first = groupAlbums(tracks).first;
      await library.toggleAlbumLike(first);
      expect(
        library.favoriteAlbums.single.tracks.map((track) => track.id),
        first.tracks.map((track) => track.id),
      );
      expect(library.favoriteAlbums.single.tracks.map((track) => track.disc), [
        1,
        2,
      ]);
      expect(library.isAlbumLiked(groupAlbums(tracks).last), isFalse);
      expect(library.playlists, hasLength(1));

      final restarted = LibraryRepository(root);
      await restarted.load();
      try {
        expect(restarted.favoriteAlbums.single.title, 'First');
        expect(restarted.isAlbumLiked(first), isTrue);
        await restarted.deletePlaylist(collection.id);
        expect(restarted.favoriteAlbums.single.title, 'First');
        await restarted.toggleAlbumLike(restarted.favoriteAlbums.single);
        expect(restarted.favoriteAlbums, isEmpty);
        expect(restarted.liked, {tracks.last.id});
        expect(restarted.tracks, hasLength(3));
      } finally {
        restarted.dispose();
      }
      final unliked = LibraryRepository(root);
      await unliked.load();
      expect(unliked.favoriteAlbums, isEmpty);
      unliked.dispose();
    },
  );

  test(
    'tag enrichment and another torrent edition keep the saved file selection',
    () async {
      final tracks = discography('original');
      await library.upsert(tracks);
      await library.toggleAlbumLike(groupAlbums(tracks).first);
      await library.upsert([
        tracks.first.copyWith(
          album: 'Tagged title',
          albumArtist: 'Tagged artist',
          albumArtistFromTags: true,
          albumSource: TrackAlbumSource.tags,
          artPath: 'cached-cover.jpg',
        ),
      ]);
      final tagged = library.favoriteAlbums.single;
      expect(tagged.title, 'Tagged title');
      expect(tagged.artist, 'Tagged artist');
      expect(tagged.artPath, 'cached-cover.jpg');
      expect(library.isAlbumLiked(tagged), isTrue);
      final other = discography('other').map(
        (track) =>
            track.copyWith(album: 'Tagged title', albumArtist: 'Tagged artist'),
      );
      await library.upsert(other);
      expect(library.favoriteAlbums.single.tracks, hasLength(2));
      expect(
        library.favoriteAlbums.single.tracks.every(
          (track) => track.torrentHash == 'original',
        ),
        isTrue,
      );
      expect(library.isAlbumLiked(groupAlbums(other).single), isFalse);

      final restarted = LibraryRepository(root);
      await restarted.load();
      expect(restarted.favoriteAlbums.single.title, 'Tagged title');
      expect(restarted.favoriteAlbums.single.tracks, hasLength(2));
      await restarted.toggleAlbumLike(restarted.favoriteAlbums.single);
      expect(restarted.favoriteAlbums, isEmpty);
      restarted.dispose();
    },
  );

  test(
    'track deletion retains remaining favorite files and removes empty albums',
    () async {
      final tracks = discography('source');
      await library.upsert(tracks);
      await library.toggleAlbumLike(groupAlbums(tracks).first);
      await library.removeTracks([tracks.first.id]);
      expect(library.favoriteAlbums.single.tracks.single.id, tracks[1].id);
      expect(library.isAlbumLiked(library.favoriteAlbums.single), isTrue);
      expect(() => library.favoriteAlbums.clear(), throwsUnsupportedError);
      await library.removeTracks([tracks[1].id]);
      expect(library.favoriteAlbums, isEmpty);
      await library.toggleAlbumLike(groupAlbums(tracks).first);
      expect(library.favoriteAlbums, isEmpty);
    },
  );

  test(
    'old profiles and stale favorite references preserve existing preferences',
    () async {
      final tracks = discography('source');
      final file = File('${root.path}/library.json');
      final contents = {
        'version': 1,
        'tracks': tracks.map((track) => track.toJson()).toList(),
        'liked': [tracks.last.id],
        'recent': [tracks.last.id],
        'settings': {'autoCache': false, 'custom': 'kept'},
      };
      await file.writeAsString(jsonEncode(contents));
      final old = LibraryRepository(root);
      await old.load();
      expect(old.favoriteAlbums, isEmpty);
      await old.toggleAlbumLike(groupAlbums(tracks).first);
      old.dispose();
      final saved =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      (saved['likedAlbums'] as List).add(['removed']);
      ((saved['likedAlbums'] as List).first as List).add('missing');
      await file.writeAsString(jsonEncode(saved));
      final restarted = LibraryRepository(root);
      await restarted.load();
      expect(restarted.favoriteAlbums, hasLength(1));
      expect(restarted.favoriteAlbums.single.tracks, hasLength(2));
      expect(restarted.liked, {tracks.last.id});
      expect(restarted.recent, [tracks.last.id]);
      expect(restarted.settings['autoCache'], isFalse);
      expect(restarted.settings['custom'], 'kept');
      restarted.dispose();
    },
  );
}
