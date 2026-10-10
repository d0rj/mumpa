import 'models.dart';
import 'music_metadata.dart';

/// A local view filter. It does not change collection order or player context.
List<Track> filterCollectionTracks(List<Track> tracks, String query) {
  final terms = _searchTerms(query);
  if (terms.isEmpty) return tracks;
  return tracks
      .where((track) => _matchesTerms(_trackSearchText(track), terms))
      .toList(growable: false);
}

/// Returns complete original albums, never groups rebuilt from matching songs.
/// Song titles belong to the separate track results, rather than album search.
List<Album> filterAlbums(List<Album> albums, String query) {
  final terms = _searchTerms(query);
  if (terms.isEmpty) return albums;
  return albums
      .where((album) {
        final text =
            '${album.title} ${album.artist} ${album.year ?? ''} '
            '${album.tracks.map((track) => '${track.artist} ${track.albumArtist ?? ''} ${track.year ?? ''}').join(' ')}';
        return _matchesTerms(text, terms);
      })
      .toList(growable: false);
}

List<MusicReleaseGroup> filterReleaseGroups(
  List<MusicReleaseGroup> albums,
  String query,
) {
  final terms = _searchTerms(query);
  if (terms.isEmpty) return albums;
  return albums
      .where(
        (album) => _matchesTerms(
          '${album.title} ${album.artist} ${album.year} ${album.type}',
          terms,
        ),
      )
      .toList(growable: false);
}

List<MusicRecording> filterRecordings(
  List<MusicRecording> tracks,
  String query,
) {
  final terms = _searchTerms(query);
  if (terms.isEmpty) return tracks;
  return tracks
      .where(
        (track) => _matchesTerms(
          '${track.title} ${track.artist} ${track.albumTitles.join(' ')} ${track.disambiguation}',
          terms,
        ),
      )
      .toList(growable: false);
}

/// The playlist name or one of its tracks must contain every query term.
/// A match keeps the full playlist and its original saved track order.
List<MusicPlaylist> filterPlaylists(
  List<MusicPlaylist> playlists,
  String query,
  List<Track> tracks,
) {
  final terms = _searchTerms(query);
  if (terms.isEmpty) return playlists;
  final indexed = {
    for (final track in tracks)
      track.id: normalizeMusicName(_trackSearchText(track)),
  };
  return playlists
      .where((playlist) {
        if (_matchesTerms(playlist.name, terms)) return true;
        return playlist.trackIds.any((id) {
          final text = indexed[id];
          return text != null && terms.every(text.contains);
        });
      })
      .toList(growable: false);
}

/// First-seen display names in library order, including album artists. Only
/// names themselves match; a song title does not turn into an artist result.
List<String> filterArtistNames(List<Track> tracks, String query) {
  final terms = _searchTerms(query);
  final names = <String, String>{};
  for (final track in tracks) {
    for (final name in [track.artist, track.albumArtist]) {
      if (name == null) continue;
      final normalized = normalizeMusicName(name);
      if (normalized.isEmpty || _unknownArtistNames.contains(normalized)) {
        continue;
      }
      if (terms.every(normalized.contains)) {
        names.putIfAbsent(normalized, () => name.trim());
      }
    }
  }
  return names.values.toList(growable: false);
}

List<String> _searchTerms(String query) => normalizeMusicName(
  query,
).split(' ').where((term) => term.isNotEmpty).toList(growable: false);

String _trackSearchText(Track track) =>
    '${track.title} ${track.artist} ${track.albumArtist ?? ''} ${track.album} ${track.year ?? ''}';

bool _matchesTerms(String text, List<String> terms) {
  final normalized = normalizeMusicName(text);
  return terms.every(normalized.contains);
}

const _unknownArtistNames = {
  'unknown',
  'unknown artist',
  'неизвестен',
  'неизвестный',
  'неизвестный исполнитель',
  'без исполнителя',
};
