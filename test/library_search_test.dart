import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/domain/collection_filter.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';

Track _track(
  String id, {
  String title = 'Song',
  String artist = 'Band',
  String album = 'Album',
  String? albumArtist,
  int? year,
}) => Track(
  id: id,
  title: title,
  artist: artist,
  album: album,
  albumArtist: albumArtist,
  year: year,
  source: TrackSource.local,
);

void main() {
  test(
    'artist discography filters complete cached releases by normalized terms',
    () {
      const releases = [
        MusicReleaseGroup(
          id: 'one',
          title: 'Ёлки',
          artist: 'Группа',
          year: '2020',
        ),
        MusicReleaseGroup(
          id: 'two',
          title: 'Другой альбом',
          artist: 'Группа',
          year: '2021',
        ),
      ];
      expect(filterReleaseGroups(releases, 'елки 2020'), [releases.first]);
      expect(filterReleaseGroups(releases, 'елки 2021'), isEmpty);
      expect(identical(filterReleaseGroups(releases, ''), releases), isTrue);
    },
  );

  test('artist recordings match song and album within one cached record', () {
    const recordings = [
      MusicRecording(
        id: 'one',
        title: 'Твои уши',
        artist: 'Ежемесячные',
        albumTitles: ['Лимбо'],
      ),
      MusicRecording(
        id: 'two',
        title: 'Другая песня',
        artist: 'Ежемесячные',
        albumTitles: ['Ёлки'],
      ),
    ];
    expect(filterRecordings(recordings, 'уши лимбо'), [recordings.first]);
    expect(filterRecordings(recordings, 'уши елки'), isEmpty);
    expect(filterRecordings(recordings, 'елки'), [recordings.last]);
    expect(identical(filterRecordings(recordings, ''), recordings), isTrue);
  });
  test(
    'album title, album artist and year match without shortening the album',
    () {
      final tracks = [
        _track(
          'one',
          artist: 'First guest',
          albumArtist: 'Ёлка',
          album: 'Точки',
          year: 2021,
        ),
        _track(
          'two',
          artist: 'Second guest',
          albumArtist: 'Ёлка',
          album: 'Точки',
          year: 2021,
        ),
      ];
      final album = Album(tracks);
      final albums = [
        album,
        Album([_track('other', album: 'Another album')]),
      ];
      final found = filterAlbums(albums, 'ТОЧКИ елка 2021');
      expect(found, [album]);
      expect(identical(found.single, album), isTrue);
      expect(identical(found.single.tracks, tracks), isTrue);
      expect(found.single.tracks.map((track) => track.id), ['one', 'two']);
      expect(albums.length, 2);
    },
  );

  test(
    'album guest artists and years match across the same complete album',
    () {
      final album = Album([
        _track(
          'one',
          artist: 'Guest One',
          albumArtist: 'Main Band',
          year: 2020,
        ),
        _track(
          'two',
          artist: 'Guest Two',
          albumArtist: 'Main Band',
          year: 2021,
        ),
      ]);
      final other = Album([_track('other', artist: 'Other', year: 2022)]);
      expect(filterAlbums([album, other], 'guest two 2020'), [album]);
      expect(filterAlbums([album, other], 'guest 2022'), isEmpty);
    },
  );

  test('song titles do not produce album results', () {
    final album = Album([
      _track('one', title: 'Unique song title'),
      _track('two', title: 'Other song'),
    ]);
    expect(filterAlbums([album], 'unique song'), isEmpty);
    expect(
      filterCollectionTracks(album.tracks, 'unique song').single.id,
      'one',
    );
    expect(album.tracks.length, 2);
  });

  test(
    'empty and punctuation queries preserve the original complete lists',
    () {
      final tracks = [_track('one')];
      final albums = [Album(tracks)];
      final playlists = [
        const MusicPlaylist(
          id: 'p',
          name: 'My playlist',
          trackIds: ['one', 'missing'],
        ),
      ];
      for (final query in ['', '   ', '--- …']) {
        expect(identical(filterAlbums(albums, query), albums), isTrue);
        expect(
          identical(filterPlaylists(playlists, query, tracks), playlists),
          isTrue,
        );
        expect(
          identical(filterCollectionTracks(tracks, query), tracks),
          isTrue,
        );
      }
      expect(filterAlbums([], 'band'), isEmpty);
      expect(filterPlaylists([], 'band', tracks), isEmpty);
      expect(filterArtistNames([], ''), isEmpty);
    },
  );

  test(
    'playlist name matches independently, even with missing track references',
    () {
      const named = MusicPlaylist(
        id: 'named',
        name: 'Ёжики — вечером',
        trackIds: ['missing'],
      );
      const other = MusicPlaylist(id: 'other', name: 'Morning');
      final playlists = [named, other];
      final found = filterPlaylists(playlists, 'ЕЖИКИ вечером', []);
      expect(found, [named]);
      expect(identical(found.single, named), isTrue);
      expect(found.single.trackIds, ['missing']);
    },
  );

  test(
    'one matching track returns the full original playlist in saved order',
    () {
      final tracks = [
        _track('first', title: 'Unrelated'),
        _track(
          'second',
          title: 'Ёлки зелёные',
          artist: 'Guest',
          albumArtist: 'Main Band',
          album: 'Live',
          year: 2023,
        ),
        _track('third', title: 'Another song'),
      ];
      const playlist = MusicPlaylist(
        id: 'p',
        name: 'Collection',
        trackIds: ['third', 'second', 'missing', 'first'],
      );
      final found = filterPlaylists([playlist], 'елки main live 2023', tracks);
      expect(found, [playlist]);
      expect(identical(found.single, playlist), isTrue);
      expect(found.single.trackIds, ['third', 'second', 'missing', 'first']);
      expect(tracks.map((track) => track.id), ['first', 'second', 'third']);
    },
  );

  test(
    'playlist query terms cannot be scattered between tracks or playlist name',
    () {
      final tracks = [
        _track('one', title: 'Morning', artist: 'First Band', album: 'One'),
        _track('two', title: 'Night', artist: 'Second Band', album: 'Two'),
      ];
      const playlist = MusicPlaylist(
        id: 'p',
        name: 'Favourite Rock',
        trackIds: ['one', 'two'],
      );
      expect(filterPlaylists([playlist], 'morning second', tracks), isEmpty);
      expect(filterPlaylists([playlist], 'rock first', tracks), isEmpty);
      expect(filterPlaylists([playlist], 'morning first', tracks), [playlist]);
    },
  );

  test(
    'playlist results retain input order instead of matching-track order',
    () {
      final tracks = [_track('one', title: 'Matching song')];
      const first = MusicPlaylist(
        id: 'first',
        name: 'First',
        trackIds: ['one'],
      );
      const second = MusicPlaylist(
        id: 'second',
        name: 'Second',
        trackIds: ['one'],
      );
      expect(filterPlaylists([second, first], 'matching', tracks), [
        second,
        first,
      ]);
    },
  );

  test(
    'artist names include album artists and deduplicate normalized names',
    () {
      final tracks = [
        _track('one', artist: ' ЁЛКА ', albumArtist: 'Main Band'),
        _track('two', artist: 'елка', albumArtist: ' main-band '),
        _track('three', artist: 'Guest Singer', albumArtist: 'Ёлка'),
      ];
      expect(filterArtistNames(tracks, ''), [
        'ЁЛКА',
        'Main Band',
        'Guest Singer',
      ]);
      expect(filterArtistNames(tracks, 'ЕлКА'), ['ЁЛКА']);
      expect(filterArtistNames(tracks, 'band main'), ['Main Band']);
      expect(filterArtistNames(tracks, 'guest band'), isEmpty);
      expect(filterArtistNames(tracks, 'song'), isEmpty);
    },
  );

  test(
    'empty and unknown artist placeholders are excluded from local artists',
    () {
      final tracks = [
        for (final (i, name) in [
          '',
          '  ',
          '?',
          'UNKNOWN ARTIST',
          'Unknown',
          'Неизвестен',
          'Неизвестный',
          'Неизвестный исполнитель',
          'Без исполнителя',
        ].indexed)
          _track(
            'unknown-$i',
            artist: name,
            albumArtist: 'Неизвестный исполнитель',
          ),
        _track('known', artist: 'Artist', albumArtist: 'Other Artist'),
      ];
      expect(filterArtistNames(tracks, ''), ['Artist', 'Other Artist']);
      expect(filterArtistNames(tracks, 'unknown'), isEmpty);
      expect(filterArtistNames(tracks, 'неизвестный'), isEmpty);
    },
  );
}
