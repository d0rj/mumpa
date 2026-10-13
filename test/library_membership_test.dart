import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/domain/models.dart';

Track _track(String id, String album, {String hash = 'source'}) => Track(
  id: id,
  title: 'Song $id',
  artist: 'Band',
  album: album,
  source: TrackSource.torrent,
  torrentHash: hash,
  torrentPath: '$album/$id.mp3',
  torrentAlbumPath: album,
  albumSource: TrackAlbumSource.directory,
);

void main() {
  late Directory root;
  late LibraryRepository library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-membership-');
    library = LibraryRepository(root);
    await library.load();
  });
  tearDown(() async {
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<void> restart() async {
    await library.flush();
    library.dispose();
    library = LibraryRepository(root);
    await library.load();
  }

  test(
    'inspection stays hidden; playback selects one whole source album',
    () async {
      final first = _track('first', 'First');
      final second = _track('second', 'First').copyWith(disc: 2);
      final other = _track('other', 'Other');
      final mirror = _track('mirror', 'First', hash: 'mirror');
      final collection = await library.openSourceCollection(
        hash: 'source',
        name: 'Discography',
        tracks: [first, second, other],
      );
      await library.openSourceCollection(
        hash: 'mirror',
        name: 'Inspected mirror',
        tracks: [mirror],
      );
      expect(library.mediaAlbums, isEmpty);
      expect(library.mediaTracks, isEmpty);
      expect(library.mediaPlaylists, isEmpty);
      expect(library.byId(other.id), isNotNull);
      expect(library.albumById(first.albumKey)!.tracks, hasLength(3));

      await library.markPlayed(first.id);
      expect(library.mediaAlbums.single.title, 'First');
      expect(library.mediaAlbums.single.tracks.map((t) => t.id), [
        'first',
        'second',
      ]);
      expect(library.mediaPlaylists.map((p) => p.id), [collection.id]);
      await restart();
      expect(library.mediaAlbums.single.tracks.map((t) => t.id), [
        'first',
        'second',
      ]);
      expect(library.tracks, hasLength(4));
      expect(library.playlists, hasLength(2));
      expect(library.playlists.first.trackIds, ['first', 'second', 'other']);
    },
  );

  test(
    'played membership outlives recent history and follows corrected tags',
    () async {
      final oldest = _track('oldest', 'Old album');
      await library.upsert([
        oldest,
        for (var i = 0; i < 101; i++) _track('new-$i', 'New album'),
      ]);
      await library.markPlayed(oldest.id);
      for (var i = 0; i < 101; i++) {
        await library.markPlayed('new-$i');
      }
      expect(library.recent, hasLength(100));
      expect(library.recent, isNot(contains(oldest.id)));
      await restart();
      expect(library.mediaAlbums.map((a) => a.title), contains('Old album'));
      await library.upsert([
        oldest.copyWith(
          album: 'Correct album',
          albumSource: TrackAlbumSource.tags,
        ),
      ]);
      expect(
        library.mediaAlbums.map((a) => a.title),
        contains('Correct album'),
      );
      expect(
        library.mediaAlbums.map((a) => a.title),
        isNot(contains('Old album')),
      );
      await library.removeTracks([oldest.id]);
      expect(
        library.mediaAlbums.map((a) => a.title),
        isNot(contains('Correct album')),
      );
    },
  );

  test(
    'favorites, downloads and personal playlists select their albums',
    () async {
      final tracks = [
        _track('like', 'Liked'),
        _track('album', 'Favorite album'),
        _track('download', 'Downloaded'),
        _track('personal', 'Personal'),
        _track('candidate', 'Candidate'),
      ];
      await library.openSourceCollection(
        hash: 'source',
        name: 'Found',
        tracks: tracks,
      );
      await library.toggleLike('like');
      await library.toggleAlbumLike(Album([tracks[1]]));
      final downloaded = await File(
        '${root.path}/download.mp3',
      ).writeAsBytes([1]);
      await library.upsert([tracks[2].copyWith(cachedPath: downloaded.path)]);
      final playlist = await library.createPlaylist('Mine');
      await library.addToPlaylist(playlist.id, ['personal']);
      await restart();
      expect(library.mediaAlbums.map((a) => a.title).toSet(), {
        'Liked',
        'Favorite album',
        'Downloaded',
        'Personal',
      });
      final snapshot = library.mediaAlbums;
      expect(() => library.mediaTracks.clear(), throwsUnsupportedError);
      expect(() => snapshot.clear(), throwsUnsupportedError);
      await library.toggleLike('like');
      expect(library.mediaAlbums.map((a) => a.title), isNot(contains('Liked')));
      expect(snapshot.map((a) => a.title), contains('Liked'));
    },
  );

  test(
    'liking a source selects its full collection; unliking hides candidates',
    () async {
      final collection = await library.openSourceCollection(
        hash: 'source',
        name: 'Found',
        tracks: [_track('a', 'First'), _track('b', 'Second')],
      );
      await library.togglePlaylistLike(collection.id);
      expect(library.mediaAlbums, hasLength(2));
      expect(library.mediaPlaylists.single.id, collection.id);
      await library.togglePlaylistLike(collection.id);
      expect(library.mediaAlbums, isEmpty);
      expect(library.mediaPlaylists, isEmpty);
      final empty = await library.createPlaylist('Empty personal playlist');
      expect(library.mediaPlaylists.single.id, empty.id);
    },
  );

  test(
    'local imports and explicit torrent additions need no playback',
    () async {
      await library.upsert([
        const Track(
          id: 'local',
          title: 'Local',
          artist: 'Band',
          album: 'Local',
          source: TrackSource.local,
        ),
        _track('explicit', 'Selected torrent'),
      ], addToLibrary: true);
      await library.upsert([_track('candidate', 'Inspected torrent')]);
      await restart();
      expect(library.mediaAlbums.map((a) => a.title).toSet(), {
        'Local',
        'Selected torrent',
      });
    },
  );

  test(
    'old profiles retain known intent and hide inspected collections',
    () async {
      final tracks = [
        _track('played', 'Played'),
        _track('liked', 'Liked'),
        _track('personal', 'Personal'),
        _track('candidate', 'Candidate'),
        const Track(
          id: 'local',
          title: 'Local',
          artist: 'Band',
          album: 'Local',
          source: TrackSource.local,
        ),
      ];
      await File('${root.path}/library.json').writeAsString(
        jsonEncode({
          'version': 1,
          'tracks': tracks.map((t) => t.toJson()).toList(),
          'playlists': [
            const MusicPlaylist(
              id: 'source-list',
              name: 'Found',
              sourceHash: 'source',
              trackIds: ['played', 'liked', 'personal', 'candidate'],
            ).toJson(),
            const MusicPlaylist(
              id: 'mine',
              name: 'Mine',
              trackIds: ['personal'],
            ).toJson(),
            const MusicPlaylist(
              id: 'unused',
              name: 'Unused source',
              sourceHash: 'unused',
            ).toJson(),
          ],
          'recent': ['played', 'missing'],
          'liked': ['liked'],
        }),
      );
      await restart();
      expect(library.mediaAlbums.map((a) => a.title).toSet(), {
        'Played',
        'Liked',
        'Personal',
        'Local',
      });
      expect(library.mediaPlaylists.map((p) => p.id).toSet(), {
        'source-list',
        'mine',
      });
      await library.setSetting('volume', .5);
      final saved =
          jsonDecode(await File('${root.path}/library.json').readAsString())
              as Map;
      expect(saved['retainedTrackIds'], ['played']);
      await restart();
      expect(library.tracks, hasLength(5));
      expect(library.mediaAlbums, hasLength(4));
    },
  );
}
