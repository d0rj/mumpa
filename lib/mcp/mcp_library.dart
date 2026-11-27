part of 'mumpa_mcp.dart';

extension _McpLibrary on MumpaMcp {
  List<McpTool> get _libraryTools => [
    McpTool(
      'library',
      'Search or browse tracks, albums and playlists using an optional text query. '
          'Scopes library, favorites, offline, recent and all refer to this device. '
          'All includes temporary source collections. Pass next_offset for more results.',
      _browse,
      properties: {
        'kind': _choice(['tracks', 'albums', 'playlists']),
        'scope': _choice(['library', 'favorites', 'offline', 'recent', 'all']),
        'query': _text,
        ..._pageFields,
      },
      required: ['kind'],
      readOnly: true,
    ),
    McpTool(
      'collection',
      'Read the ordered tracks of an album or playlist by ID. Supply exactly one ID. Pass next_offset for more tracks.',
      _collection,
      properties: {'album_id': _id, 'playlist_id': _id, ..._pageFields},
      readOnly: true,
    ),
    McpTool(
      'favorite',
      'Set the desired favorite state for a track, album, or playlist by ID.',
      _favorite,
      properties: {
        'kind': _choice(['track', 'album', 'playlist']),
        'id': _id,
        'liked': _bool,
      },
      required: ['kind', 'id', 'liked'],
      idempotent: true,
    ),
    McpTool(
      'playlist_create',
      'Create a playlist with an optional ordered list of exact track IDs.',
      _createPlaylist,
      properties: {'name': _text, 'track_ids': _ids},
      required: ['name'],
    ),
    McpTool(
      'playlist_edit',
      'Rename, append, remove tracks, replace track order, or delete a saved playlist. '
          'Replace accepts an empty track_ids array to clear a playlist. Delete removes the playlist only. '
          'Smart playlists allow rename and delete. The built-in Top 50 is read-only.',
      _editPlaylist,
      properties: {
        'playlist_id': _id,
        'action': _choice(['rename', 'append', 'remove', 'replace', 'delete']),
        'name': _text,
        'track_ids': {..._ids, 'minItems': 0},
      },
      required: ['playlist_id', 'action'],
      idempotent: true,
      destructive: true,
    ),
    McpTool(
      'smart_playlist',
      'Create or update a playlist defined by a rule. Provide playlist_id to update an existing smart playlist. '
          'The supplied rule replaces the previous rule.',
      _saveSmartPlaylist,
      properties: {
        'playlist_id': _id,
        'name': _text,
        'rule': {
          'type': 'object',
          'additionalProperties': false,
          'required': <String>[],
          'properties': {
            'liked': _bool,
            'offline': _bool,
            'unplayed': _bool,
            'artist': _id,
            for (final key in [
              'fromYear',
              'toYear',
              'notPlayedDays',
              'addedDays',
            ])
              key: {'type': 'integer', 'minimum': 0, 'maximum': 9999},
            'sort': _choice(['title', 'rare', 'recent']),
            'limit': {'type': 'integer', 'minimum': 1, 'maximum': 5000},
          },
        },
      },
      required: ['name', 'rule'],
    ),
    McpTool(
      'track_edit',
      'Edit a track’s display metadata, pin it in the library, choose it as the preferred version, '
          'or change matching exclusion. These changes apply to this device.',
      _editTrack,
      properties: {
        'track_id': _id,
        'title': _text,
        'artist': _text,
        'album': _text,
        'album_artist': _text,
        'pinned': _bool,
        'preferred': _bool,
        'exclude_from_matching': _bool,
      },
      required: ['track_id'],
      idempotent: true,
    ),
    McpTool(
      'downloads',
      'Read download progress by track ID, with optional state filter. Use next_offset for more jobs.',
      _downloads,
      properties: {
        'state': _choice(
          DownloadState.values.map((state) => state.name).toList(),
        ),
        ..._pageFields,
      },
      readOnly: true,
    ),
    McpTool(
      'download_edit',
      'Queue exact track versions for offline use, pause or retry jobs, or remove their managed offline copies.',
      _editDownloads,
      properties: {
        'action': _choice(['enqueue', 'pause', 'retry', 'remove_offline']),
        'track_ids': _ids,
      },
      required: ['action', 'track_ids'],
      destructive: true,
      idempotent: true,
      network: true,
    ),
    McpTool(
      'listening',
      'Read listening totals, top artists and daily listening time over the last N local calendar days.',
      _listening,
      properties: {
        'days': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 366,
          'default': 30,
        },
      },
      readOnly: true,
    ),
  ];

  Json _albumJson(Album album) => {
    'id': album.id,
    'title': album.title,
    'artist': album.artist,
    'track_count': album.tracks.length,
    'offline': album.offline,
    'liked': _library.favoriteAlbums.any((saved) => saved.id == album.id),
  };

  Json _playlistJson(MusicPlaylist playlist) => {
    'id': playlist.id,
    'name': playlist.name,
    'track_count': playlist.trackIds.length,
    'kind': playlist.isSmart
        ? 'smart'
        : playlist.isSystem
        ? 'system'
        : playlist.sourceHash == null
        ? 'manual'
        : 'source',
    'liked': _library.isPlaylistLiked(playlist.id),
    if (playlist.isSmart) 'rule': playlist.smartRule,
  };

  Json _browse(Json args) {
    final scope = args['scope'] ?? 'library';
    final query = normalizeMusicName(args['query'] as String? ?? '');
    final terms = query.isEmpty ? const <String>[] : query.split(' ');
    bool matches(String fields) {
      if (terms.isEmpty) return true;
      final searchable = normalizeMusicName(fields);
      return terms.every(searchable.contains);
    }

    final recent = _library.recent.map(_library.byId).whereType<Track>();
    return switch (args['kind']) {
      'tracks' => _page(
        (switch (scope) {
          'favorites' => _library.favoriteTracks,
          'offline' => _library.tracks.where((track) => track.offline),
          'recent' => recent,
          'all' => _library.tracks,
          _ => _library.mediaTracks,
        }).where(
          (track) => matches(
            '${track.artist} ${track.title} ${track.album} ${track.format}',
          ),
        ),
        args,
        _trackJson,
      ),
      'albums' => _page(
        (switch (scope) {
          'favorites' => _library.favoriteAlbums,
          'offline' => _library.albums.where((album) => album.offline),
          'recent' =>
            recent
                .map((track) => track.albumKey)
                .toSet()
                .map(_library.albumById)
                .whereType<Album>(),
          'all' => _library.albums,
          _ => _library.mediaAlbums,
        }).where((album) => matches('${album.artist} ${album.title}')),
        args,
        _albumJson,
      ),
      _ => _page(
        (switch (scope) {
          'favorites' => _library.favoritePlaylists,
          'offline' => _library.playlists.where(
            (playlist) =>
                playlist.trackIds.isNotEmpty &&
                playlist.trackIds.every(
                  (id) => _library.byId(id)?.offline == true,
                ),
          ),
          'recent' => _library.frequentPlaylists,
          'all' => [_library.topTracksPlaylist, ..._library.playlists],
          _ => [_library.topTracksPlaylist, ..._library.mediaPlaylists],
        }).where((playlist) => matches(playlist.name)),
        args,
        _playlistJson,
      ),
    };
  }

  Json _collection(Json args) {
    if (args.containsKey('album_id') == args.containsKey('playlist_id')) {
      _invalid('Supply exactly one album_id or playlist_id.');
    }
    if (args.containsKey('album_id')) {
      final album = _album(_str(args, 'album_id'));
      return {
        'album': _albumJson(album),
        ..._page(album.tracks, args, _trackJson),
      };
    }
    final playlist = _playlist(_str(args, 'playlist_id'));
    final tracks = playlist.trackIds.map(_library.byId).whereType<Track>();
    return {
      'playlist': _playlistJson(playlist),
      ..._page(tracks, args, _trackJson),
    };
  }

  Future<Json> _favorite(Json args) async {
    final id = _str(args, 'id'), liked = args['liked'] as bool;
    switch (args['kind']) {
      case 'track':
        _track(id);
        if (_library.isTrackLiked(id) != liked) await _library.toggleLike(id);
      case 'album':
        final album = _album(id);
        final saved = _library.favoriteAlbums
            .where((item) => item.id == id)
            .toList();
        if (liked && saved.isEmpty) {
          await _library.toggleAlbumLike(album);
        }
        if (!liked) {
          for (final selection in saved) {
            if (_library.isAlbumLiked(selection)) {
              await _library.toggleAlbumLike(selection);
            }
          }
        }
      case 'playlist':
        final playlist = _playlist(id);
        if (playlist.id == MusicPlaylist.deviceTop50Id) {
          _invalid('Top 50 cannot be favorited.');
        }
        if (_library.isPlaylistLiked(id) != liked) {
          await _library.togglePlaylistLike(id);
        }
    }
    return {'id': id, 'kind': args['kind'], 'liked': liked};
  }

  Future<Json> _createPlaylist(Json args) async {
    final ids = (args['track_ids'] as List? ?? []).cast<String>();
    for (final id in ids) {
      _track(id);
    }
    final playlist = await _library.createPlaylistWithTracks(
      _str(args, 'name'),
      trackIds: ids,
    );
    return _playlistJson(playlist);
  }

  Future<Json> _editPlaylist(Json args) async {
    final playlist = _playlist(_str(args, 'playlist_id')),
        action = args['action'];
    final editTracks = ['append', 'remove', 'replace'].contains(action);
    if (playlist.id == MusicPlaylist.deviceTop50Id ||
        (playlist.isSmart && editTracks)) {
      _invalid('This playlist does not support that edit.');
    }
    if ((action == 'rename') != args.containsKey('name') ||
        editTracks != args.containsKey('track_ids')) {
      _invalid(
        'Rename requires name. Append, remove and replace require track_ids.',
      );
    }
    final id = playlist.id;
    final ids = (args['track_ids'] as List? ?? []).cast<String>();
    if (action == 'append' || action == 'replace') {
      for (final trackId in ids) {
        _track(trackId);
      }
    }
    switch (action) {
      case 'delete':
        await _library.deletePlaylist(id);
        return {'id': id, 'deleted': true};
      case 'rename':
        await _library.renamePlaylist(id, _str(args, 'name'));
      case 'append':
        await _library.addToPlaylist(id, ids);
      case 'remove':
        await _library.removePlaylistTracks(id, ids);
      case 'replace':
        await _library.replacePlaylistTracks(id, ids);
    }
    return _playlistJson(_playlist(id));
  }

  Future<Json> _saveSmartPlaylist(Json args) async {
    final playlist = args.containsKey('playlist_id')
        ? _playlist(_str(args, 'playlist_id'))
        : null;
    if (playlist != null && !playlist.isSmart) {
      _invalid('playlist_id must identify a smart playlist.');
    }
    final rule = args['rule'] as Json;
    final from = rule['fromYear'], to = rule['toYear'];
    if (from is int && to is int && from > to) {
      _invalid('fromYear must be less than or equal to toYear.');
    }
    final saved = await _library.saveSmartPlaylist(
      _str(args, 'name'),
      rule,
      id: playlist?.id,
    );
    return _playlistJson(saved);
  }

  Future<Json> _editTrack(Json args) async {
    final track = _track(_str(args, 'track_id'));
    if (args.length == 1) _invalid('Supply at least one track edit.');
    if (args['preferred'] == false) {
      _invalid('Use preferred=true to select this version.');
    }
    final edits = {
      for (final key in ['title', 'artist', 'album', 'album_artist'])
        if (args.containsKey(key))
          key == 'album_artist' ? 'albumArtist' : key: _str(args, key),
    };
    if (edits.isNotEmpty) await _library.editMetadata(track, edits);
    if (args['pinned'] case bool pinned) {
      await _library.setPinned([track.id], pinned);
    }
    if (args['exclude_from_matching'] case bool excluded) {
      await _library.setTrackMatchExcluded(track.id, excluded);
    }
    if (args['preferred'] == true) await _library.preferTrackVariant(track.id);
    return {
      ..._trackJson(_track(track.id)),
      'pinned': _library.features.pinned.contains(track.id),
      'preferred': _library.isPreferredVariant(track.id),
      'excluded_from_matching': _library.isMatchExcluded(track.id),
    };
  }

  Json _downloadJson(DownloadJob job) => {
    'track': _trackJson(_library.byId(job.track.id) ?? job.track),
    'state': job.state.name,
    'received_bytes': job.received,
    'total_bytes': job.total,
    if (job.state == DownloadState.failed)
      'error': {
        'code': 'download_failed',
        'message': 'Retry the job or select a different source.',
      },
  };

  Json _downloads(Json args) => {
    'waiting_for_conditions': app.downloads.waitingForConditions,
    ..._page(
      app.downloads.jobs.where(
        (job) => args['state'] == null || job.state.name == args['state'],
      ),
      args,
      _downloadJson,
    ),
  };

  Future<Json> _editDownloads(Json args) async {
    final tracks = _strings(args, 'track_ids').toSet().map(_track).toList();
    final ids = tracks.map((track) => track.id).toSet();
    final downloads = app.downloads;
    if (args['action'] == 'pause' || args['action'] == 'retry') {
      final existing = downloads.jobs.map((job) => job.track.id).toSet();
      if (!existing.containsAll(ids)) {
        _missing('One or more track IDs have no download job.');
      }
    }
    switch (args['action']) {
      case 'enqueue':
        downloads.enqueue(tracks, exact: true);
      case 'pause':
        ids.forEach(downloads.pause);
      case 'retry':
        ids.forEach(downloads.retry);
      case 'remove_offline':
        for (final track in tracks) {
          await downloads.removeOffline(_track(track.id), userRequested: true);
        }
    }
    return {
      'tracks': tracks.map((track) => _trackJson(_track(track.id))).toList(),
      'jobs': downloads.jobs
          .where((job) => ids.contains(job.track.id))
          .map(_downloadJson)
          .toList(),
    };
  }

  Json _listening(Json args) {
    final days = args['days'] as int? ?? 30;
    final now = DateTime.now();
    final since = DateTime(now.year, now.month, now.day - days + 1);
    final summary = _library.listeningSummary(since: since, until: now);
    final artists = summary.artists.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final daily = summary.daily.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return {
      'days': days,
      'plays': summary.plays,
      'listened_ms': summary.milliseconds,
      'top_artists': [
        for (final entry in artists.take(25))
          {'artist': entry.key, 'listened_ms': entry.value},
      ],
      'daily': [
        for (final entry in daily)
          {'day': entry.key, 'listened_ms': entry.value},
      ],
    };
  }
}
