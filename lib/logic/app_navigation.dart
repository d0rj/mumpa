part of 'app_controller.dart';

/// An in-memory route snapshot. Library objects are resolved by stable IDs on
/// return, so tag enrichment does not replace an album with a stale copy.
class _NavigationEntry {
  _NavigationEntry(AppController app, this.id)
    : page = app.page,
      album = (
        id: app.selectedAlbum,
        anchor: app._selectedAlbumAnchor,
        tracks: app._selectedAlbumTrackIds == null
            ? null
            : Set<String>.unmodifiable(app._selectedAlbumTrackIds!),
        playlistId: app.albumPlaylistId,
      ),
      playlistId = app.selectedPlaylist,
      settingsSection = app.settingsSection,
      artist = (
        name: app.selectedArtist,
        id: app._selectedArtistId,
        profile: app.artistProfile,
        error: app.artistError,
        pending: app.artistLoading,
        similar: app.similarArtistResults,
        similarPending: app.similarArtistsLoading,
      ),
      search = (
        query: app.query,
        tracks: app.trackSearchMode,
        recordings: List<MusicRecording>.unmodifiable(app.recordingResults),
        recording: app.selectedRecording,
        variants: List<TrackVariant>.unmodifiable(app.trackVariants),
        format: app.versionFormat,
        metadataError: app.metadataError,
        versionError: app.versionError,
        status: app.versionStatus,
        pending: app.searching,
        versionsPending: app.versionLoading,
        completed: app.searchCompleted,
        releases: List<SearchRelease>.unmodifiable(app.releases),
        correction: app.correctedSearchQuery,
        correctionCandidate: app.searchCorrectionCandidate,
        suggestions: List<String>.unmodifiable(app.searchCorrectionSuggestions),
      ),
      catalog = (
        sections: List<CatalogSection>.unmodifiable(app.catalogSections),
        trail: List<CatalogSection>.unmodifiable(app.catalogTrail),
        releases: List<SearchRelease>.unmodifiable(app.catalogReleases),
        next: app.catalogNextPath,
        error: app.catalogError,
        connection: app.catalogNeedsConnection,
        login: app.catalogNeedsLogin,
        pending: app.catalogLoading,
      ),
      filter = app.filter,
      sort = app.sort;

  final int id;
  final AppPage page;
  final ({String? id, String? anchor, Set<String>? tracks, String? playlistId})
  album;
  final String? playlistId;
  final String? settingsSection;
  final ({
    String? name,
    String? id,
    MusicArtist? profile,
    String? error,
    bool pending,
    List<SimilarArtist> similar,
    bool similarPending,
  })
  artist;
  final ({
    String query,
    bool tracks,
    List<MusicRecording> recordings,
    MusicRecording? recording,
    List<TrackVariant> variants,
    String? format,
    String? metadataError,
    String? versionError,
    String? status,
    bool pending,
    bool versionsPending,
    bool completed,
    List<SearchRelease> releases,
    String? correction,
    String? correctionCandidate,
    List<String> suggestions,
  })
  search;
  final ({
    List<CatalogSection> sections,
    List<CatalogSection> trail,
    List<SearchRelease> releases,
    String? next,
    String? error,
    bool connection,
    bool login,
    bool pending,
  })
  catalog;
  final LibraryFilter filter;
  final LibrarySort sort;
}
