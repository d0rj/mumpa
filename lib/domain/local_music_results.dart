import 'collection_filter.dart';
import 'models.dart';

typedef LocalMusicResults = ({
  List<String> artists,
  List<Album> albums,
  List<MusicPlaylist> playlists,
  List<Track> tracks,
});

/// Keeps only the latest view per section, without retaining query history.
class LocalMusicResultsCache {
  Object? _key;
  LocalMusicResults? _results;

  LocalMusicResults resolve({
    required Object key,
    required String query,
    required List<Track> Function() tracks,
    required List<Album> albums,
    required List<MusicPlaylist> playlists,
  }) {
    if (key != _key) {
      final source = tracks();
      _results = (
        artists: filterArtistNames(source, query),
        albums: filterAlbums(albums, query),
        playlists: filterPlaylists(playlists, query, source),
        tracks: filterCollectionTracks(source, query),
      );
      _key = key;
    }
    return _results!;
  }
}
