import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/models.dart';
import '../domain/torrent_album_layout.dart';
import '../domain/collection_filter.dart';

Future<String> _encodeLibrarySnapshot(Map<String, dynamic> snapshot) {
  // Tiny profiles cost less to encode than starting and transferring an isolate.
  if ((snapshot['tracks'] as List).length < 256) {
    return Future.value(jsonEncode(snapshot));
  }
  return Isolate.run(() => jsonEncode(snapshot));
}

class LibraryRepository extends ChangeNotifier {
  LibraryRepository(this.root);
  final Directory root;
  List<Track> _trackItems = [];
  List<Track>? _trackSnapshot;
  Map<String, Track>? _trackIndex;
  List<Track> get _tracks => _trackItems;
  set _tracks(List<Track> value) {
    _trackItems = value;
    _trackSnapshot = null;
    _trackIndex = null;
  }

  List<MusicPlaylist> _playlists = [];
  // Insertion order is the order of favorite additions. Persist these oldest
  // first and expose views newest first, independently of library/tag order.
  Set<String> _liked = {};
  Set<String> _likedPlaylists = {};
  List<Set<String>> _likedAlbums = [];
  List<String> _recent = [];
  Map<String, dynamic> _settings = {};
  Future<void> _writeTail = Future.value();
  String? loadWarning;
  List<Track> get tracks => _trackSnapshot ??= List.unmodifiable(_tracks);
  List<MusicPlaylist> get playlists => List.unmodifiable(_playlists);
  Set<String> get liked => Set.unmodifiable(_liked);
  bool isTrackLiked(String id) => _liked.contains(id);
  Set<String> get likedPlaylists => Set.unmodifiable(_likedPlaylists);
  List<Track> get favoriteTracks {
    final indexed = _indexedTracks;
    return List.unmodifiable(
      _liked.toList().reversed.map((id) => indexed[id]).whereType<Track>(),
    );
  }

  List<MusicPlaylist> get favoritePlaylists {
    final indexed = {for (final playlist in _playlists) playlist.id: playlist};
    return List.unmodifiable(
      _likedPlaylists
          .toList()
          .reversed
          .map((id) => indexed[id])
          .whereType<MusicPlaylist>(),
    );
  }

  bool isPlaylistLiked(String id) => _likedPlaylists.contains(id);

  /// Keep the chosen files, rather than a metadata key that can change when
  /// tags arrive or combine the same album from multiple torrent releases.
  List<Album> get favoriteAlbums {
    if (_likedAlbums.isEmpty) return const [];
    final indexed = _indexedTracks;
    return List.unmodifiable(
      _likedAlbums.reversed.expand(
        (ids) => groupAlbums(ids.map((id) => indexed[id]).whereType<Track>()),
      ),
    );
  }

  bool isAlbumLiked(Album album) {
    final ids = album.tracks.map((track) => track.id);
    return _likedAlbums.any((saved) => saved.containsAll(ids));
  }

