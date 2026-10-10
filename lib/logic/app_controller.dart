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
import '../domain/models.dart';
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

enum LibraryFilter { all, offline, torrents }

enum LibrarySort { added, name, artist }

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
  }) : indexer = indexer ?? IndexerService(),
       catalog = catalog ?? RuTrackerService(),
       jackett = jackett ?? JackettService(library.root),
       flaresolverr = flaresolverr ?? FlareSolverrService(library.root) {
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
  String query = '';
  String? selectedAlbum, selectedPlaylist, selectedArtist;
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
  SourceOperation? _opening;
  SourceOperation? _searchOperation;
  bool get canCancelOpening => _opening != null;
  void cancelOpening() => _opening?.cancel();
  final List<AppPage> _history = [];
  void _changed() => notifyListeners();
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

  List<Track> get searchTracks => query.trim().isEmpty
      ? []
      : library.tracks
            .where(
              (t) => '${t.title} ${t.artist} ${t.album}'.toLowerCase().contains(
                query.toLowerCase().trim(),
              ),
            )
            .toList();
  Album? get album => groupAlbums(
    library.tracks,
  ).where((a) => a.id == selectedAlbum).firstOrNull;
  MusicPlaylist? get playlist =>
      library.playlists.where((l) => l.id == selectedPlaylist).firstOrNull;
  MusicPlaylist? get currentPlaylist => library.playlists
      .where((l) => l.id == playback.contextPlaylistId)
      .firstOrNull;
  List<Track> get playlistTracks =>
      playlist?.trackIds.map(library.byId).whereType<Track>().toList() ?? [];
  List<Track> get likedTracks =>
      library.tracks.where((t) => library.liked.contains(t.id)).toList();
  List<Track> get offlineTracks =>
      library.tracks.where((t) => t.cachedPath != null).toList();
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

  void navigate(AppPage value) {
    if (page != value) _history.add(page);
    page = value;
    error = null;
    notifyListeners();
  }

  void back() {
    if (_history.isNotEmpty) {
      page = _history.removeLast();
      notifyListeners();
    }
  }

  void openAlbum(Album value) {
    selectedAlbum = value.id;
    navigate(AppPage.album);
  }

  void openPlaylist(MusicPlaylist value) {
    selectedPlaylist = value.id;
    navigate(AppPage.playlist);
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
  }) => run('Открываем коллекцию…', () async {
    final tracks = torrents.tracks(info, link: link, album: title);
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
    selectedArtist = value;
    navigate(AppPage.artist);
  }

  void setQuery(String value) {
    _searchDebounce?.cancel();
    _searchOperation?.cancel();
    query = value;
    releases = [];
    ++_searchId;
    searchCompleted = false;
    searching = false;
    if (query.trim().isNotEmpty && (indexerConnected || !usesIndexer)) {
      searching = true;
      _searchDebounce = Timer(const Duration(milliseconds: 600), searchSources);
    }
    notifyListeners();
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

  Future<void> searchSources() async {
    _searchDebounce?.cancel();
    _searchOperation?.cancel();
    final operation = SourceOperation();
    _searchOperation = operation;
    final endpoint = library.settings['indexerUrl'] as String? ?? '';
    if (usesIndexer && endpoint.isEmpty) {
      navigate(AppPage.settings);
      message =
          'Настрой Jackett: добавь RuTracker и войди в свой аккаунт. На Windows можно запустить Jackett из Mumpa.';
      notifyListeners();
      return;
    }
    if (query.trim().isEmpty) return;
    final id = ++_searchId;
    searching = true;
    searchCompleted = false;
    error = null;
    notifyListeners();
    try {
      final items = usesIndexer
          ? await indexer.search(
              endpoint,
              library.settings['indexerKey'] as String? ?? '',
              query.trim(),
              operation: operation,
            )
          : (await catalog.search(query.trim())).releases;
      if (id == _searchId) {
        releases = items;
        searchCompleted = true;
        catalogNeedsConnection = false;
        catalogError = null;
      }
    } on SourceCancelled {
      // A newer query owns the visible results.
    } catch (e) {
      if (id == _searchId) {
        if (!usesIndexer) {
          _catalogFailure(e);
        } else {
          error = e is HttpException ? e.message : e.toString();
        }
      }
    } finally {
      if (id == _searchId) {
        searching = false;
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
    setQuery('');
    navigate(AppPage.search);
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
    _disposed = true;
    _searchDebounce?.cancel();
    ++_searchId;
    _opening?.cancel();
    _searchOperation?.cancel();
    library.removeListener(_changed);
    downloads.removeListener(_changed);
    playback.removeListener(_onPlayback);
    indexer.dispose();
    unawaited(catalog.dispose());
    unawaited(jackett.stop());
    unawaited(flaresolverr.stop());
    super.dispose();
  }
}
