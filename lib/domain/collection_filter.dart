import 'dart:isolate';

import 'models.dart';
import 'music_metadata.dart';

// Tracks are immutable. Weak keys let removed/replaced metadata leave memory
// while unchanged tracks reuse their normalized search text across keystrokes.
final _trackText = Expando<String>('track-search-text');
final _artistNames = Expando<List<String>>('track-search-artists');
String _normalizedTrackText(Track track) =>
    _trackText[track] ??= normalizeMusicName(_trackSearchText(track));

Future<List<List<String>>> _prepareText(List<List<String>> values) =>
    Isolate.run(
      () => values
          .map((row) => row.map(normalizeMusicName).toList())
          .toList(growable: false),
    );

/// Prepare new metadata before publishing it without blocking text input.
Future<void> prepareCollectionSearch(List<Track> tracks) async {
  final missing = tracks.where((track) => _trackText[track] == null).toList();
  if (missing.isEmpty) return;
  final values = await _prepareText([
    for (final track in missing)
      [_trackSearchText(track), track.artist, track.albumArtist ?? ''],
  ]);
  for (var i = 0; i < missing.length; i++) {
    _trackText[missing[i]] = values[i][0];
    _artistNames[missing[i]] = values[i].sublist(1);
  }
}

final _albumText = Expando<String>('album-search-text');

List<String> normalizedTrackArtistNames(Track track) =>
    _artistNames[track] ??= [
      normalizeMusicName(track.artist),
      normalizeMusicName(track.albumArtist ?? ''),
    ];

/// A local view filter. It does not change collection order or player context.
List<Track> filterCollectionTracks(List<Track> tracks, String query) {
  final terms = _searchTerms(query);
  if (terms.isEmpty) return tracks;
  return tracks
      .where((track) => terms.every(_normalizedTrackText(track).contains))
      .toList(growable: false);
}

/// Returns complete original albums, never groups rebuilt from matching songs.
/// Song titles belong to the separate track results, rather than album search.
List<Album> filterAlbums(List<Album> albums, String query) {
  final terms = _searchTerms(query);
  if (terms.isEmpty) return albums;
  return albums
      .where((album) {
        final text = _albumText[album] ??=
            '${normalizeMusicName('${album.title} ${album.artist} ${album.year ?? ''}')} '
            '${album.tracks.map((track) => '${normalizedTrackArtistNames(track).join(' ')} ${track.year ?? ''}').join(' ')}';
        return terms.every(text.contains);
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
    for (final track in tracks) track.id: _normalizedTrackText(track),
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
    final normalizedNames = normalizedTrackArtistNames(track);
    final displayNames = [track.artist, track.albumArtist];
    for (var i = 0; i < displayNames.length; i++) {
      final name = displayNames[i];
      if (name == null) continue;
      final normalized = normalizedNames[i];
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