  List<String> get recent => List.unmodifiable(_recent);
  Map<String, dynamic> get settings => Map.unmodifiable(_settings);
  Directory get downloads => Directory(p.join(root.path, 'downloads'));
  Map<String, Track> get _indexedTracks =>
      _trackIndex ??= {for (final track in _tracks) track.id: track};
  Track? byId(String id) => _indexedTracks[id];

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
        final trackIds = _tracks.map((track) => track.id).toSet();
        _likedAlbums = ((j['likedAlbums'] as List?) ?? [])
            .map(
              (ids) =>
                  Set<String>.from(ids as List)
                    ..removeWhere((id) => !trackIds.contains(id)),
            )
            .where((ids) => ids.isNotEmpty)
            .toList();
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
    if (await _upgradeTorrentLayouts()) {
      await _save();
    }
    await prepareCollectionSearch(tracks);
    notifyListeners();
  }

  /// Path migration keeps all persisted IDs and references. Existing cached
  /// files are inspected sequentially in isolates, once per legacy track.
  Future<bool> _upgradeTorrentLayouts() async {
    final sources = <String, List<Track>>{};
    for (final track in _tracks) {
      if (track.source == TrackSource.torrent &&
          track.torrentHash != null &&
          track.torrentPath != null) {
        sources.putIfAbsent(track.torrentHash!, () => []).add(track);
      }
    }
    final indexed = {for (final track in _tracks) track.id: track};
    var changed = false;
    for (final entry in sources.entries) {
      final legacy = entry.value
          .where((track) => track.albumSource == null)
          .toList();
      if (legacy.isEmpty) {
        continue;
      }
      final collection = _playlists
          .where((playlist) => playlist.sourceHash == entry.key)
          .firstOrNull;
      final first = entry.value.first;
      final layout = TorrentAlbumLayout(
        TorrentInfo(
          hash: entry.key,
          title: collection?.name ?? first.album,
          files: entry.value
              .map(
                (track) => TorrentFile(
                  index: track.torrentIndex ?? 0,
                  path: track.torrentPath!,
                  bytes: track.bytes,
                ),
              )
              .toList(),
        ),
        artist:
            first.albumArtist ??
            (first.artist == 'Неизвестный исполнитель' ? null : first.artist),
      );
      for (final old in legacy) {
        final identity = layout.forPath(old.torrentPath!);
        var track = old.copyWith(
          album: identity.album,
          artist: old.artist == 'Неизвестный исполнитель'
              ? identity.artist
              : old.artist,
          albumArtist:
              old.albumArtist == null ||
                  old.albumArtist == 'Неизвестный исполнитель'
              ? identity.artist
              : old.albumArtist,
          torrentAlbumPath: identity.folder,
          albumSource: identity.source,
          disc: old.disc == 1 ? identity.disc : old.disc,
          year: old.year ?? identity.year,
          number: old.number == 0
              ? parseTorrentTrackName(old.torrentPath!).number
              : old.number,
        );
        if (old.cachedPath != null) {
          try {
            track = await inspect(old.cachedPath!, torrent: track);
          } catch (_) {
            // Keep the cached item and previously enriched metadata on failure.
          }
        }
        indexed[track.id] = track;
        changed = true;
      }
    }
    if (changed) {
      _tracks = _propagateTorrentAlbumMetadata(indexed.values);
    }
    return changed;
  }

  Future<void> _save() {
    final snapshot = <String, dynamic>{
      'version': 1,
      'tracks': _tracks.map((t) => t.toJson()).toList(),
      'playlists': _playlists.map((t) => t.toJson()).toList(),
      'liked': _liked.toList(),
      'likedPlaylists': _likedPlaylists.toList(),
      'likedAlbums': _likedAlbums.map((ids) => ids.toList()).toList(),
      'recent': List<String>.of(_recent),
      'settings': _settings,
    };
    final next = _writeTail.catchError((Object _) {}).then((_) async {
      final contents = await _encodeLibrarySnapshot(snapshot);
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
      final inferred =
          t.albumSource == TrackAlbumSource.release ||
          t.albumSource == TrackAlbumSource.directory;
      final item =
          old != null &&
              t.source == TrackSource.torrent &&
              inferred &&
              t.cachedPath == null &&
              preserveCache
          ? _mergeTorrentImport(old, t)
          : t;
      indexed[t.id] =
          preserveCache && old?.cachedPath != null && item.cachedPath == null
          ? item.copyWith(cachedPath: old!.cachedPath)
          : item;
    }
    _tracks = _propagateTorrentAlbumMetadata(indexed.values);
    await prepareCollectionSearch(this.tracks);
    notifyListeners();
    await _save();
  }

  Future<void> removeTracks(Iterable<String> ids) async {
    final removed = ids.toSet();
    _tracks = _tracks.where((t) => !removed.contains(t.id)).toList();
    _liked.removeAll(removed);
    for (final ids in _likedAlbums) {
      ids.removeAll(removed);
    }
    _likedAlbums.removeWhere((ids) => ids.isEmpty);
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

  Future<void> toggleAlbumLike(Album album) async {
    final existing = _tracks.map((track) => track.id).toSet();
    final ids = album.tracks
        .map((track) => track.id)
        .where(existing.contains)
        .toSet();
    if (ids.isEmpty) return;
    if (_likedAlbums.any((saved) => saved.containsAll(ids))) {
      for (final saved in _likedAlbums) {
        saved.removeAll(ids);
      }
      _likedAlbums.removeWhere((saved) => saved.isEmpty);
    } else {
      // Replace an earlier, smaller selection of this album without creating
      // duplicate favorites when additional files are imported later.
      _likedAlbums.removeWhere((saved) => ids.containsAll(saved));
      _likedAlbums.add(ids);
    }
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
      final old = indexed[track.id];
      if (old == null) {
        indexed[track.id] = track;
      } else if (track.source == TrackSource.torrent &&
          track.albumSource != null) {
        indexed[track.id] = _mergeTorrentImport(old, track);
      }
    }
    _tracks = _propagateTorrentAlbumMetadata(indexed.values);
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
    await prepareCollectionSearch(this.tracks);
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
    metadata = _readAudioMetadata(file);
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
    String? value(String? text) =>
        text?.trim().isNotEmpty == true ? text!.trim() : null;
    final tagAlbum = value(metadata?.album);
    final tagAlbumArtist = value(metadata?.albumArtist);
    return torrent.copyWith(
      cachedPath: path,
      title: value(metadata?.title),
      artist: value(metadata?.artist),
      album: tagAlbum,
      albumSource: tagAlbum == null
          ? torrent.albumSource
          : TrackAlbumSource.tags,
      albumArtist: tagAlbumArtist ?? torrent.albumArtist ?? torrent.artist,
      albumArtistFromTags:
          tagAlbumArtist != null || torrent.albumArtistFromTags,
      artPath: art,
      durationMs: metadata?.duration?.inMilliseconds,
      number: metadata?.trackNumber,
      disc: metadata?.discNumber,
      year: (metadata?.year?.year ?? 0) > 0 ? metadata!.year!.year : null,
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

AudioMetadata _readAudioMetadata(File file) {
  // The pinned generic MP3 mapper drops TPE2/albumArtist and uses it as TPE1.
  // Parse once through its public raw model, preserving the separate credits.
  if (p.extension(file.path).toLowerCase() == '.mp3') {
    final raw = readAllMetadata(file, getImage: true);
    if (raw is Mp3Metadata) {
      final year = raw.originalReleaseYear ?? raw.year;
      final metadata = AudioMetadata(
        file: file,
        title: raw.songName,
        album: raw.album,
        artist: raw.leadPerformer ?? raw.originalArtist ?? raw.bandOrOrchestra,
        albumArtist: raw.bandOrOrchestra,
        year: year == null || year <= 0 ? null : DateTime(year),
        duration: raw.duration,
        trackNumber: raw.trackNumber,
        trackTotal: raw.trackTotal,
        discNumber: raw.discNumber,
        totalDisc: raw.totalDics,
        lyrics: raw.lyric,
        language: raw.languages,
        bitrate: raw.bitrate,
        sampleRate: raw.samplerate,
      );
      metadata.pictures = raw.pictures;
      metadata.genres = raw.genres;
      return metadata;
    }
  }
  final metadata = readMetadata(file, getImage: true);
  if ({
    '.m4a',
    '.aac',
    '.alac',
    '.mp4',
  }.contains(p.extension(file.path).toLowerCase())) {
    try {
      final credits = _readMp4Artists(file);
      metadata.albumArtist = credits.albumArtist ?? metadata.albumArtist;
      metadata.artist =
          credits.artist ?? metadata.artist ?? credits.albumArtist;
    } catch (_) {
      // Malformed/unsupported supplemental atoms do not discard valid tags.
    }
  }
  return metadata;
}

/// Read only iTunes ©ART/aART credits omitted by the pinned generic mapper.
/// Media payload is skipped by seeking: bounded depth, atom count and tag size.
({String? artist, String? albumArtist}) _readMp4Artists(File file) {
  final reader = file.openSync();
  String? artist, albumArtist;
  var remainingAtoms = 10000;
  Uint8List readAt(int offset, int count) {
    reader.setPositionSync(offset);
    final data = reader.readSync(count);
    if (data.length != count) {
      throw const FormatException('Incomplete metadata atom.');
    }
    return data;
  }

  void walk(int start, int end, int depth, [String? field]) {
    if (depth > 8) return;
    var offset = start;
    while (offset <= end - 8 && --remainingAtoms >= 0) {
      final header = readAt(offset, 8);
      var size = ByteData.sublistView(header).getUint32(0);
      final type = latin1.decode(header.sublist(4));
      var headerSize = 8;
      if (size == 1) {
        if (offset > end - 16) return;
        size = ByteData.sublistView(readAt(offset + 8, 8)).getUint64(0);
        headerSize = 16;
      } else if (size == 0) {
        size = end - offset;
      }
      if (size < headerSize || size > end - offset) return;
      final atomEnd = offset + size;
      final payload = offset + headerSize;
      if ({'moov', 'udta', 'meta', 'ilst'}.contains(type)) {
        var childStart = payload;
        if (type == 'meta') {
          if (payload > atomEnd - 8) return;
          // Some QuickTime meta atoms omit ISO-BMFF's version/flags word.
          final firstType = latin1.decode(readAt(payload + 4, 4));
          if (!{'ilst', 'hdlr', 'free', 'keys'}.contains(firstType)) {
            childStart += 4;
          }
        }
        walk(childStart, atomEnd, depth + 1);
      } else if (type == '©ART' || type == 'aART') {
        walk(payload, atomEnd, depth + 1, type);
      } else if (type == 'data' &&
          field != null &&
          atomEnd - payload >= 8 &&
          atomEnd - payload - 8 <= 64 * 1024) {
        final encoding =
            ByteData.sublistView(readAt(payload, 4)).getUint32(0) & 0xffffff;
        final bytes = readAt(payload + 8, atomEnd - payload - 8);
        String? value;
        if (encoding == 0 || encoding == 1) {
          value = utf8.decode(bytes, allowMalformed: true);
        } else if (encoding == 2 && bytes.length.isEven) {
          final data = ByteData.sublistView(bytes);
          value = String.fromCharCodes([
            for (var index = 0; index < bytes.length; index += 2)
              data.getUint16(index),
          ]);
        }
        value = value
            ?.replaceFirst('\uFEFF', '')
            .replaceAll('\u0000', '')
            .trim();
        if (value?.isNotEmpty == true) {
          if (field == '©ART') {
            artist ??= value;
          } else {
            albumArtist ??= value;
          }
        }
      }
      offset = atomEnd;
    }
  }

  try {
    walk(0, reader.lengthSync(), 0);
    return (artist: artist, albumArtist: albumArtist);
  } finally {
    reader.closeSync();
  }
}

Track _mergeTorrentImport(Track old, Track inferred) {
  final enriched =
      old.albumSource == TrackAlbumSource.tags ||
      old.albumSource == TrackAlbumSource.sibling;
  return old.copyWith(
    album: enriched ? old.album : inferred.album,
    albumArtist: enriched || old.albumArtistFromTags
        ? old.albumArtist
        : inferred.albumArtist,
    torrentAlbumPath: inferred.torrentAlbumPath,
    albumSource: enriched ? old.albumSource : inferred.albumSource,
    year: old.year ?? inferred.year,
    disc: enriched ? old.disc : inferred.disc,
    artPath: old.artPath ?? inferred.artPath,
  );
}

List<Track> _propagateTorrentAlbumMetadata(Iterable<Track> tracks) {
  final items = tracks.toList();
  final groups = <String, List<Track>>{};
  for (final track in items) {
    // A flat mixed collection provides no evidence that tracks share an album.
    if (track.source != TrackSource.torrent ||
        track.torrentHash == null ||
        track.torrentAlbumPath == null) {
      continue;
    }
    groups
        .putIfAbsent(
          '${track.torrentHash}\u0000${track.torrentAlbumPath}',
          () => [],
        )
        .add(track);
  }
  final updated = <String, Track>{};
  for (final group in groups.values) {
    group.sort((a, b) => (a.torrentIndex ?? 0).compareTo(b.torrentIndex ?? 0));
    final canonical =
        group
            .where((track) => track.albumSource == TrackAlbumSource.tags)
            .firstOrNull ??
        group.where((track) => track.albumArtistFromTags).firstOrNull;
    if (canonical == null) {
      continue;
    }
    final albumArtist =
        group
            .where(
              (track) =>
                  track.albumArtistFromTags &&
                  (track.albumSource != TrackAlbumSource.tags ||
                      track.album == canonical.album),
            )
            .firstOrNull
            ?.albumArtist ??
        canonical.albumArtist ??
        canonical.artist;
    for (final track in group) {
      if (track.albumSource == TrackAlbumSource.tags &&
          track.album != canonical.album) {
        continue;
      }
      final explicit = track.albumSource == TrackAlbumSource.tags;
      updated[track.id] = track.copyWith(
        album: explicit ? track.album : canonical.album,
        albumSource: explicit ? track.albumSource : TrackAlbumSource.sibling,
        albumArtist: track.albumArtistFromTags
            ? track.albumArtist
            : albumArtist,
        year: explicit ? track.year : canonical.year,
      );
    }
  }
  return items.map((track) => updated[track.id] ?? track).toList();
}
