import '../domain/models.dart';

/// Lazily computed immutable views of one repository revision. UI refreshes
/// reuse these until a library mutation publishes another revision.
class LibraryViews {
  LibraryViews({
    required this.tracks,
    required List<MusicPlaylist> playlists,
    required Set<String> liked,
    required Set<String> likedPlaylists,
    required List<Set<String>> likedAlbums,
    required List<String> recent,
    required Map<String, dynamic> settings,
  }) : playlists = List.unmodifiable(playlists),
       liked = Set.unmodifiable(liked),
       likedPlaylists = Set.unmodifiable(likedPlaylists),
       _likedAlbums = [for (final ids in likedAlbums) Set<String>.of(ids)],
       recent = List.unmodifiable(recent),
       settings = Map.unmodifiable(settings);

  final List<Track> tracks;
  final List<MusicPlaylist> playlists;
  final Set<String> liked, likedPlaylists;
  final List<Set<String>> _likedAlbums;
  final List<String> recent;
  final Map<String, dynamic> settings;
  late final _indexedTracks = {for (final track in tracks) track.id: track};
  late final offlineTracks = _offlineTracks();
  List<Track> _offlineTracks() {
    final items = tracks.where((track) => track.cachedPath != null).toList();
    final positions = {for (var i = 0; i < tracks.length; i++) tracks[i].id: i};
    items.sort((a, b) {
      final time = (b.downloadedAt?.microsecondsSinceEpoch ?? 0).compareTo(
        a.downloadedAt?.microsecondsSinceEpoch ?? 0,
      );
      return time != 0 ? time : positions[a.id]!.compareTo(positions[b.id]!);
    });
    return List.unmodifiable(items);
  }

  late final favoriteTracks = List<Track>.unmodifiable(
    liked.toList().reversed.map((id) => _indexedTracks[id]).whereType<Track>(),
  );
  late final favoritePlaylists = _favoritePlaylists();
  List<MusicPlaylist> _favoritePlaylists() {
    final indexed = {for (final playlist in playlists) playlist.id: playlist};
    return List.unmodifiable(
      likedPlaylists
          .toList()
          .reversed
          .map((id) => indexed[id])
          .whereType<MusicPlaylist>(),
    );
  }

  late final favoriteAlbums = List<Album>.unmodifiable(
    _likedAlbums.reversed.expand(
      (ids) =>
          groupAlbums(ids.map((id) => _indexedTracks[id]).whereType<Track>()),
    ),
  );
}
