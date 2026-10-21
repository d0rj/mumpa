part of 'library_repository.dart';

extension LibraryProfileTransfer on LibraryRepository {
  Track _reattachTransferredLocalTrack(Track track, Set<String> claimed) {
    final candidates = _tracks
        .where(
          (old) =>
              old.source == TrackSource.local &&
              old.localPath == null &&
              !claimed.contains(old.id) &&
              old.title == track.title &&
              old.artist == track.artist &&
              old.album == track.album &&
              old.bytes == track.bytes &&
              old.durationMs == track.durationMs &&
              old.number == track.number &&
              old.disc == track.disc,
        )
        .take(2)
        .toList();
    if (candidates.length != 1) return track;
    final id = candidates.single.id;
    claimed.add(id);
    return Track.fromJson({...track.toJson(), 'id': id});
  }

  Future<String> exportProfile() async {
    await flush();
    final snapshot = _snapshot();
    final contents = await Isolate.run(
      () => ProfileTransfer.fromSnapshot(snapshot).encode(),
    );
    if (utf8.encode(contents).length > ProfileTransfer.maxBytes) {
      throw const FormatException('Файл профиля больше 64 МБ.');
    }
    return contents;
  }

  /// Additive restore. A private full snapshot survives later automatic saves.
  Future<void> importProfile(
    ProfileTransfer transfer, {
    bool includeSettings = true,
  }) async {
    if (_profileImporting) throw StateError('Импорт профиля уже выполняется.');
    _profileImporting = true;
    try {
      await flush();
      _storage.checkWritable();
      final backup = File(
        p.join(
          root.path,
          'backups',
          'before-profile-import',
          'library-${DateTime.now().microsecondsSinceEpoch}.json',
        ),
      );
      await backup.parent.create(recursive: true);
      await backup.writeAsString(
        await _encodeLibrarySnapshot(_snapshot()),
        flush: true,
      );
      // Take the latest state after the backup I/O: playback/settings may have
      // changed while the dialog was open or the backup was being written.
      final before = _snapshot();
      final merged = transfer.merge(before, includeSettings: includeSettings);
      _applyTransferredSnapshot(merged);
      final saved = _save();
      final sequence = _saveSequence;
      try {
        await saved;
      } catch (_) {
        // Never undo a later user action if another mutation followed import.
        if (_saveSequence == sequence) {
          // The primary may already be committed when a later daily-backup
          // step fails. Keep memory consistent with that successful rename.
          var committed = false;
          final expected = _snapshot();
          try {
            committed =
                await _storage.primary.readAsString() ==
                await _encodeLibrarySnapshot(expected);
          } catch (_) {
            // A failure before primary publication leaves the previous state.
          }
          if (_saveSequence == sequence && !committed) {
            _applyTransferredSnapshot(before);
          }
        }
        notifyListeners();
        rethrow;
      }
      await _prepareTracks();
      notifyListeners();
    } finally {
      _profileImporting = false;
    }
  }

  void _applyTransferredSnapshot(Map<String, dynamic> snapshot) {
    features = LocalFeatures.fromJson(snapshot['localFeatures']);
    radioFeedbackRevision++;
    _tracks = [
      for (final row in snapshot['tracks'] as List)
        Track.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
    _playlists = [
      for (final row in snapshot['playlists'] as List)
        MusicPlaylist.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
    _liked = Set<String>.from(snapshot['liked'] as List);
    _likedPlaylists = Set<String>.from(snapshot['likedPlaylists'] as List);
    _likedAlbums = [
      for (final ids in snapshot['likedAlbums'] as List)
        Set<String>.from(ids as List),
    ];
    _recent = List<String>.from(snapshot['recent'] as List);
    _retainedTrackIds = Set<String>.from(snapshot['retainedTrackIds'] as List);
    _matchExcluded = Set<String>.from(snapshot['trackMatchExcluded'] as List);
    _preferredVariants = Set<String>.from(
      snapshot['preferredTrackVariants'] as List,
    );
    _trackPlayCounts = Map<String, int>.from(
      snapshot['trackPlayCounts'] as Map,
    );
    _playlistPlayCounts = Map<String, int>.from(
      snapshot['playlistPlayCounts'] as Map,
    );
    _settings = Map<String, dynamic>.from(snapshot['settings'] as Map);
  }
}
