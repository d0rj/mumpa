import 'models.dart';
import 'music_metadata.dart';

/// A local view filter. It does not change collection order or player context.
List<Track> filterCollectionTracks(List<Track> tracks, String query) {
  final terms = normalizeMusicName(
    query,
  ).split(' ').where((term) => term.isNotEmpty).toList();
  if (terms.isEmpty) return tracks;
  return tracks
      .where((track) {
        final text = normalizeMusicName(
          '${track.title} ${track.artist} ${track.albumArtist ?? ''} ${track.album} ${track.year ?? ''}',
        );
        return terms.every(text.contains);
      })
      .toList(growable: false);
}
