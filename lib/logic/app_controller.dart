import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../data/download_repository.dart';
import '../data/library_repository.dart';
import '../data/torrent_service.dart';
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
  }) : indexer = indexer ?? IndexerService() {
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
  AppPage page = AppPage.home;
  LibraryFilter filter = LibraryFilter.all;
  LibrarySort sort = LibrarySort.added;
  String query = '';
  String? selectedAlbum, selectedPlaylist, selectedArtist;
  String? busy, message, error, engineVersion;
  List<SearchRelease> releases = [];
  bool searching = false;
  int _searchId = 0;
  final List<AppPage> _history = [];
  void _changed() => notifyListeners();
  String? _autoCachedId;
  String? _playbackError;
  void _onPlayback() {
    if (playback.error != _playbackError) {
      if (error == _playbackError) error = null;
      _playbackError = playback.error;
      if (_playbackError != null) error = _playbackError;
      notifyListeners();
    }
    final track = playback.current;
    if (track?.id == _autoCachedId || !playback.playing) return;
    _autoCachedId = track?.id;
    if (track != null && library.settings['autoCache'] == true) {
      downloads.enqueue([track]);
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

  void openArtist(String value) {
    selectedArtist = value;
    navigate(AppPage.artist);
  }

  void setQuery(String value) {
    query = value;
    releases = [];
    ++_searchId;
    searching = false;
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
      error = e.toString();
      return null;
    } finally {
      busy = null;
      notifyListeners();
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
    final endpoint = library.settings['indexerUrl'] as String? ?? '';
    if (endpoint.isEmpty) {
      navigate(AppPage.settings);
      message = 'Подключите свой Torznab-источник для поиска музыки.';
      notifyListeners();
      return;
    }
    if (query.trim().isEmpty) return;
    final id = ++_searchId;
    searching = true;
    error = null;
    notifyListeners();
    try {
      final items = await indexer.search(
        endpoint,
        library.settings['indexerKey'] as String? ?? '',
        query.trim(),
      );
      if (id == _searchId) releases = items;
    } catch (e) {
      if (id == _searchId) error = e.toString();
    } finally {
      if (id == _searchId) {
        searching = false;
        notifyListeners();
      }
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
    library.removeListener(_changed);
    downloads.removeListener(_changed);
    playback.removeListener(_onPlayback);
    indexer.dispose();
    super.dispose();
  }
}
