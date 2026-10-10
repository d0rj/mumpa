import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/models.dart';

class LibraryRepository extends ChangeNotifier {
  LibraryRepository(this.root);
  final Directory root;
  List<Track> _tracks = [];
  List<MusicPlaylist> _playlists = [];
  Set<String> _liked = {};
  Set<String> _likedPlaylists = {};
  List<String> _recent = [];
  Map<String, dynamic> _settings = {};
  Future<void> _writeTail = Future.value();
  String? loadWarning;
  List<Track> get tracks => List.unmodifiable(_tracks);
  List<MusicPlaylist> get playlists => List.unmodifiable(_playlists);
  Set<String> get liked => Set.unmodifiable(_liked);
  Set<String> get likedPlaylists => Set.unmodifiable(_likedPlaylists);
  List<MusicPlaylist> get favoritePlaylists => List.unmodifiable(
    _playlists.where((playlist) => _likedPlaylists.contains(playlist.id)),
  );
  bool isPlaylistLiked(String id) => _likedPlaylists.contains(id);
  List<String> get recent => List.unmodifiable(_recent);
  Map<String, dynamic> get settings => Map.unmodifiable(_settings);
  Directory get downloads => Directory(p.join(root.path, 'downloads'));
  Track? byId(String id) => _tracks.where((t) => t.id == id).firstOrNull;

