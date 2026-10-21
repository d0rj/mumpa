import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/models.dart';
import '../domain/local_features.dart';
import '../domain/playlist_rules.dart';
import '../domain/music_metadata.dart';
import '../l10n/app_localizations.dart';
import '../domain/torrent_album_layout.dart';
import '../domain/collection_filter.dart';
import '../domain/track_matching.dart';
import 'library_views.dart';
import 'library_storage.dart';
import 'profile_transfer.dart';

part 'library_metadata.dart';
part 'library_profile_transfer.dart';
part 'library_features.dart';

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
  LocalFeatures features = LocalFeatures();
  int radioFeedbackRevision = 0;
  late final _storage = LibraryStorage(root);
  List<Track> _trackItems = [];
  List<Track>? _trackSnapshot;
  List<MusicPlaylist>? _resolvedPlaylists, _resolvedMediaPlaylists;
  Map<String, Track>? _trackIndex;
  Map<String, List<Track>>? _offlineTorrentIndex;
  LibraryViews? _views;
  List<Album>? _albumSnapshot;
  Map<String, Album>? _albumIndex;
  TrackMatchIndex? _trackMatches;
  Set<String> _matchExcluded = {}, _preferredVariants = {};
  TrackMatchIndex get trackMatches => _trackMatches ??= TrackMatchIndex(
    tracks,
    excluded: _matchExcluded,
    preferred: _preferredVariants,
    sourceDescriptions: _sourceDescriptions,
  );
  Map<String, String> get _sourceDescriptions => {
    for (final playlist in _playlists)
      if (playlist.sourceHash != null) playlist.sourceHash!: playlist.name,
  };
  List<MatchedTrack> matchedTracks(List<Track> tracks) =>
      trackMatches.rowsFor(tracks);
  bool isMatchExcluded(String id) => _matchExcluded.contains(id);
  bool isPreferredVariant(String id) => _preferredVariants.contains(id);

  String trackCountLabel(List<Track> tracks) {
    final count = matchedTracks(tracks).length;
    return '${tr('{0} треков', [count])}${count == tracks.length ? '' : tr(' · {0} файлов', [tracks.length])}';
  }

  Future<void> _prepareTracks() async {
    final snapshot = tracks;
    await Future.wait([
      prepareCollectionSearch(snapshot),
      prepareTrackMatching(snapshot),
    ]);
    // A concurrent import/removal owns the new revision.
    if (identical(snapshot, tracks)) {
      _trackMatches = TrackMatchIndex(
        snapshot,
        excluded: _matchExcluded,
        preferred: _preferredVariants,
        sourceDescriptions: _sourceDescriptions,
      );
    }
  }

  LibraryViews get _currentViews => _views ??= LibraryViews(
    tracks: tracks,
    playlists: _playlists,
    liked: _liked,
    likedPlaylists: _likedPlaylists,
    likedAlbums: _likedAlbums,
    recent: _recent,
    retainedTrackIds: _retainedTrackIds,
    settings: _settings,
  );

  @override
  void notifyListeners() {
    _resolvedPlaylists = null;
    _resolvedMediaPlaylists = null;
    _views = null;
    _topTracksPlaylist = null;
    super.notifyListeners();
  }

  List<Track> get _tracks => _trackItems;
  set _tracks(List<Track> value) {
    _resolvedPlaylists = null;
    _resolvedMediaPlaylists = null;
    _topTracksPlaylist = null;
    _trackItems = value;
    _trackSnapshot = null;
    _trackIndex = null;
    _offlineTorrentIndex = null;
    _views = null;
    _albumSnapshot = null;
    _albumIndex = null;
    _trackMatches = null;
  }

  List<MusicPlaylist> _playlists = [];
  // Insertion order is the order of favorite additions. Persist these oldest
  // first and expose views newest first, independently of library/tag order.
  Set<String> _liked = {};
  Set<String> _likedPlaylists = {};
  List<Set<String>> _likedAlbums = [];
  List<String> _recent = [];
  Map<String, int> _trackPlayCounts = {}, _playlistPlayCounts = {};
  MusicPlaylist? _topTracksPlaylist;
  // Playback/library membership outlives the bounded recent-history list.
  Set<String> _retainedTrackIds = {};
  Map<String, dynamic> _settings = {};
  Future<void> _writeTail = Future.value();
  int _saveSequence = 0;
  bool _profileImporting = false;
  String? loadWarning;
  List<Track> get tracks => _trackSnapshot ??= List.unmodifiable(_tracks);
  List<MusicPlaylist> get playlists => _resolvedPlaylists ??= List.unmodifiable(
    _currentViews.playlists.map(resolveSmartPlaylist),
  );

  /// Personal library views exclude sources inspected only for discovery.
  /// Keep all known records available for queues, navigation and version picks.
  List<Track> get mediaTracks => _currentViews.mediaTracks;
  List<Album> get mediaAlbums => _currentViews.mediaAlbums;
  List<MusicPlaylist> get mediaPlaylists => _resolvedMediaPlaylists ??=
      List.unmodifiable(_currentViews.mediaPlaylists.map(resolveSmartPlaylist));
  Set<String> get liked => _currentViews.liked;
  bool isTrackLiked(String id) => _liked.contains(id);
  Set<String> get likedPlaylists => _currentViews.likedPlaylists;
  List<Track> get favoriteTracks => _currentViews.favoriteTracks;
  List<Track> get offlineTracks => _currentViews.offlineTracks;
  List<MusicPlaylist> get favoritePlaylists => _currentViews.favoritePlaylists;

  int trackPlayCount(String id) => _trackPlayCounts[id] ?? 0;
  int playlistPlayCount(String id) => _playlistPlayCounts[id] ?? 0;

  List<MusicPlaylist> get frequentPlaylists {
    final items = playlists.where((p) => playlistPlayCount(p.id) > 0).toList();
    items.sort((a, b) {
      final count = playlistPlayCount(b.id).compareTo(playlistPlayCount(a.id));
      return count != 0 ? count : a.id.compareTo(b.id);
    });
    return List.unmodifiable(items.take(6));
  }

  MusicPlaylist get topTracksPlaylist =>
      _topTracksPlaylist ??= _buildTopTracks();

  MusicPlaylist _buildTopTracks() {
    final rows = matchedTracks(
      tracks.where((t) => trackPlayCount(t.id) > 0).toList(),
    ).toList();
    int count(MatchedTrack row) =>
        row.group.ids.fold(0, (sum, id) => sum + trackPlayCount(id));
    rows.sort((a, b) {
      final plays = count(b).compareTo(count(a));
      return plays != 0 ? plays : a.anchor.id.compareTo(b.anchor.id);
    });
    return MusicPlaylist(
      id: MusicPlaylist.deviceTop50Id,
      name: tr('Топ-50 на этом устройстве'),
      trackIds: List.unmodifiable(rows.take(50).map((row) => row.anchor.id)),
    );
  }

  MusicPlaylist? playlistById(String? id) => id == MusicPlaylist.deviceTop50Id
      ? topTracksPlaylist
      : playlists.where((p) => p.id == id).firstOrNull;

  bool isPlaylistLiked(String id) => _likedPlaylists.contains(id);

  /// Keep the chosen files, rather than a metadata key that can change when
  /// tags arrive or combine the same album from multiple torrent releases.
  List<Album> get favoriteAlbums => _currentViews.favoriteAlbums;

  bool isAlbumLiked(Album album) {
    final ids = album.tracks.map((track) => track.id);
    return _likedAlbums.any((saved) => saved.containsAll(ids));
  }

  List<String> get recent => _currentViews.recent;
  Map<String, dynamic> get settings => _currentViews.settings;
  List<Album> get albums =>
      _albumSnapshot ??= List.unmodifiable(groupAlbums(tracks));
  Album? albumById(String id) =>
      (_albumIndex ??= {for (final album in albums) album.id: album})[id];
  Directory get downloads => Directory(p.join(root.path, 'downloads'));
  Map<String, Track> get _indexedTracks =>
      _trackIndex ??= {for (final track in _tracks) track.id: track};
  Track? byId(String id) => _indexedTracks[id];

  String? _torrentFileKey(Track track) =>
      track.source == TrackSource.torrent &&
          track.torrentHash != null &&
          track.torrentPath != null
      ? '${track.torrentHash!.toLowerCase()}\u0000${track.torrentPath!.replaceAll('\\', '/')}'
      : null;

  /// Reuse only the identical torrent file here. Different codecs/edits remain
  /// separate versions, selected by the collection's matching/version picker.
  Iterable<Track> localCopiesFor(Track track) sync* {
    final latest = byId(track.id) ?? track;
    if (latest.offline) yield latest;
    final key = _torrentFileKey(latest);
    if (key == null) return;
    if (_offlineTorrentIndex == null) {
      final index = <String, List<Track>>{};
      for (final item in tracks.where((item) => item.offline)) {
        final itemKey = _torrentFileKey(item);
        if (itemKey != null) {
          index.putIfAbsent(itemKey, () => []).add(item);
        }
      }
      _offlineTorrentIndex = index;
    }
    yield* (_offlineTorrentIndex![key] ?? const <Track>[]).where(
      (item) => item.id != latest.id,
    );
  }

  Future<String?> localPathFor(Track track) async {
    for (final copy in localCopiesFor(track)) {
      for (final path in [copy.cachedPath, copy.localPath]) {
        if (path != null && await File(path).exists()) return path;
      }
    }
    return null;
  }

  bool isTrackProtected(String id) =>
      features.pinned.contains(id) ||
      _liked.contains(id) ||
      byId(id)?.cachedPath != null ||
      _likedAlbums.any((ids) => ids.contains(id)) ||
      _playlists.any(
        (playlist) =>
            _likedPlaylists.contains(playlist.id) &&
            playlist.trackIds.contains(id),
      );

  Future<void> load() async {
    final loaded = await _storage.load();
    loadWarning = _storage.warning;
    if (loaded != null) {
      final j = loaded;
      features = LocalFeatures.fromJson(j['localFeatures']);
      radioFeedbackRevision++;
      _tracks = ((j['tracks'] as List?) ?? [])
          .map((e) => Track.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      _playlists = ((j['playlists'] as List?) ?? [])
          .map(
            (e) => MusicPlaylist.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
      _liked = Set<String>.from((j['liked'] as List?) ?? []);
      final playlistIds = _playlists.map((playlist) => playlist.id).toSet();
      _likedPlaylists = Set<String>.from((j['likedPlaylists'] as List?) ?? [])
        ..removeWhere((id) => !playlistIds.contains(id));
      final trackIds = _tracks.map((track) => track.id).toSet();
      _matchExcluded = Set<String>.from(
        (j['trackMatchExcluded'] as List?) ?? [],
      )..retainAll(trackIds);
      _preferredVariants = Set<String>.from(
        (j['preferredTrackVariants'] as List?) ?? [],
      )..retainAll(trackIds);
      _likedAlbums = ((j['likedAlbums'] as List?) ?? [])
          .map(
            (ids) =>
                Set<String>.from(ids as List)
                  ..removeWhere((id) => !trackIds.contains(id)),
          )
          .where((ids) => ids.isNotEmpty)
          .toList();
      _recent = List<String>.from((j['recent'] as List?) ?? []);
      _trackPlayCounts = Map<String, int>.from(
        j['trackPlayCounts'] as Map? ?? {},
      )..removeWhere((id, count) => !trackIds.contains(id) || count <= 0);
      _playlistPlayCounts = Map<String, int>.from(
        j['playlistPlayCounts'] as Map? ?? {},
      )..removeWhere((id, count) => !playlistIds.contains(id) || count <= 0);
      _retainedTrackIds = Set<String>.from(
        (j['retainedTrackIds'] as List?) ?? _recent,
      )..retainAll(trackIds);
      _settings = Map<String, dynamic>.from((j['settings'] as Map?) ?? {});
    }
    // Older profiles lack completion dates. Use the final file's modification
    // time once, then persist it so later tag updates do not change the order.
    var migratedDownloadDates = false;
    // An interrupted transfer never becomes an offline item.
    _tracks = await Future.wait(
      _tracks.map((track) async {
        if (track.cachedPath == null) return track;
        final stat = await File(track.cachedPath!).stat();
        if (stat.type != FileSystemEntityType.file) {
          return track.copyWith(clearCache: true);
        }
        if (track.downloadedAt != null) return track;
        migratedDownloadDates = true;
        return track.copyWith(downloadedAt: stat.modified.toUtc());
      }),
    );
    // Default applies once to new/older profiles; an explicit opt-out survives.
    _settings.putIfAbsent('autoCache', () => true);
    final upgradedLayouts = await _upgradeTorrentLayouts();
    _tracks = _tracks.map(applyMetadataEdits).toList();
    if (upgradedLayouts || migratedDownloadDates) {
      await _save();
    }
    await _prepareTracks();
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

  Map<String, dynamic> _snapshot() => {
    'version': 1,
    'localFeatures': features.toJson(),
    'tracks': _tracks.map((t) => t.toJson()).toList(),
    'playlists': _playlists.map((t) => t.toJson()).toList(),
    'liked': _liked.toList(),
    'likedPlaylists': _likedPlaylists.toList(),
    'likedAlbums': _likedAlbums.map((ids) => ids.toList()).toList(),
    'recent': List<String>.of(_recent),
    'trackPlayCounts': Map<String, int>.of(_trackPlayCounts),
    'playlistPlayCounts': Map<String, int>.of(_playlistPlayCounts),
    'retainedTrackIds': _retainedTrackIds.toList(),
    'settings': Map<String, dynamic>.of(_settings),
    'trackMatchExcluded': _matchExcluded.toList(),
    'preferredTrackVariants': _preferredVariants.toList(),
  };

  Future<void> _save() {
    _resolvedPlaylists = null;
    _resolvedMediaPlaylists = null;
    _saveSequence++;
    // markPlayed/settings mutate before awaiting disk I/O and notifying.
    _views = null;
    _topTracksPlaylist = null;
    final snapshot = _snapshot();
    final next = _writeTail.catchError((Object _) {}).then((_) async {
      final contents = await _encodeLibrarySnapshot(snapshot);
      await _storage.save(contents);
    });
    _writeTail = next;
    return next;
  }

  Future<void> upsert(
    Iterable<Track> tracks, {
    bool preserveCache = true,
    bool addToLibrary = false,
  }) async {
    final indexed = {for (final t in _tracks) t.id: t};
    for (final t in tracks) {
      final old = indexed[t.id];
      final inferred =
          t.albumSource == TrackAlbumSource.release ||
          t.albumSource == TrackAlbumSource.directory;
      var item =
          old != null &&
              t.source == TrackSource.torrent &&
              inferred &&
              t.cachedPath == null &&
              preserveCache
          ? _mergeTorrentImport(old, t)
          : t;
      if (preserveCache && old?.cachedPath != null) {
        if (item.cachedPath == null) {
          item = item.copyWith(
            cachedPath: old!.cachedPath,
            downloadedAt: old.downloadedAt,
          );
        } else if (item.cachedPath == old!.cachedPath &&
            item.downloadedAt == null) {
          item = item.copyWith(downloadedAt: old.downloadedAt);
        }
      }
      indexed[t.id] = applyMetadataEdits(item);
      if (old == null) features.added[t.id] = DateTime.now().toUtc();
      if (addToLibrary) _retainedTrackIds.add(t.id);
    }
    _tracks = _propagateTorrentAlbumMetadata(
      indexed.values,
    ).map(applyMetadataEdits).toList();
    await _prepareTracks();
    notifyListeners();
    await _save();
  }

  Future<void> removeTracks(Iterable<String> ids) async {
    // Removing a collection must never orphan offline files or erase favorites.
    final removed = ids.where((id) => !isTrackProtected(id)).toSet();
    if (removed.isEmpty) return;
    _tracks = _tracks.where((t) => !removed.contains(t.id)).toList();
    _liked.removeAll(removed);
    _matchExcluded.removeAll(removed);
    _preferredVariants.removeAll(removed);
    for (final ids in _likedAlbums) {
      ids.removeAll(removed);
    }
    _likedAlbums.removeWhere((ids) => ids.isEmpty);
    _recent.removeWhere(removed.contains);
    _trackPlayCounts.removeWhere((id, _) => removed.contains(id));
    _retainedTrackIds.removeAll(removed);
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

  Future<void> toggleMatchedTrackLike(
    TrackMatchGroup group,
    String preferredId,
  ) async {
    if (group.ids.any(_liked.contains)) {
      _liked.removeAll(group.ids);
    } else if (group.ids.contains(preferredId) && byId(preferredId) != null) {
      _liked.add(preferredId);
    }
    notifyListeners();
    await _save();
  }

  Future<void> preferTrackVariant(String id) async {
    final track = byId(id);
    if (track == null) return;
    _preferredVariants.removeAll(trackMatches.groupFor(track).ids);
    _preferredVariants.add(id);
    _trackMatches = null;
    notifyListeners();
    await _save();
  }

  Future<void> setTrackMatchExcluded(String id, bool excluded) async {
    if (byId(id) == null) return;
    if (excluded) {
      _matchExcluded.add(id);
    } else {
      _matchExcluded.remove(id);
      // Keep one explicit default when rejoining a separated file.
      _preferredVariants.remove(id);
    }
    _trackMatches = null;
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
    if (byId(id) == null) return;
    _retainedTrackIds.add(id);
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

  /// Called once when audio advances in a queue occurrence. Pauses, session
  /// restoration and failed opens do not create extra listens.
  Future<void> recordListen(String id, {String? playlistId}) async {
    if (byId(id) == null) return;
    features.lastPlayed[id] = DateTime.now().toUtc();
    features.bucket(byId(id)!, DateTime.now()).plays++;
    _trackPlayCounts[id] = trackPlayCount(id) + 1;
    if (_playlists.any((p) => p.id == playlistId)) {
      _playlistPlayCounts[playlistId!] = playlistPlayCount(playlistId) + 1;
    }
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
    await _prepareTracks();
    notifyListeners();
    await _save();
    return playlist;
  }

  Future<void> deletePlaylist(String id) async {
    _playlistPlayCounts.remove(id);
    _playlists.removeWhere((l) => l.id == id);
    _likedPlaylists.remove(id);
    _trackMatches = null;
    notifyListeners();
    await _save();
  }

  Future<void> renamePlaylist(String id, String name) async {
    _playlists = _playlists
        .map((l) => l.id == id ? l.copyWith(name: name.trim()) : l)
        .toList();
    _trackMatches = null;
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

  Future<void> removeFromPlaylist(String id, String track) =>
      removePlaylistTracks(id, [track]);

  /// Move one saved occurrence to its final index, retaining every file ID.
  Future<void> movePlaylistTrack(String id, int from, int to) async {
    final index = _playlists.indexWhere((playlist) => playlist.id == id);
    if (index < 0) return;
    final playlist = _playlists[index];
    if (from < 0 ||
        from >= playlist.trackIds.length ||
        to < 0 ||
        to >= playlist.trackIds.length ||
        from == to) {
      return;
    }
    final ids = List.of(playlist.trackIds);
    ids.insert(to, ids.removeAt(from));
    _playlists[index] = playlist.copyWith(trackIds: ids);
    notifyListeners();
    await _save();
  }

  /// Move a displayed song and all of its saved variants as one block.
  /// Hidden search results and absent file IDs retain their relative order.
  Future<void> movePlaylistTrackGroup(
    String id,
    Set<String> moving,
    Set<String> target, {
    required bool after,
  }) async {
    final index = _playlists.indexWhere((playlist) => playlist.id == id);
    if (index < 0 || moving.any(target.contains)) return;
    final playlist = _playlists[index];
    final moved = playlist.trackIds.where(moving.contains).toList();
    final remaining = playlist.trackIds
        .where((id) => !moving.contains(id))
        .toList();
    final destination = after
        ? remaining.lastIndexWhere(target.contains)
        : remaining.indexWhere(target.contains);
    if (moved.isEmpty || destination < 0) return;
    remaining.insertAll(destination + (after ? 1 : 0), moved);
    if (listEquals(playlist.trackIds, remaining)) return;
    _playlists[index] = playlist.copyWith(trackIds: remaining);
    notifyListeners();
    await _save();
  }

  Future<void> removePlaylistTracks(String id, Iterable<String> tracks) async {
    final removed = tracks.toSet();
    _playlists = _playlists
        .map(
          (l) => l.id == id
              ? l.copyWith(
                  trackIds: l.trackIds
                      .where((t) => !removed.contains(t))
                      .toList(),
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
    // Metadata-only profile transfers keep IDs used by favorites/playlists.
    // Reattach a uniquely matching local file instead of adding a second row.
    final claimed = <String>{};
    final restored = [
      for (final track in imported)
        _reattachTransferredLocalTrack(track, claimed),
    ];
    await upsert(restored);
    return restored;
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
