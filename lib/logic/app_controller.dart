import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../data/download_repository.dart';
import '../data/library_repository.dart';
import '../data/jackett_service.dart';
import '../data/flaresolverr_service.dart';
import '../data/rutracker_service.dart';
import '../data/torrent_service.dart';
import '../data/torrent_network.dart';
import '../data/source_operation.dart';
import '../data/media_cache.dart';
import '../data/music_metadata_repository.dart';
import '../data/torrent_artwork_repository.dart';
import '../data/track_search_service.dart';
import '../data/windows_player_service.dart';
import '../domain/models.dart';
import '../domain/music_metadata.dart';
import '../domain/collection_filter.dart';
import 'corrected_music_search.dart';
import 'playback_controller.dart';

enum AppPage {
  home,
  search,
  library,
  liked,
  downloads,
  settings,
  album,
  playlist,
  artist,
}

typedef LocalMusicResults = ({
  List<String> artists,
  List<Album> albums,
  List<MusicPlaylist> playlists,
  List<Track> tracks,
});

enum LibraryFilter { all, offline, torrents }

enum LibrarySort { added, name, artist }

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
      artist = (
        name: app.selectedArtist,
        profile: app.artistProfile,
        error: app.artistError,
        pending: app.artistLoading,
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
  final ({String? name, MusicArtist? profile, String? error, bool pending})
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

class AppController extends ChangeNotifier {
  AppController({
    required this.library,
    required this.playback,
    required this.downloads,
    required this.torrents,
    required this.engine,
    IndexerService? indexer,
    RuTrackerService? catalog,
    JackettService? jackett,
    FlareSolverrService? flaresolverr,
    MusicMetadataRepository? metadata,
  }) : indexer = indexer ?? IndexerService(),
       catalog = catalog ?? RuTrackerService(),
       jackett = jackett ?? JackettService(library.root),
       flaresolverr = flaresolverr ?? FlareSolverrService(library.root),
       metadata =
           metadata ??
           MusicMetadataRepository(
             cache: DiskMediaCache(
               Directory('${library.root.path}/metadata'),
               maxBytes:
                   ((library.settings['metadataCacheMb'] as num?)?.toInt() ??
                       256) *
                   1024 *
                   1024,
             ),
           ) {
    library.addListener(_changed);
    downloads.addListener(_changed);
    playback.addListener(_onPlayback);
  }
  final LibraryRepository library;
  final PlaybackController playback;
  final DownloadRepository downloads;
  final TorrentService torrents;
  final TorrentEngine engine;
  final IndexerService indexer;
  final RuTrackerService catalog;
  final JackettService jackett;
  final FlareSolverrService flaresolverr;
  final MusicMetadataRepository metadata;
  late final torrentArtwork = TorrentArtworkRepository(
    torrents: torrents,
    cache: metadata.cache,
  );

  Future<String?> loadTrackArtwork(Track track) async {
    final generation = metadata.cache.generation;
    final embedded = artworkForTrack(track);
    if (embedded != null && await File(embedded).exists()) return embedded;
    final cachedTorrent = await torrentArtwork.cachedCover(track);
    if (_disposed || generation != metadata.cache.generation) return null;
    if (cachedTorrent != null) return cachedTorrent;
    final artist = track.albumArtist?.trim().isNotEmpty == true
        ? track.albumArtist!
        : track.artist;
    final canUseMetadata =
        artist.trim().isNotEmpty &&
        track.album.trim().isNotEmpty &&
        !const {
          'неизвестный исполнитель',
          'неизвестен',
          'unknown artist',
          'unknown',
        }.contains(artist.trim().toLowerCase());
    if (canUseMetadata) {
      final cachedMetadata = await metadata.cachedCoverForAlbum(
        artist,
        track.album,
      );
      if (_disposed || generation != metadata.cache.generation) return null;
      if (cachedMetadata != null) return cachedMetadata;
    }
    // A slow cover piece must not delay a ready public-catalogue image. Keep
    // the losing transfer alive: its bounded result can serve later visits.
    final sources = <Future<String?> Function()>[
      () => torrentArtwork.load(track),
      if (canUseMetadata) () => metadata.coverForAlbum(artist, track.album),
    ];
    final result = Completer<String?>();
    var pending = sources.length;
    void finish(String? path) {
      pending--;
      if (result.isCompleted) return;
      if (_disposed || generation != metadata.cache.generation) {
        result.complete(null);
      } else if (path != null || pending == 0) {
        result.complete(path);
      }
    }

    for (final source in sources) {
      unawaited(
        Future<String?>.sync(
          source,
        ).then(finish, onError: (Object _, StackTrace _) => finish(null)),
      );
    }
    return result.future;
  }

  Future<String?> loadReleaseGroupArtwork(MusicReleaseGroup group) async {
    final generation = metadata.cache.generation;
    final local = library.tracks
        .where(
          (track) =>
              normalizeMusicName(track.albumArtist ?? track.artist) ==
                  normalizeMusicName(group.artist) &&
              normalizeMusicName(track.album) ==
                  normalizeMusicName(group.title),
        )
        .firstOrNull;
    if (local != null) return loadTrackArtwork(local);
    final saved = await metadata.cachedCoverForAlbum(group.artist, group.title);
    if (_disposed || generation != metadata.cache.generation) return null;
    if (saved != null) return saved;
    final cover = await metadata.coverForGroup(group.id);
    if (cover != null) return cover;
    if (_disposed || generation != metadata.cache.generation) return null;
    return metadata.coverForAlbum(group.artist, group.title);
  }

  WindowsPlayerService? windowsPlayer;
  Future<void>? _shutdown;
  Future<void>? _catalogDisposal, _jackettStop, _flaresolverrStop;
  Future<void> shutdown() => _shutdown ??= _shutdownApplication();
  Future<void> _shutdownApplication() async {
    // A failed save or service must not prevent the remaining resources from
    // being released, or leave the Windows quit handshake permanently blocked.
    await _shutdownStep('downloads', downloads.close);
    await _shutdownStep('playback', playback.close);
    await _shutdownStep('torrent engine', engine.stop);
    await _stopJackett();
    await _stopFlareSolverr();
    await _disposeCatalog();
    await _shutdownStep('library flush', library.flush);
    dispose();
    _disposeStep('torrent client', torrents.dispose);
  }

  Future<void> _shutdownStep(
    String stage,
    FutureOr<void> Function() cleanup,
  ) async {
    try {
      await cleanup();
    } catch (_) {
      // Third-party errors may contain URLs, cookies or credentials.
      debugPrint('Mumpa shutdown: $stage failed; continuing cleanup.');
    }
  }

  void _disposeStep(String stage, VoidCallback cleanup) {
    try {
      cleanup();
    } catch (_) {
      debugPrint('Mumpa shutdown: $stage failed; continuing cleanup.');
    }
  }

  Future<void> _disposeCatalog() =>
      _catalogDisposal ??= _shutdownStep('catalog browser', catalog.dispose);
  Future<void> _stopJackett() =>
      _jackettStop ??= _shutdownStep('Jackett', jackett.stop);
  Future<void> _stopFlareSolverr() =>
      _flaresolverrStop ??= _shutdownStep('FlareSolverr', flaresolverr.stop);

  MusicArtist? artistProfile;
  bool artistLoading = false,
      trackSearchMode = false,
      versionLoading = false,
      cacheBusy = false;
  String? artistError, metadataError, versionError, versionStatus;
  CacheStats? cacheStats;
  List<MusicRecording> recordingResults = [];
  MusicRecording? selectedRecording;
  List<TrackVariant> trackVariants = [];
  String? versionFormat;
  List<String> get versionFormats =>
      trackVariants.map((variant) => variant.format).toSet().toList()..sort();
  List<TrackVariant> get visibleTrackVariants => trackVariants
      .where(
        (variant) => versionFormat == null || variant.format == versionFormat,
      )
      .toList();
  void setVersionFormat(String? format) {
    if (format != null && !versionFormats.contains(format)) return;
    versionFormat = format;
    notifyListeners();
  }

  int _artistRequest = 0, _versionRequest = 0;
  SourceOperation? _versionOperation;
  SourceOperation? _artistOperation;
  List<Track> get artistTracks => library.tracks
      .where(
        (t) =>
            normalizeMusicName(t.artist) ==
                normalizeMusicName(selectedArtist ?? '') ||
            normalizeMusicName(t.albumArtist ?? '') ==
                normalizeMusicName(selectedArtist ?? '') ||
            artistProfile?.matches(t.artist) == true ||
            artistProfile?.matches(t.albumArtist ?? '') == true,
      )
      .toList();
  List<Album> get artistAlbums => groupAlbums(artistTracks);
  List<Track> get artistSearchTracks =>
      filterCollectionTracks(artistTracks, localQuery(artistSearchScope));
  List<Album> get artistSearchAlbums =>
      filterAlbums(artistAlbums, localQuery(artistSearchScope));
  List<MusicReleaseGroup> get artistSearchDiscography => filterReleaseGroups(
    artistProfile?.albums ?? const [],
    localQuery(artistSearchScope),
  );
  List<MusicRecording> get artistSearchRecordings => filterRecordings(
    artistProfile?.recordings ?? const [],
    localQuery(artistSearchScope),
  );

  Future<void> refreshMetadataCache() async {
    cacheStats = await metadata.cache.stats();
    if (!_disposed) notifyListeners();
  }

  Future<void> setDownloadConcurrency(int value) async {
    await run('Сохраняем настройки загрузок', () async {
      await downloads.setMaxConcurrentDownloads(value);
    });
  }

  Future<void> setMetadataCacheLimit(int megabytes) async {
    if (megabytes < 16 || megabytes > 4096 || cacheBusy) return;
    cacheBusy = true;
    notifyListeners();
    try {
      await metadata.cache.setMaxBytes(megabytes * 1024 * 1024);
      await library.setSetting('metadataCacheMb', megabytes);
      await refreshMetadataCache();
    } catch (_) {
      reportError('Не удалось изменить размер кеша.');
    } finally {
      cacheBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> clearMetadataCache() async {
    if (cacheBusy) return;
    cacheBusy = true;
    notifyListeners();
    cancelVersionSearch();
    ++_artistRequest;
    _artistOperation?.cancel();
    _artistOperation = null;
    artistLoading = false;
    _searchDebounce?.cancel();
    ++_searchId;
    _searchOperation?.cancel();
    _searchOperation = null;
    searching = false;
    searchCorrectionCandidate = null;
    try {
      torrentArtwork.cancelPending();
      await metadata.cache.clear();
      trackVariants = [];
      versionFormat = null;
      await refreshMetadataCache();
      reportMessage('Кеш обложек и метаданных очищен.');
    } catch (_) {
      reportError('Не удалось очистить кеш.');
    } finally {
      cacheBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  bool cloudflareEnabled = false;
  JackettConnection? jackettConnection;
  List<SearchRelease> sourceFeed = [];
  List<({String id, String name})> configuredIndexers = [];
  String? get indexerNotice =>
      configuredIndexers.any((i) => i.id == 'rutracker-ru') &&
          !configuredIndexers.any((i) => i.id == 'rutracker')
      ? 'Подключён RuTracker.RU. Это другой сайт, чем RuTracker.org. Для каталога RuTracker.org добавь именно этот индексатор в Jackett и войди в свой аккаунт.'
      : null;
  String? indexerError;
  bool indexerLoading = false;
  bool get indexerConnected =>
      (library.settings['indexerUrl'] as String? ?? '').isNotEmpty;
  bool catalogLoading = false,
      catalogNeedsConnection = false,
      catalogNeedsLogin = false;
  String? catalogError, catalogNextPath;
  List<CatalogSection> catalogSections = [], catalogTrail = [];
  List<SearchRelease> catalogReleases = [];
  int _catalogId = 0;
  bool get usesIndexer => library.settings['searchProvider'] != 'rutracker';
  AppPage page = AppPage.home;
  LibraryFilter filter = LibraryFilter.all;
  LibrarySort sort = LibrarySort.added;
  final Map<String, String> _localQueries = {};

  String localQuery(String scope) => _localQueries[scope] ?? '';

  void setLocalQuery(String scope, String value) {
    if (localQuery(scope) == value) return;
    if (value.isEmpty) {
      _localQueries.remove(scope);
    } else {
      _localQueries[scope] = value;
    }
    notifyListeners();
  }

  String get artistSearchScope =>
      'artist:${normalizeMusicName(selectedArtist ?? '')}';

  LocalMusicResults _localResults(
    String scope, {
    required List<Track> tracks,
    required List<Album> albums,
    required List<MusicPlaylist> playlists,
  }) {
    final query = localQuery(scope);
    return (
      artists: filterArtistNames(tracks, query),
      albums: filterAlbums(albums, query),
      playlists: filterPlaylists(playlists, query, tracks),
      tracks: filterCollectionTracks(tracks, query),
    );
  }

  LocalMusicResults get librarySearchResults => _localResults(
    'library',
    tracks: library.tracks
        .where(
          (track) => switch (filter) {
            LibraryFilter.offline => track.offline,
            LibraryFilter.torrents => track.source == TrackSource.torrent,
            _ => true,
          },
        )
        .toList(),
    albums: albums,
    playlists: library.playlists,
  );

  LocalMusicResults get likedSearchResults {
    final albums = library.favoriteAlbums;
    final playlists = library.favoritePlaylists;
    final indexed = {for (final track in library.tracks) track.id: track};
    final tracks = {
      for (final track in likedTracks) track.id: track,
      for (final album in albums)
        for (final track in album.tracks) track.id: track,
      for (final playlist in playlists)
        for (final id in playlist.trackIds)
          if (indexed[id] case final Track track) track.id: track,
    }.values.toList();
    return _localResults(
      'liked',
      tracks: tracks,
      albums: albums,
      playlists: playlists,
    );
  }

  String query = '';
  String? selectedAlbum, selectedPlaylist, selectedArtist;
  String? _selectedAlbumAnchor;
  Set<String>? _selectedAlbumTrackIds;
  String? albumPlaylistId;
  String? busy, message, error, engineVersion;
  List<TorrentNetwork> torrentNetworks = const [];
  String get torrentInterface =>
      library.settings['torrentInterface'] as String? ?? '';
  Future<void> refreshTorrentNetworks() async {
    try {
      torrentNetworks = List.unmodifiable(await listTorrentNetworks());
      if (!_disposed) notifyListeners();
    } catch (e) {
      reportError('Не удалось прочитать сетевые интерфейсы: $e');
    }
  }

  Future<void> saveTorrentInterface(String name) async {
    await run('Сохраняем сетевой интерфейс', () async {
      await resolveTorrentNetwork(name);
      await library.setSetting('torrentInterface', name);
      message =
          'Сетевой интерфейс сохранён. Перезапустите Mumpa для применения.';
    });
  }

  List<SearchRelease> releases = [];
  bool searching = false;
  int _searchId = 0;
  Timer? _searchDebounce;
  bool _disposed = false;
  bool searchCompleted = false;
  String? correctedSearchQuery, searchCorrectionCandidate;
  List<String> searchCorrectionSuggestions = const [];
  SourceOperation? _opening;
  SourceOperation? _searchOperation;
  bool get canCancelOpening => _opening != null;
  void cancelOpening() => _opening?.cancel();
  final List<_NavigationEntry> _history = [];
  int _navigationEntryId = 0, _nextNavigationEntryId = 1;
  int get navigationEntryId => _navigationEntryId;
  bool get canGoBack => _history.isNotEmpty;
  Iterable<int> get navigationEntryIds => [
    ..._history.map((entry) => entry.id),
    _navigationEntryId,
  ];
  Map<String, String>? _artworkByAlbum;
  String? artworkForTrack(Track track) {
    if (track.artPath != null) return track.artPath;
    _artworkByAlbum ??= {
      for (final item in library.tracks)
        if (item.artPath != null) item.albumKey: item.artPath!,
    };
    return _artworkByAlbum![track.albumKey];
  }

  void _changed() {
    _artworkByAlbum = null;
    notifyListeners();
  }

  String? _autoCachedId;
  String? _playbackError;
  String? _playbackStatus;
  void _onPlayback() {
    if (_playbackStatus != playback.connectionStatus) {
      _playbackStatus = playback.connectionStatus;
      notifyListeners();
    }
    if (playback.error != _playbackError) {
      if (error == _playbackError) error = null;
      _playbackError = playback.error;
      if (_playbackError != null) error = _playbackError;
      notifyListeners();
    }
    final track = playback.current;
    if (track == null ||
        track.id == _autoCachedId ||
        !playback.playing ||
        playback.loading ||
        library.settings['autoCache'] != true) {
      return;
    }
    if (track.source == TrackSource.torrent && track.cachedPath == null) {
      _autoCachedId = track.id;
      downloads.enqueue([track], priority: true);
    }
  }

  void reportError(String value) {
    error = value;
    notifyListeners();
  }

  void reportMessage(String value) {
    message = value;
    notifyListeners();
  }

  List<Album> get albums {
    var albums = groupAlbums(library.tracks);
    if (filter == LibraryFilter.offline) {
      albums = albums.where((a) => a.offline).toList();
    }
    if (filter == LibraryFilter.torrents) {
      albums = albums.where((a) => a.torrent).toList();
    }
    if (sort == LibrarySort.name) {
      albums.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    }
    if (sort == LibrarySort.artist) {
      albums.sort(
        (a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()),
      );
    }
    if (sort == LibrarySort.added) albums = albums.reversed.toList();
    return albums;
  }

  List<Track> get searchTracks =>
      query.trim().isEmpty ? [] : filterCollectionTracks(library.tracks, query);
  Album? get album {
    final currentKey = library.byId(_selectedAlbumAnchor ?? '')?.albumKey;
    final key = currentKey ?? selectedAlbum;
    final tracks = _selectedAlbumTrackIds == null
        ? library.tracks
        : library.tracks.where(
            (track) => _selectedAlbumTrackIds!.contains(track.id),
          );
    return groupAlbums(tracks).where((a) => a.id == key).firstOrNull;
  }

  MusicPlaylist? get playlist =>
      library.playlists.where((l) => l.id == selectedPlaylist).firstOrNull;
  MusicPlaylist? get currentPlaylist => library.playlists
      .where((l) => l.id == playback.contextPlaylistId)
      .firstOrNull;
  List<Track> get playlistTracks =>
      playlist?.trackIds.map(library.byId).whereType<Track>().toList() ?? [];
  List<Track> get likedTracks => library.favoriteTracks;
  List<Track> get offlineTracks =>
      library.tracks.where((t) => t.cachedPath != null).toList();
  List<Track> get offlineSearchTracks =>
      filterCollectionTracks(offlineTracks, localQuery('downloads'));
  List<DownloadJob> get downloadSearchJobs {
    final jobs = downloads.jobs;
    final matches = filterCollectionTracks(
      jobs.map((job) => job.track).toList(),
      localQuery('downloads'),
    ).map((track) => track.id).toSet();
    return jobs.where((job) => matches.contains(job.track.id)).toList();
  }

  List<Track> get recentTracks =>
      library.recent.map(library.byId).whereType<Track>().toList();
  List<Album> get recentAlbums {
    final seen = <String>{};
    final all = groupAlbums(library.tracks);
    return recentTracks
        .where((t) => seen.add(t.albumKey))
        .map((t) => all.firstWhere((a) => a.id == t.albumKey))
        .toList();
  }

  void navigate(AppPage value, {bool newEntry = false}) {
    _navigate(value, newEntry: newEntry);
  }

  void _navigate(AppPage value, {bool newEntry = false, VoidCallback? select}) {
    if (page != value || newEntry) {
      _history.add(_NavigationEntry(this, _navigationEntryId));
      if (_history.length > 64) _history.removeAt(0);
      _navigationEntryId = _nextNavigationEntryId++;
      // These requests belong to the outgoing view. Back will restart a
      // pending request with the restored query, rather than accept old data.
      if (page == AppPage.artist) {
        ++_artistRequest;
        _artistOperation?.cancel();
        _artistOperation = null;
        artistLoading = false;
      }
      if (page == AppPage.search) {
        _cancelNavigationSearch();
        ++_catalogId;
        catalogLoading = false;
      }
    }
    select?.call();
    page = value;
    error = null;
    notifyListeners();
    if (value == AppPage.settings) unawaited(refreshMetadataCache());
  }

  void back() {
    if (!canGoBack || _disposed) return;
    final entry = _history.removeLast();
    _cancelNavigationSearch();
    ++_catalogId;
    ++_artistRequest;
    _artistOperation?.cancel();
    _artistOperation = null;
    _navigationEntryId = entry.id;
    page = entry.page;
    selectedAlbum = entry.album.id;
    _selectedAlbumAnchor = entry.album.anchor;
    _selectedAlbumTrackIds = entry.album.tracks;
    albumPlaylistId = entry.album.playlistId;
    selectedPlaylist = entry.playlistId;
    selectedArtist = entry.artist.name;
    artistProfile = entry.artist.profile;
    artistError = entry.artist.error;
    artistLoading = page == AppPage.artist && entry.artist.pending;
    query = entry.search.query;
    trackSearchMode = entry.search.tracks;
    recordingResults = List.of(entry.search.recordings);
    selectedRecording = entry.search.recording;
    trackVariants = List.of(entry.search.variants);
    versionFormat = entry.search.format;
    metadataError = entry.search.metadataError;
    versionError = entry.search.versionError;
    versionStatus = entry.search.status;
    searchCompleted = entry.search.completed;
    releases = List.of(entry.search.releases);
    correctedSearchQuery = entry.search.correction;
    // A restored view has no matching in-flight correction request. A resumed
    // search will set its own candidate once that request actually starts.
    searchCorrectionCandidate = null;
    searchCorrectionSuggestions = List.of(entry.search.suggestions);
    catalogSections = List.of(entry.catalog.sections);
    catalogTrail = List.of(entry.catalog.trail);
    catalogReleases = List.of(entry.catalog.releases);
    catalogNextPath = entry.catalog.next;
    catalogError = entry.catalog.error;
    catalogNeedsConnection = entry.catalog.connection;
    catalogNeedsLogin = entry.catalog.login;
    catalogLoading = false;
    filter = entry.filter;
    sort = entry.sort;
    error = null;
    notifyListeners();
    if (artistLoading && selectedArtist != null) {
      unawaited(_loadArtist(selectedArtist!));
    } else if (page == AppPage.search) {
      if (entry.search.versionsPending && selectedRecording != null) {
        unawaited(findRecordingVersions(selectedRecording!));
      } else if (entry.search.pending && query.trim().isNotEmpty) {
        unawaited(searchSources());
      } else if (entry.catalog.pending &&
          query.trim().isEmpty &&
          catalogTrail.isNotEmpty) {
        unawaited(browseCatalog(catalogTrail.last, back: true));
      }
    }
    if (page == AppPage.settings) unawaited(refreshMetadataCache());
  }

  void _cancelNavigationSearch() {
    _searchDebounce?.cancel();
    ++_searchId;
    _searchOperation?.cancel();
    _searchOperation = null;
    searching = false;
    searchCorrectionCandidate = null;
    ++_versionRequest;
    _versionOperation?.cancel();
    _versionOperation = null;
    versionLoading = false;
  }

  void openAlbum(Album value, {String? playlistId}) {
    final ids = value.tracks.map((track) => track.id).toSet();
    final different =
        page == AppPage.album &&
        (album?.id != value.id ||
            albumPlaylistId != playlistId ||
            !setEquals(_selectedAlbumTrackIds, ids));
    _navigate(
      AppPage.album,
      newEntry: different,
      select: () {
        selectedAlbum = value.id;
        _selectedAlbumAnchor = value.tracks.first.id;
        _selectedAlbumTrackIds = ids;
        albumPlaylistId = playlistId;
      },
    );
  }

  void openPlaylist(MusicPlaylist value) {
    _navigate(
      AppPage.playlist,
      newEntry: page == AppPage.playlist && selectedPlaylist != value.id,
      select: () => selectedPlaylist = value.id,
    );
  }

  Future<void> playCollection(
    List<Track> tracks, {
    int index = 0,
    String? playlistId,
  }) =>
      playback.playTracks(tracks, index: index, contextPlaylistId: playlistId);

  Future<void> addToCurrentPlaylist(Track track) async {
    final target = currentPlaylist;
    if (target == null) return;
    await library.addToPlaylist(target.id, [track.id]);
    if (!playback.queue.any((t) => t.id == track.id)) {
      playback.enqueue(track);
    }
    reportMessage('Добавлено в «${target.name}»');
  }

  Future<MusicPlaylist?> openTorrentCollection(
    TorrentInfo info, {
    String? link,
    String? title,
    String? artist,
  }) => run('Открываем коллекцию…', () async {
    final identity = parseReleaseIdentity(title ?? info.title);
    final tracks = torrents.tracks(
      info,
      link: link,
      album: title,
      artist:
          artist ??
          identity?.artist ??
          inferredReleaseArtist(title ?? info.title),
    );
    if (tracks.isEmpty) {
      throw const FormatException('В этой коллекции нет аудиотреков.');
    }
    final collection = await library.openSourceCollection(
      hash: info.hash,
      name: title ?? info.title,
      tracks: tracks,
    );
    openPlaylist(collection);
    return collection;
  });

  Future<void> openRelease(SearchRelease release) async {
    final opened = await inspectRelease(release);
    if (opened != null) {
      await openTorrentCollection(
        opened.info,
        link: opened.link,
        title: release.title,
      );
    }
  }

  void openArtist(String value) {
    _navigate(
      AppPage.artist,
      newEntry: page == AppPage.artist && selectedArtist != value,
      select: () {
        _artistOperation?.cancel();
        selectedArtist = value;
        artistProfile = null;
        artistError = null;
        artistLoading = true;
      },
    );
    unawaited(_loadArtist(value));
  }

  Future<void> _loadArtist(String name) async {
    final id = ++_artistRequest;
    final operation = SourceOperation();
    _artistOperation = operation;
    try {
      final profile = await metadata.artist(name, operation: operation);
      if (_disposed || id != _artistRequest) return;
      artistProfile = profile;
      if (profile == null) {
        artistError = 'Исполнитель пока не найден в MusicBrainz.';
      }
    } catch (e) {
      if (!_disposed && id == _artistRequest) {
        artistError = e is HttpException
            ? e.message
            : 'Музыкальная база сейчас недоступна.';
      }
    } finally {
      if (!_disposed && id == _artistRequest) {
        artistLoading = false;
        notifyListeners();
      }
    }
  }

  void searchAlbumMetadata(MusicReleaseGroup album) {
    openGlobalSearch('${album.artist} ${album.title}', tracks: false);
  }

  void setTrackSearchMode(bool enabled) {
    if (trackSearchMode == enabled) return;
    trackSearchMode = enabled;
    setQuery(query);
  }

  void cancelVersionSearch() => _cancelVersionSearch();

  void _cancelVersionSearch({bool notify = true}) {
    ++_versionRequest;
    _versionOperation?.cancel();
    _versionOperation = null;
    versionLoading = false;
    if (notify && !_disposed) notifyListeners();
  }

  Future<void> findRecordingVersions(MusicRecording recording) async {
    navigate(
      AppPage.search,
      newEntry: page == AppPage.search && selectedRecording?.id != recording.id,
    );
    versionFormat = null;
    cancelVersionSearch();
    _searchDebounce?.cancel();
    _searchOperation?.cancel();
    ++_searchId;
    searching = false;
    trackSearchMode = true;
    selectedRecording = recording;
    trackVariants = [];
    versionError = null;
    versionStatus = null;
    if (!usesIndexer || !indexerConnected) {
      versionError =
          'Для поиска файлов треков подключи Jackett. Раздачи напрямую можно открыть в режиме «Альбомы и коллекции».';
      notifyListeners();
      return;
    }
    final id = ++_versionRequest;
    final operation = SourceOperation();
    _versionOperation = operation;
    versionLoading = true;
    notifyListeners();
    try {
      recording = await metadata.recordingWithAlbums(
        recording,
        operation: operation,
      );
      if (!_disposed && id == _versionRequest) selectedRecording = recording;
      final service = TrackSearchService(
        indexer: indexer,
        torrents: torrents,
        cache: metadata.cache,
        workDirectory: Directory('${library.root.path}/source-search-temp'),
      );
      final results = await operation
          .wait(
            service.find(
              recording,
              endpoint: library.settings['indexerUrl'] as String,
              key: library.settings['indexerKey'] as String? ?? '',
              operation: operation,
              onStatus: (status) {
                if (!_disposed && id == _versionRequest) {
                  versionStatus = status;
                  notifyListeners();
                }
              },
              onResults: (results) {
                if (!_disposed && id == _versionRequest) {
                  trackVariants = results;
                  notifyListeners();
                }
              },
            ),
          )
          .timeout(
            const Duration(seconds: 120),
            onTimeout: () {
              operation.cancel();
              throw TimeoutException('Поиск версий занял больше двух минут.');
            },
          );
      if (!_disposed && id == _versionRequest) {
        trackVariants = results;
        if (results.isEmpty) {
          versionError =
              'В проверенных коллекциях подходящих аудиофайлов не найдено. Попробуй поиск по альбому: база и имена файлов могут различаться.';
        }
      }
    } on SourceCancelled {
      /* A new selection owns the view. */
    } catch (e) {
      if (!_disposed && id == _versionRequest) {
        versionError = e is HttpException
            ? e.message
            : e is TimeoutException
            ? 'Поиск версий занял больше двух минут. Уже найденные варианты доступны.'
            : 'Не удалось найти версии трека.';
      }
    } finally {
      operation.cancel();
      if (!_disposed && id == _versionRequest) {
        versionLoading = false;
        notifyListeners();
      }
    }
  }

  Future<({MusicPlaylist playlist, List<Track> tracks, Track selected})?>
  _importVariant(TrackVariant variant) =>
      run('Открываем выбранную версию…', () async {
        var source = variant.source;
        if (!await File(source).exists()) {
          final resolved = await indexer.resolve(
            variant.release.link,
            Directory('${library.root.path}/torrents'),
          );
          if (!resolved.file) {
            throw const FormatException('Выбери раздачу с torrent-файлом.');
          }
          source = resolved.source;
        }
        final info = await torrents.upload(source);
        // The metainfo ordinal is not a stream ID: TorrServer sorts its file
        // list. Match immutable content identity, then use its returned ID.
        final readyMatches = info.files
            .where(
              (file) =>
                  file.path == variant.track.torrentPath &&
                  file.bytes == variant.track.bytes &&
                  isAudioPath(file.path),
            )
            .toList();
        if (info.hash != variant.info.hash || readyMatches.length != 1) {
          throw const FormatException(
            'Список файлов раздачи изменился. Повтори поиск версий.',
          );
        }
        final readyAudio = readyMatches.single;
        final tracks = torrents.tracks(
          info,
          album: variant.track.album,
          artist: variant.track.artist,
        );
        final playlist = await library.openSourceCollection(
          hash: info.hash,
          name: variant.release.title,
          tracks: tracks,
        );
        final savedTracks = playlist.trackIds
            .map(library.byId)
            .whereType<Track>()
            .toList();
        final savedMatches = library.tracks
            .where(
              (track) =>
                  track.torrentHash == info.hash &&
                  track.torrentIndex == readyAudio.index &&
                  track.torrentPath == readyAudio.path,
            )
            .toList();
        if (savedMatches.length != 1) {
          throw const FormatException('Трек отсутствует в коллекции.');
        }
        final selected = savedMatches.single;
        // Source-playlist edits remain persistent. Explicitly choosing a
        // removed file may still play it or enqueue it without restoring it
        // to that playlist; include it only in this playback queue snapshot.
        if (!savedTracks.any((track) => track.id == selected.id)) {
          savedTracks.add(selected);
        }
        return (playlist: playlist, tracks: savedTracks, selected: selected);
      });

  Future<void> playTrackVariant(TrackVariant variant) async {
    final imported = await _importVariant(variant);
    if (imported == null) return;
    openPlaylist(imported.playlist);
    await playback.playTracks(
      imported.tracks,
      index: imported.tracks.indexWhere((t) => t.id == imported.selected.id),
      contextPlaylistId: imported.playlist.id,
    );
  }

  Future<void> enqueueTrackVariant(TrackVariant variant) async {
    final imported = await _importVariant(variant);
    if (imported == null) return;
    playback.enqueue(imported.selected);
    reportMessage('Трек добавлен в очередь.');
  }

  /// Switching the results page and updating the shared field is one change,
  /// so listeners never replace an in-progress edit with the previous query.
  void openGlobalSearch(String value, {bool? tracks}) {
    _navigate(
      AppPage.search,
      select: () {
        if (tracks != null) trackSearchMode = tracks;
        _setQuery(value, notify: false);
      },
    );
  }

  void setQuery(String value) => _setQuery(value);

  void _setQuery(String value, {bool notify = true}) {
    _searchDebounce?.cancel();
    _searchOperation?.cancel();
    query = value;
    _cancelVersionSearch(notify: false);
    selectedRecording = null;
    trackVariants = [];
    versionFormat = null;
    recordingResults = [];
    metadataError = null;
    releases = [];
    correctedSearchQuery = null;
    searchCorrectionCandidate = null;
    searchCorrectionSuggestions = const [];
    ++_searchId;
    searchCompleted = false;
    searching = false;
    if (query.trim().isNotEmpty &&
        (trackSearchMode || indexerConnected || !usesIndexer)) {
      searching = true;
      _searchDebounce = Timer(const Duration(milliseconds: 600), searchSources);
    }
    if (notify) notifyListeners();
  }

  void setFilter(LibraryFilter value) {
    filter = value;
    notifyListeners();
  }

  void setSort(LibrarySort value) {
    sort = value;
    notifyListeners();
  }

  void clearMessage() {
    message = null;
    error = null;
    notifyListeners();
  }

  Future<T?> run<T>(String label, Future<T> Function() action) async {
    if (busy != null) return null;
    busy = label;
    error = null;
    message = null;
    notifyListeners();
    try {
      return await action();
    } catch (e) {
      if (e is SourceCancelled) {
        message = 'Открытие альбома отменено.';
      } else if (e is HttpException) {
        error = e.message;
      } else if (e is TimeoutException) {
        error =
            'Источник не ответил вовремя. Попробуй другую раздачу или повтори запрос.';
      } else {
        error = e.toString();
      }
      return null;
    } finally {
      busy = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> importFiles() async {
    await run('Выберите музыку', () async {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: audioExtensions.toList(),
      );
      if (files.isEmpty) return;
      final imported = await library.importPaths(
        files.map((f) => f.path).whereType<String>().toList(),
        copy: Platform.isAndroid,
        progress: (done, total) {
          busy = 'Импорт: $done из $total';
          notifyListeners();
        },
      );
      message = 'Добавлено треков: ${imported.length}';
      navigate(AppPage.library);
    });
  }

  Future<void> importFolder() async {
    await run('Выберите папку с альбомами', () async {
      List<String> paths;
      if (Platform.isAndroid) {
        paths =
            (await const MethodChannel(
              'app.mumpa/engine',
            ).invokeListMethod<String>('importFolder')) ??
            [];
      } else {
        final folder = await FilePicker.getDirectoryPath(
          dialogTitle: 'Папка с музыкой',
        );
        paths = folder == null ? [] : [folder];
      }
      if (paths.isEmpty) return;
      final tracks = await library.importPaths(
        paths,
        progress: (done, total) {
          busy = 'Импорт: $done из $total';
          notifyListeners();
        },
      );
      message = 'Добавлено треков: ${tracks.length}';
      navigate(AppPage.library);
    });
  }

  Future<TorrentInfo?> inspectTorrent(String link, {bool file = false}) => run(
    'Получаем файлы альбома…',
    () => file ? torrents.upload(link) : torrents.add(link),
  );
  Future<TorrentInfo?> pickTorrent() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['torrent'],
    );
    if (file?.path == null) return null;
    return inspectTorrent(file!.path!, file: true);
  }

  Future<void> addTorrent(
    TorrentInfo info,
    Set<int> selected, {
    String? link,
    String? album,
    String? artist,
  }) async {
    await run('Добавляем альбом', () async {
      final tracks = torrents
          .tracks(info, link: link, album: album, artist: artist)
          .where((t) => selected.contains(t.torrentIndex))
          .toList();
      await library.upsert(tracks);
      message = 'Альбом добавлен · ${tracks.length} треков';
      if (tracks.isNotEmpty) openAlbum(Album(tracks));
    });
  }

  Iterable<String> _knownSearchNames() sync* {
    final profile = artistProfile;
    if (profile != null) {
      yield profile.name;
      yield* profile.aliases;
      for (final album in profile.albums) {
        yield album.title;
        yield '${profile.name} ${album.title}';
      }
    }
    for (final track in library.tracks) {
      yield track.artist;
      if (track.albumArtist != null) yield track.albumArtist!;
      yield track.album;
      yield '${track.albumArtist ?? track.artist} ${track.album}';
    }
    for (final release in [...sourceFeed, ...catalogReleases]) {
      final artist = inferredReleaseArtist(release.title);
      if (artist != null) yield artist;
      final identity = parseReleaseIdentity(release.title);
      if (identity != null) {
        yield identity.album;
        yield '${identity.artist} ${identity.album}';
      }
    }
  }

  Future<void> searchSources() async {
    _searchDebounce?.cancel();
    _searchOperation?.cancel();
    correctedSearchQuery = null;
    searchCorrectionCandidate = null;
    searchCorrectionSuggestions = const [];
    final requestedQuery = query.trim();
    if (requestedQuery.isEmpty) {
      searching = false;
      notifyListeners();
      return;
    }
    if (trackSearchMode) {
      final id = ++_searchId;
      final operation = SourceOperation();
      _searchOperation = operation;
      searching = true;
      metadataError = null;
      searchCompleted = false;
      notifyListeners();
      try {
        final results = await metadata.searchRecordings(
          requestedQuery,
          operation: operation,
        );
        if (!_disposed && id == _searchId) {
          recordingResults = results;
          searchCompleted = true;
        }
      } catch (e) {
        if (!_disposed && id == _searchId) {
          metadataError = e is HttpException
              ? e.message
              : 'Поиск MusicBrainz недоступен.';
        }
      } finally {
        if (!_disposed && id == _searchId) {
          searching = false;
          notifyListeners();
        }
      }
      return;
    }
    final operation = SourceOperation();
    _searchOperation = operation;
    final endpoint = library.settings['indexerUrl'] as String? ?? '';
    if (usesIndexer && endpoint.isEmpty) {
      searching = false;
      searchCompleted = true;
      message =
          'Настрой Jackett: добавь RuTracker и войди в свой аккаунт. На Windows можно запустить Jackett из Mumpa.';
      notifyListeners();
      return;
    }
    final id = ++_searchId;
    searching = true;
    searchCompleted = false;
    error = null;
    notifyListeners();
    try {
      late List<SearchRelease> items;
      if (usesIndexer) {
        final result = await searchMusicWithCorrections(
          query: requestedQuery,
          knownNames: _knownSearchNames(),
          operation: operation,
          search: (phrase) => indexer.search(
            endpoint,
            library.settings['indexerKey'] as String? ?? '',
            phrase,
            operation: operation,
          ),
          suggestArtists: (phrase) =>
              metadata.suggestArtistNames(phrase, operation: operation),
          onCorrectionAttempt: (phrase) {
            if (_disposed || id != _searchId) return;
            searchCorrectionCandidate = phrase;
            notifyListeners();
          },
        );
        operation.check();
        if (_disposed || id != _searchId) return;
        correctedSearchQuery = result.correctedQuery;
        searchCorrectionSuggestions = result.suggestions;
        items = result.releases;
      } else {
        items = (await catalog.search(requestedQuery)).releases;
      }
      if (!_disposed && id == _searchId) {
        releases = items;
        searchCompleted = true;
        catalogNeedsConnection = false;
        catalogError = null;
      }
    } on SourceCancelled {
      // A newer query owns the visible results.
    } catch (e) {
      if (!_disposed && id == _searchId) {
        if (!usesIndexer) {
          _catalogFailure(e);
        } else {
          error = e is HttpException ? e.message : e.toString();
        }
      }
    } finally {
      if (!_disposed && id == _searchId) {
        searching = false;
        searchCorrectionCandidate = null;
        notifyListeners();
      }
    }
  }

  Future<void> initializeSources() async {
    if (library.settings['managedJackett'] == true && Platform.isWindows) {
      try {
        await _startJackett();
      } catch (e) {
        indexerError = e.toString();
        notifyListeners();
        return;
      }
    }
    if (indexerConnected) await refreshSourceFeed();
  }

  Future<JackettConnection> _startJackett() async {
    final connection = await jackett.start();
    jackettConnection = connection;
    if (await flaresolverr.isEnabled()) {
      final solverUrl = await flaresolverr.start();
      await jackett.configureFlareSolverr(connection, solverUrl);
      cloudflareEnabled = true;
    }
    await library.setSetting('indexerUrl', connection.torznabUrl);
    await library.setSetting('indexerKey', connection.apiKey);
    await library.setSetting('managedJackett', true);
    await library.setSetting('searchProvider', 'torznab');
    return connection;
  }

  Future<void> setSearchProvider(String provider) async {
    setQuery(query);
    await library.setSetting('searchProvider', provider);
    if (provider == 'rutracker') {
      if (catalog.sections.isEmpty) await initializeCatalog();
    } else {
      await refreshSourceFeed();
    }
  }

  Future<JackettConnection?> prepareJackett() =>
      run('Запускаем Jackett…', _startJackett);

  Future<void> prepareCloudflare() async {
    await run('Настраиваем проверку Cloudflare…', () async {
      final connection = await _startJackett();
      final solverUrl = await flaresolverr.enable();
      await jackett.configureFlareSolverr(connection, solverUrl);
      cloudflareEnabled = true;
      message =
          'FlareSolverr подключён. Повтори сохранение или проверку RuTracker.org в Jackett.';
    });
  }

  Future<void> finishJackettSetup() async {
    final connection = jackettConnection;
    if (connection == null) return;
    await run('Проверяем RuTracker в Jackett', () async {
      final configured = await jackett.isRuTrackerConfigured(connection);
      message = configured
          ? 'RuTracker подключён через Jackett.'
          : 'Jackett готов. Добавь индексатор RuTracker.org и сохрани настройки аккаунта.';
    });
    await refreshSourceFeed();
    if (query.trim().isNotEmpty) await searchSources();
  }

  Future<void> refreshSourceFeed() async {
    if (!indexerConnected || indexerLoading) return;
    indexerLoading = true;
    indexerError = null;
    notifyListeners();
    try {
      try {
        configuredIndexers = await indexer.configuredIndexers(
          library.settings['indexerUrl'] as String,
          library.settings['indexerKey'] as String? ?? '',
        );
      } catch (_) {
        // Other Torznab implementations may not provide Jackett's inventory.
      }
      sourceFeed = await indexer.search(
        library.settings['indexerUrl'] as String,
        library.settings['indexerKey'] as String? ?? '',
        '',
      );
    } catch (e) {
      indexerError = e.toString();
    } finally {
      indexerLoading = false;
      notifyListeners();
    }
  }

  Future<void> saveIndexer(String endpoint, String key) async {
    await run('Проверяем Jackett…', () async {
      var uri = Uri.tryParse(endpoint.trim());
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw const FormatException(
          'Укажи корректный HTTP/HTTPS адрес Jackett.',
        );
      }
      if (uri.path.isEmpty || uri.path == '/' || uri.path.startsWith('/UI/')) {
        uri = uri.replace(path: '/api/v2.0/indexers/all/results/torznab/api');
      }
      final apiKey = key.trim().isNotEmpty
          ? key.trim()
          : uri.queryParameters['apikey'] ?? '';
      final params = {...uri.queryParameters}..remove('apikey');
      uri = uri.replace(queryParameters: params.isEmpty ? null : params);
      await indexer.check(uri.toString(), apiKey);
      await library.setSetting('indexerUrl', uri.toString());
      await library.setSetting('indexerKey', apiKey);
      await library.setSetting('managedJackett', false);
      await library.setSetting('searchProvider', 'torznab');
      message = 'Jackett подключён. Поиск ограничен музыкальными раздачами.';
    });
    if (indexerConnected) await refreshSourceFeed();
  }

  void _catalogFailure(Object e) {
    catalogError = e is CatalogException
        ? e.message
        : 'Не удалось загрузить RuTracker. Проверь соединение и повтори попытку.';
    catalogNeedsConnection = e is CatalogException && e.connect;
    catalogNeedsLogin =
        catalogNeedsConnection &&
        RegExp(
          'вход|войди|аккаунт',
          caseSensitive: false,
        ).hasMatch(catalogError!);
  }

  Future<void> initializeCatalog() async {
    await catalog.restore();
    catalogSections = catalog.sections;
    notifyListeners();
    await refreshCatalog();
  }

  Future<void> refreshCatalog() async {
    final id = ++_catalogId;
    catalogLoading = true;
    catalogError = null;
    notifyListeners();
    try {
      final sections = await catalog.refresh();
      if (id != _catalogId) return;
      catalogSections = sections;
      catalogTrail = [];
      catalogReleases = [];
      catalogNextPath = null;
      catalogNeedsConnection = false;
    } catch (e) {
      if (id == _catalogId) _catalogFailure(e);
    } finally {
      if (id == _catalogId) {
        catalogLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> browseCatalog(
    CatalogSection section, {
    bool back = false,
  }) async {
    navigate(AppPage.search, newEntry: !back);
    trackSearchMode = false;
    setQuery('');
    final id = ++_catalogId;
    if (!back) catalogTrail.add(section);
    catalogSections = section.children;
    catalogReleases = [];
    catalogNextPath = null;
    catalogError = null;
    if (section.children.isNotEmpty) {
      catalogLoading = false;
      notifyListeners();
      return;
    }
    catalogLoading = true;
    notifyListeners();
    try {
      final listing = await catalog.browse(section.path);
      if (id != _catalogId) return;
      catalogSections = listing.sections;
      catalogReleases = listing.releases;
      catalogNextPath = listing.nextPath;
      catalogNeedsConnection = false;
    } catch (e) {
      if (id == _catalogId) _catalogFailure(e);
    } finally {
      if (id == _catalogId) {
        catalogLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> catalogBack() async {
    if (page == AppPage.search &&
        canGoBack &&
        _history.last.page == AppPage.search &&
        _history.last.catalog.trail.length < catalogTrail.length) {
      back();
      return;
    }
    if (catalogTrail.isNotEmpty) catalogTrail.removeLast();
    if (catalogTrail.isEmpty) {
      ++_catalogId;
      catalogSections = catalog.sections;
      catalogReleases = [];
      catalogNextPath = null;
      catalogLoading = false;
      catalogError = null;
      notifyListeners();
    } else {
      await browseCatalog(catalogTrail.last, back: true);
    }
  }

  Future<void> loadMoreCatalog() async {
    final path = catalogNextPath;
    if (path == null || catalogLoading) return;
    final id = ++_catalogId;
    catalogLoading = true;
    notifyListeners();
    try {
      final listing = await catalog.browse(path);
      if (id != _catalogId) return;
      final seen = catalogReleases.map((r) => r.link).toSet();
      catalogReleases.addAll(listing.releases.where((r) => seen.add(r.link)));
      catalogNextPath = listing.nextPath;
    } catch (e) {
      if (id == _catalogId) _catalogFailure(e);
    } finally {
      if (id == _catalogId) {
        catalogLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> connectCatalog({bool login = true}) async {
    await run(
      login ? 'Вход в RuTracker' : 'Проверка доступа к RuTracker',
      () async {
        await catalog.connect(login: login);
      },
    );
    await refreshCatalog();
    if (query.trim().isNotEmpty) await searchSources();
  }

  Future<({TorrentInfo info, String? link})?> inspectRelease(
    SearchRelease release,
  ) async {
    if (busy != null) return null;
    final operation = SourceOperation();
    _opening = operation;
    void progress(String text) {
      if (_disposed || _opening != operation || operation.cancelled) return;
      busy = text;
      notifyListeners();
    }

    Future<({TorrentInfo info, String? link})> inspect() async {
      if (release.rutracker) {
        final link = await operation.wait(catalog.magnet(release));
        return (
          info: await torrents.add(
            link,
            title: release.title,
            operation: operation,
            onProgress: progress,
          ),
          link: link,
        );
      }
      progress(
        'Получаем torrent-файл из ${release.indexerName.isEmpty ? 'Jackett' : release.indexerName}…',
      );
      final resolved = await indexer.resolve(
        release.link,
        Directory('${library.root.path}/torrents'),
        operation: operation,
      );
      if (resolved.file) {
        return (
          info: await torrents.upload(
            resolved.source,
            operation: operation,
            onProgress: progress,
          ),
          link: null,
        );
      }
      return (
        info: await torrents.add(
          resolved.source,
          title: release.title,
          operation: operation,
          onProgress: progress,
        ),
        link: resolved.source,
      );
    }

    try {
      return await run(
        'Открываем альбом…',
        () => operation
            .wait(inspect())
            .timeout(
              const Duration(seconds: 60),
              onTimeout: () {
                operation.cancel();
                throw const HttpException(
                  'Не удалось открыть альбом за минуту. Проверь источник или выбери другую раздачу.',
                );
              },
            ),
      );
    } finally {
      operation.cancel();
      if (_opening == operation) _opening = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> checkEngine() async {
    await run('Проверяем торрент-движок', () async {
      engineVersion = await torrents.version();
      message = 'Торрент-движок готов: $engineVersion';
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _searchDebounce?.cancel();
    ++_searchId;
    _opening?.cancel();
    _searchOperation?.cancel();
    _artistOperation?.cancel();
    ++_artistRequest;
    ++_versionRequest;
    _versionOperation?.cancel();
    library.removeListener(_changed);
    downloads.removeListener(_changed);
    playback.removeListener(_onPlayback);
    _disposeStep('indexer client', indexer.dispose);
    _disposeStep('torrent artwork', torrentArtwork.dispose);
    _disposeStep('metadata client', metadata.dispose);
    unawaited(_disposeCatalog());
    unawaited(_stopJackett());
    unawaited(_stopFlareSolverr());
    super.dispose();
  }
}