  Future<void> load() async {
    await root.create(recursive: true);
    for (final name in ['library.json', 'library.json.bak']) {
      final file = File(p.join(root.path, name));
      if (!await file.exists()) continue;
      try {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        _tracks = ((j['tracks'] as List?) ?? [])
            .map((e) => Track.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        _playlists = ((j['playlists'] as List?) ?? [])
            .map(
              (e) =>
                  MusicPlaylist.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        _liked = Set<String>.from((j['liked'] as List?) ?? []);
        final playlistIds = _playlists.map((playlist) => playlist.id).toSet();
        _likedPlaylists = Set<String>.from((j['likedPlaylists'] as List?) ?? [])
          ..removeWhere((id) => !playlistIds.contains(id));
        _recent = List<String>.from((j['recent'] as List?) ?? []);
        _settings = Map<String, dynamic>.from((j['settings'] as Map?) ?? {});
        if (name.endsWith('.bak')) {
          loadWarning = 'Библиотека восстановлена из резервной копии.';
        }
        break;
      } catch (_) {
        loadWarning =
            'Не удалось прочитать библиотеку. Исходный файл сохранён.';
      }
    }
    // An interrupted transfer never becomes an offline item.
    _tracks = await Future.wait(
      _tracks.map(
        (t) async => t.cachedPath != null && !await File(t.cachedPath!).exists()
            ? t.copyWith(clearCache: true)
            : t,
      ),
    );
    // Default applies once to new/older profiles; an explicit opt-out survives.
    _settings.putIfAbsent('autoCache', () => true);
    notifyListeners();
  }

  Future<void> _save() {
    final contents = jsonEncode({
      'version': 1,
      'tracks': _tracks.map((t) => t.toJson()).toList(),
      'playlists': _playlists.map((t) => t.toJson()).toList(),
      'liked': _liked.toList(),
      'likedPlaylists': _likedPlaylists.toList(),
      'recent': _recent,
      'settings': _settings,
    });
    final next = _writeTail.catchError((Object _) {}).then((_) async {
      final target = File(p.join(root.path, 'library.json'));
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(contents, flush: true);
      if (await target.exists()) await target.copy('${target.path}.bak');
      await tmp.rename(target.path);
    });
    _writeTail = next;
    return next;
  }

  Future<void> upsert(
    Iterable<Track> tracks, {
    bool preserveCache = true,
  }) async {
    final indexed = {for (final t in _tracks) t.id: t};
    for (final t in tracks) {
      final old = indexed[t.id];
      indexed[t.id] =
          preserveCache && old?.cachedPath != null && t.cachedPath == null
          ? t.copyWith(cachedPath: old!.cachedPath)
          : t;
    }
    _tracks = indexed.values.toList();
    notifyListeners();
    await _save();
  }

  Future<void> removeTracks(Iterable<String> ids) async {
    final removed = ids.toSet();
    _tracks.removeWhere((t) => removed.contains(t.id));
    _liked.removeAll(removed);
    _recent.removeWhere(removed.contains);
    _playlists = _playlists
        .map(
          (l) => l.copyWith(
            trackIds: l.trackIds.where((id) => !removed.contains(id)).toList(),
          ),
        )
        .toList();
    notifyListeners();
    await _save();
  }

  Future<void> toggleLike(String id) async {
    if (!_liked.add(id)) _liked.remove(id);
    notifyListeners();
    await _save();
  }

  Future<void> togglePlaylistLike(String id) async {
    if (!_playlists.any((playlist) => playlist.id == id)) return;
    if (!_likedPlaylists.add(id)) _likedPlaylists.remove(id);
    notifyListeners();
    await _save();
  }

  Future<void> markPlayed(String id) async {
    _recent.remove(id);
    _recent.insert(0, id);
    if (_recent.length > 100) _recent.removeRange(100, _recent.length);
    await _save();
    notifyListeners();
  }

  Future<void> setSetting(String key, dynamic value) async {
    _settings = {..._settings, key: value};
    await _save();
    notifyListeners();
  }

  Future<MusicPlaylist> createPlaylist(String name) async {
    final playlist = MusicPlaylist(
      id: stableId(DateTime.now().toIso8601String()),
      name: name.trim(),
    );
    _playlists.add(playlist);
    notifyListeners();
    await _save();
    return playlist;
  }

  /// Opening one source creates one persistent collection, without audio I/O.
  /// Reopening preserves edits, tag enrichment and existing offline copies.
  Future<MusicPlaylist> openSourceCollection({
    required String hash,
    required String name,
    required List<Track> tracks,
  }) async {
    final indexed = {for (final track in _tracks) track.id: track};
    for (final track in tracks) {
      indexed.putIfAbsent(track.id, () => track);
    }
    _tracks = indexed.values.toList();
    var playlist = _playlists.where((p) => p.sourceHash == hash).firstOrNull;
    if (playlist == null) {
      playlist = MusicPlaylist(
        id: stableId('torrent-collection:$hash'),
        name: name.trim().isEmpty ? 'Музыкальная коллекция' : name.trim(),
        trackIds: tracks.map((t) => t.id).toList(),
        sourceHash: hash,
      );
      _playlists.add(playlist);
    }
    notifyListeners();
    await _save();
    return playlist;
  }

  Future<void> deletePlaylist(String id) async {
    _playlists.removeWhere((l) => l.id == id);
    _likedPlaylists.remove(id);
    notifyListeners();
    await _save();
  }

  Future<void> renamePlaylist(String id, String name) async {
    _playlists = _playlists
        .map((l) => l.id == id ? l.copyWith(name: name.trim()) : l)
        .toList();
    notifyListeners();
    await _save();
  }

  Future<void> addToPlaylist(String id, Iterable<String> tracks) async {
    _playlists = _playlists
        .map(
          (l) => l.id == id
              ? l.copyWith(trackIds: {...l.trackIds, ...tracks}.toList())
              : l,
        )
        .toList();
    notifyListeners();
    await _save();
  }

  Future<void> removeFromPlaylist(String id, String track) async {
    _playlists = _playlists
        .map(
          (l) => l.id == id
              ? l.copyWith(
                  trackIds: l.trackIds.where((t) => t != track).toList(),
                )
              : l,
        )
        .toList();
    notifyListeners();
    await _save();
  }

  Future<void> flush() => _writeTail;

  Future<List<Track>> importPaths(
    List<String> paths, {
    bool copy = false,
    void Function(int, int)? progress,
  }) async {
    final files = <String>[];
    for (final path in paths) {
      if (await FileSystemEntity.isDirectory(path)) {
        await for (final entity in Directory(
          path,
        ).list(recursive: true, followLinks: false)) {
          if (entity is File && isAudioPath(entity.path)) {
            files.add(entity.path);
          }
        }
      } else if (isAudioPath(path)) {
        files.add(path);
      }
    }
    files.sort();
    final imported = <Track>[];
    for (var i = 0; i < files.length; i++) {
      var path = files[i];
      if (copy) {
        final input = File(path);
        final digest = await sha256.bind(input.openRead()).first;
        final destination = File(
          p.join(root.path, 'imports', '$digest${p.extension(path)}'),
        );
        await destination.parent.create(recursive: true);
        if (!await destination.exists()) await input.copy(destination.path);
        final originalName = p.basenameWithoutExtension(path);
        path = destination.path;
        imported.add(await inspect(path, fallbackTitle: originalName));
      } else {
        imported.add(await inspect(path));
      }
      progress?.call(i + 1, files.length);
    }
    await upsert(imported);
    return imported;
  }

  Future<Track> inspect(
    String path, {
    String? fallbackTitle,
    Track? torrent,
  }) async {
    final artDirectory = p.join(root.path, 'artwork');
    return Isolate.run(
      () => inspectAudioFile(
        path,
        artDirectory,
        fallbackTitle: fallbackTitle,
        torrent: torrent,
      ),
    );
  }
}

Track inspectAudioFile(
  String path,
  String artDirectory, {
  String? fallbackTitle,
  Track? torrent,
}) {
  final file = File(path);
  final id = torrent?.id ?? stableId(p.normalize(p.absolute(path)));
  final filename =
      fallbackTitle ?? p.basenameWithoutExtension(torrent?.torrentPath ?? path);
  final parent = p.basename(p.dirname(torrent?.torrentPath ?? path));
  final filenameNumber =
      int.tryParse(
        RegExp(r'^\s*(\d{1,3})[ ._\-]').firstMatch(filename)?.group(1) ?? '',
      ) ??
      0;
  final fallback = filename.replaceFirst(RegExp(r'^\s*\d{1,3}[ ._\-]+'), '');
  AudioMetadata? metadata;
  try {
    metadata = readMetadata(file, getImage: true);
  } catch (_) {
    /* Untagged audio remains playable. */
  }
  String? art;
  final picture = metadata?.pictures.firstOrNull;
  if (picture != null && picture.bytes.length < 16 * 1024 * 1024) {
    final dir = Directory(artDirectory)..createSync(recursive: true);
    final out = File(
      p.join(dir.path, '${stableId(base64Encode(picture.bytes))}.jpg'),
    );
    if (!out.existsSync()) out.writeAsBytesSync(picture.bytes);
    art = out.path;
  } else {
    for (final name in [
      'cover.jpg',
      'folder.jpg',
      'front.jpg',
      'cover.png',
      'folder.png',
    ]) {
      final candidate = File(p.join(file.parent.path, name));
      if (candidate.existsSync()) {
        art = candidate.path;
        break;
      }
    }
  }
  if (torrent != null) {
    return torrent.copyWith(
      cachedPath: path,
      title: metadata?.title,
      artist: metadata?.artist,
      // Keep the imported release together as files finish at different times.
      // Track-level tags may differ (especially on compilations).
      albumArtist: torrent.albumArtist ?? torrent.artist,
      artPath: art,
      durationMs: metadata?.duration?.inMilliseconds,
      number: metadata?.trackNumber,
      disc: metadata?.discNumber,
      year: metadata?.year?.year,
      lyrics: metadata?.lyrics,
    );
  }
  return Track(
    id: id,
    title: metadata?.title?.trim().isNotEmpty == true
        ? metadata!.title!
        : fallback,
    artist: metadata?.artist ?? 'Неизвестный исполнитель',
    albumArtist: metadata?.albumArtist,
    album:
        metadata?.album ??
        (parent == 'imports' ? 'Импортированная музыка' : parent),
    source: TrackSource.local,
    localPath: path,
    artPath: art,
    bytes: file.lengthSync(),
    durationMs: metadata?.duration?.inMilliseconds ?? 0,
    number: metadata?.trackNumber ?? filenameNumber,
    disc: metadata?.discNumber ?? 1,
    year: metadata?.year?.year,
    lyrics: metadata?.lyrics,
  );
}
