part of 'library_repository.dart';

extension LibraryFeatureOperations on LibraryRepository {
  Future<void> saveFeatures() async {
    await _save();
    notifyListeners();
  }

  MusicPlaylist resolveSmartPlaylist(MusicPlaylist playlist) =>
      !playlist.isSmart
      ? playlist
      : playlist.copyWith(
          trackIds: selectSmartTracks(
            tracks: mediaTracks,
            rule: playlist.smartRule!,
            liked: liked,
            plays: trackPlayCount,
            features: features,
            now: DateTime.now(),
          ).map((t) => t.id).toList(),
        );

  Future<MusicPlaylist> saveSmartPlaylist(
    String name,
    Map<String, dynamic> rule, {
    String? id,
  }) async {
    if (name.trim().isEmpty) {
      throw const FormatException('Нужно название плейлиста.');
    }
    final playlist = MusicPlaylist(
      id: id ?? stableId('smart:${DateTime.now().microsecondsSinceEpoch}'),
      name: name.trim(),
      smartRule: validatedSmartRule(rule),
    );
    _playlists.removeWhere((p) => p.id == playlist.id);
    _playlists.add(playlist);
    notifyListeners();
    await _save();
    return resolveSmartPlaylist(playlist);
  }

  ListeningSummary listeningSummary({DateTime? since, DateTime? until}) =>
      ListeningSummary(
        features.listening.values.where(
          (b) =>
              (since == null ||
                  b.day.compareTo(LocalFeatures.dayKey(since)) >= 0) &&
              (until == null ||
                  b.day.compareTo(LocalFeatures.dayKey(until)) <= 0),
        ),
      );

  void recordListeningTime(String id, int milliseconds, {DateTime? at}) {
    final track = byId(id);
    if (track == null || milliseconds <= 0 || milliseconds > 30000) return;
    features.bucket(track, at ?? DateTime.now()).milliseconds += milliseconds;
  }

  Future<void> setPinned(Iterable<String> ids, bool pinned) async {
    for (final id in ids.where((id) => byId(id) != null)) {
      if (pinned) {
        features.pinned.add(id);
        _retainedTrackIds.add(id);
      } else {
        features.pinned.remove(id);
      }
    }
    notifyListeners();
    await _save();
  }

  bool acceptsRadio(Track track) =>
      !features.blockedSongs.contains(_radioSongIdentity(track)) &&
      !trackMatches.groupFor(track).ids.any(features.blocked.contains);

  String _radioSongIdentity(Track track) =>
      '${normalizeMusicName(track.albumArtist ?? track.artist)}\u0000${normalizedTrackTitle(track)}';

  bool reducedRadioArtist(String name) =>
      features.mutedArtists.contains(normalizeMusicName(name));

  Future<void> radioFeedback(
    Track track, {
    bool block = false,
    bool muteArtist = false,
    bool undo = false,
  }) async {
    radioFeedbackRevision++;
    if (block) {
      final ids = trackMatches.groupFor(track).ids;
      undo ? features.blocked.removeAll(ids) : features.blocked.addAll(ids);
      undo
          ? features.blockedSongs.remove(_radioSongIdentity(track))
          : features.blockedSongs.add(_radioSongIdentity(track));
    }
    if (muteArtist) {
      final artist = normalizeMusicName(track.artist);
      undo
          ? features.mutedArtists.remove(artist)
          : features.mutedArtists.add(artist);
    }
    notifyListeners();
    await _save();
  }

  Future<void> resetRadioFeedback() async {
    features.blocked.clear();
    features.blockedSongs.clear();
    features.mutedArtists.clear();
    radioFeedbackRevision++;
    await saveFeatures();
  }

  Future<void> editMetadata(Track track, Map<String, dynamic> edits) async {
    final clean = <String, dynamic>{};
    for (final key in ['title', 'artist', 'album', 'albumArtist', 'artPath']) {
      final value = edits[key];
      if (value is String && value.trim().isNotEmpty && value.length <= 4096) {
        clean[key] = value.trim();
      }
    }
    final year = edits['year'];
    if (year is int && year >= 1 && year <= 9999) clean['year'] = year;
    features.edits[track.id] = {...?features.edits[track.id], ...clean};
    await upsert([applyMetadataEdits(track)]);
  }

  Track applyMetadataEdits(Track track) {
    final edits = features.edits[track.id];
    return edits == null
        ? track
        : track.copyWith(
            title: edits['title'] as String?,
            artist: edits['artist'] as String?,
            album: edits['album'] as String?,
            albumArtist: edits['albumArtist'] as String?,
            year: edits['year'] as int?,
            artPath: edits['artPath'] as String?,
          );
  }

  /// Keep IDs and references; reject incompatible files. When both originals
  /// exist, require matching hashes as well as size and known duration.
  Future<void> relinkTrack(String id, String path, {bool copy = false}) async {
    final old = byId(id);
    if (old == null || old.source != TrackSource.local || !isAudioPath(path)) {
      throw const FormatException('Выбери аудиофайл для локального трека.');
    }
    final candidate = await inspect(path);
    if ((old.bytes > 0 && old.bytes != candidate.bytes) ||
        old.durationMs > 0 &&
            candidate.durationMs > 0 &&
            (old.durationMs - candidate.durationMs).abs() > 2000) {
      throw const FormatException(
        'Размер или длительность файла отличаются от исходного трека.',
      );
    }
    if (old.localPath != null && await File(old.localPath!).exists()) {
      final originalHash = await sha256
          .bind(File(old.localPath!).openRead())
          .first;
      final candidateHash = await sha256.bind(File(path).openRead()).first;
      if (originalHash != candidateHash) {
        throw const FormatException('Содержимое файлов отличается.');
      }
    }
    var destination = path;
    if (copy) {
      final digest = await sha256.bind(File(path).openRead()).first;
      final target = File(
        p.join(root.path, 'imports', '$digest${p.extension(path)}'),
      );
      await target.parent.create(recursive: true);
      if (!await target.exists()) await File(path).copy(target.path);
      destination = target.path;
    }
    await upsert([old.copyWith(localPath: destination)]);
  }

  /// Offer only unique file-name/size/duration matches. Nothing changes until
  /// the user confirms the proposed paths in the UI.
  Future<Map<String, String>> findRelinkCandidates(
    Directory folder,
    List<Track> missing,
  ) async {
    final candidates = <String, List<String>>{};
    final wanted = <String, List<Track>>{};
    String name(String value) => p.basename(value).toLowerCase();
    for (final track in missing.where((t) => t.localPath != null)) {
      wanted.putIfAbsent(name(track.localPath!), () => []).add(track);
    }
    await for (final entity in folder.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !isAudioPath(entity.path)) continue;
      final possible = wanted[name(entity.path)];
      if (possible == null) continue;
      final size = await entity.length();
      final matching = possible
          .where((track) => track.bytes == 0 || track.bytes == size)
          .toList();
      if (matching.isEmpty) continue;
      final inspected = await inspect(entity.path);
      for (final track in matching) {
        if (track.durationMs > 0 &&
            inspected.durationMs > 0 &&
            (track.durationMs - inspected.durationMs).abs() > 2000) {
          continue;
        }
        candidates.putIfAbsent(track.id, () => []).add(entity.path);
      }
    }
    final uses = <String, int>{};
    for (final paths in candidates.values) {
      if (paths.length == 1) uses[paths.single] = (uses[paths.single] ?? 0) + 1;
    }
    return {
      for (final entry in candidates.entries)
        if (entry.value.length == 1 && uses[entry.value.single] == 1)
          entry.key: entry.value.single,
    };
  }
}
