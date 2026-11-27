part of 'mumpa_mcp.dart';

class _McpOperation {
  _McpOperation(this.id, this.kind);

  final String id, kind;
  final cancellation = SourceOperation();
  late final Future<void> completion;
  String state = 'running';
  Json? result;
  McpError? error;
  DateTime? finishedAt;

  Json snapshot(Json args) {
    final outcome = result;
    return {
      'operation_id': id,
      'kind': kind,
      'state': state,
      if (state == 'running') 'poll_after_ms': 500,
      if (outcome != null)
        'result': {
          ...outcome,
          if (outcome['items'] case final List items)
            ..._page(items, args, (item) => item),
        },
      if (error != null) 'error': error!.toJson(),
    };
  }
}

extension _McpSources on MumpaMcp {
  List<McpTool> get _sourceTools => [
    McpTool(
      'search_online',
      'Start a search for catalog recordings, available music releases, or an artist and their discography. '
          'Poll mumpa_operation. Use recording_id from recordings for find_versions, or release_id from releases for open_source.',
      _searchOnline,
      properties: {
        'kind': _choice(['recordings', 'releases', 'artist']),
        'query': _text,
      },
      required: ['kind', 'query'],
      network: true,
    ),
    McpTool(
      'similar_artists',
      'Start a similar-artist lookup using a MusicBrainz artist_id from search_online. Poll mumpa_operation.',
      _similarArtists,
      properties: {'artist_id': _id},
      required: ['artist_id'],
      network: true,
    ),
    McpTool(
      'find_versions',
      'Find playable file versions of an online recording by recording_id. Poll mumpa_operation, '
          'then pass a variant_id to open_source to import that exact version.',
      _findVersions,
      properties: {'recording_id': _id},
      required: ['recording_id'],
      network: true,
    ),
    McpTool(
      'open_source',
      'Inspect the audio files of a release, BTIH magnet or local .torrent, or import it as a source playlist. '
          'Supply one of release_id, magnet, torrent_path or variant_id. Optional file_indices select files when first importing '
          'a release. A variant_id imports the collection and returns the exact track_id. Poll mumpa_operation.',
      _openSource,
      properties: {
        'action': _choice(['inspect', 'import']),
        'release_id': _id,
        'variant_id': _id,
        'magnet': {'type': 'string', 'minLength': 1, 'maxLength': 4096},
        'torrent_path': {'type': 'string', 'minLength': 1, 'maxLength': 4096},
        'file_indices': {
          'type': 'array',
          'items': _offset,
          'minItems': 1,
          'maxItems': 500,
        },
      },
      required: ['action'],
      network: true,
    ),
    McpTool(
      'import_local',
      'Add music from absolute paths on local Windows drives. Directories are scanned recursively. '
          'Poll mumpa_operation for imported track IDs.',
      _importLocal,
      properties: {
        'paths': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 30,
          'items': {'type': 'string', 'minLength': 1, 'maxLength': 4096},
        },
      },
      required: ['paths'],
    ),
    McpTool(
      'operation',
      'Read the state or result of a background operation. Follow result.next_offset for result items. '
          'Use cancel=true to request cancellation of an active operation.',
      _operationStatus,
      properties: {'operation_id': _id, 'cancel': _bool, ..._pageFields},
      required: ['operation_id'],
    ),
  ];

  Json _startOperation(
    String kind,
    Future<Json> Function(SourceOperation) run, {
    Duration timeout = const Duration(minutes: 2),
  }) {
    _pruneOperations();
    if (_operations.values.where((job) => job.finishedAt == null).length >= 4) {
      throw const McpError(
        'busy',
        'Four background operations are active. Poll or cancel one before starting another.',
      );
    }
    if (_operations.length >= 48) {
      _operations.remove(
        _operations.values.firstWhere((job) => job.finishedAt != null).id,
      );
    }
    final job = _McpOperation(_newKey(12), kind);
    _operations[job.id] = job;
    job.completion = _runOperation(job, run, timeout);
    return job.snapshot(const {});
  }

  Future<void> _runOperation(
    _McpOperation job,
    Future<Json> Function(SourceOperation) run,
    Duration timeout,
  ) async {
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = !job.cancellation.cancelled;
      job.cancellation.cancel();
    });
    try {
      job.result = await run(job.cancellation);
      job.state = 'succeeded';
    } on SourceCancelled {
      job.state = timedOut ? 'failed' : 'cancelled';
      if (timedOut) {
        job.error = McpError.from(TimeoutException('MCP operation'));
      }
    } catch (error) {
      job.state = 'failed';
      job.error = McpError.from(error);
    } finally {
      timer.cancel();
      job.cancellation.cancel();
      job.finishedAt = DateTime.now();
    }
  }

  void _pruneOperations() {
    final now = DateTime.now();
    _operations.removeWhere(
      (_, job) =>
          job.finishedAt?.add(const Duration(minutes: 20)).isBefore(now) ==
          true,
    );
  }

  Json _operationStatus(Json args) {
    _pruneOperations();
    final job =
        _operations[_str(args, 'operation_id')] ??
        _missing('Operation ID is unknown or expired.');
    if (args['cancel'] == true && job.finishedAt == null) {
      job.cancellation.cancel();
    }
    return {
      ...job.snapshot(args),
      if (job.finishedAt == null && job.cancellation.cancelled)
        'cancellation_requested': true,
    };
  }

  String _reference(Object value) {
    final now = DateTime.now();
    _references.removeWhere((_, ref) => ref.expires.isBefore(now));
    if (_references.length >= 1024) _references.remove(_references.keys.first);
    final id = _newKey(12);
    _references[id] = (
      value: value,
      expires: now.add(const Duration(minutes: 20)),
    );
    return id;
  }

  T _referenced<T extends Object>(String id) {
    final entry = _references[id];
    if (entry == null || entry.expires.isBefore(DateTime.now())) {
      _references.remove(id);
      _missing('Search reference is unknown or expired. Repeat the search.');
    }
    final value = entry.value;
    if (value is! T) _invalid('Wrong type of search reference.');
    return value;
  }

  Json _recording(MusicRecording recording) => {
    'recording_id': _reference(recording),
    'catalog_id': recording.key,
    'title': recording.title,
    'artist': recording.artist,
    'duration_ms': recording.durationMs,
    'albums': recording.albumTitles.take(20).toList(),
    if (recording.explicit != null) 'explicit': recording.explicit,
  };

  Json _searchOnline(Json args) {
    final query = _str(args, 'query');
    final kind = args['kind'] as String;
    return _startOperation(kind, (operation) async {
      switch (kind) {
        case 'recordings':
          final found = await app.musicCatalog.search(
            query,
            operation: operation,
          );
          return {
            'query': query,
            'unavailable_providers': found.unavailableProviders,
            'items': found.recordings.take(200).map(_recording).toList(),
          };
        case 'artist':
          final found = await app.metadata.artist(query, operation: operation);
          if (found == null) _missing('The catalog did not find this artist.');
          return {
            'artist_id': found.id,
            'artist': found.name,
            'provider': found.provider,
            'items': [
              for (final album in found.albums)
                {
                  'id': album.id,
                  'title': album.title,
                  'artist': album.artist,
                  'year': album.year,
                  'type': album.type,
                },
            ],
          };
        default:
          if (app.usesIndexer && !app.indexerConnected) {
            throw const McpError(
              'source_not_configured',
              'Configure a music source in Mumpa settings.',
            );
          }
          final indexed = app.usesIndexer
              ? await app.lookupIndexedReleases(query, operation: operation)
              : null;
          final releases =
              indexed?.releases ??
              (await operation.wait(app.catalog.search(query))).releases;
          return {
            'query': query,
            'corrected_query': indexed?.correctedQuery,
            'suggestions': indexed?.suggestions ?? const <String>[],
            'items': [
              for (final release in releases.take(200))
                {
                  'release_id': _reference(release),
                  'title': release.title,
                  'provider': release.indexerName,
                  'bytes': release.bytes,
                  'seeders': release.seedersKnown ? release.seeders : null,
                },
            ],
          };
      }
    });
  }

  Json _similarArtists(Json args) {
    final id = _str(args, 'artist_id');
    if (!RegExp(
      r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(id)) {
      _invalid('artist_id must be a MusicBrainz UUID.');
    }
    return _startOperation('similar_artists', (operation) async {
      final results = await app.similarArtists.similarArtists(
        id,
        operation: operation,
      );
      return {
        'items': [
          for (final artist in results)
            {
              'artist_id': artist.id,
              'name': artist.name,
              'score': artist.score,
              'description': artist.disambiguation,
            },
        ],
      };
    });
  }

  Json _findVersions(Json args) {
    final recording = _referenced<MusicRecording>(_str(args, 'recording_id'));
    if (!app.usesIndexer || !app.indexerConnected) {
      throw const McpError(
        'source_not_configured',
        'Choose the automatic source or configure a Torznab source in Mumpa.',
      );
    }
    final endpoint = app.sourceEndpoint, key = app.sourceKey;
    return _startOperation('find_versions', (operation) async {
      final detailed = await app.musicCatalog.details(
        recording,
        operation: operation,
      );
      final variants = await app.trackSearch.find(
        detailed,
        endpoint: endpoint,
        key: key,
        operation: operation,
      );
      return {
        'items': [
          for (final variant in variants.take(200))
            {
              'variant_id': _reference(variant),
              'title': variant.track.title,
              'artist': variant.track.artist,
              'album': variant.track.album,
              'format': variant.format,
              'edition': variant.edition,
              'release': variant.release.title,
              'bytes': variant.track.bytes,
            },
        ],
      };
    });
  }

  Json _openSource(Json args) {
    const selectors = ['release_id', 'magnet', 'torrent_path', 'variant_id'];
    if (selectors.where(args.containsKey).length != 1) {
      _invalid(
        'Supply exactly one of release_id, magnet, torrent_path or variant_id.',
      );
    }
    final importing = args['action'] == 'import';
    final variant = args['variant_id'] == null
        ? null
        : _referenced<TrackVariant>(_str(args, 'variant_id'));
    final release = args['release_id'] == null
        ? null
        : _referenced<SearchRelease>(_str(args, 'release_id'));
    final magnet = args['magnet'] as String?;
    final torrentPath = args['torrent_path'] == null
        ? null
        : _localPath(_str(args, 'torrent_path'));
    final indices = (args['file_indices'] as List?)?.cast<int>().toSet();
    if ((!importing && (variant != null || indices != null)) ||
        (variant != null && indices != null)) {
      _invalid(
        'Variants require import. file_indices are allowed when importing a magnet, .torrent or release.',
      );
    }
    if (magnet != null) {
      final uri = Uri.tryParse(magnet);
      final hashes = uri?.queryParametersAll['xt'] ?? const [];
      if (uri?.scheme != 'magnet' ||
          !hashes.any(
            RegExp(
              r'^urn:btih:([0-9a-f]{40}|[a-z2-7]{32})$',
              caseSensitive: false,
            ).hasMatch,
          )) {
        _invalid('Supply a valid BTIH magnet URI.');
      }
    }
    return _startOperation('open_source', (operation) async {
      if (variant != null) {
        final imported = await app.importTrackVariant(
          variant,
          operation: operation,
        );
        return {
          'playlist_id': imported.playlist.id,
          'track_id': imported.selected.id,
          'track': _trackJson(imported.selected),
        };
      }
      final opened = release != null
          ? await app.resolveRelease(release, operation: operation)
          : torrentPath == null
          ? (
              info: await app.torrents.add(magnet!, operation: operation),
              link: magnet,
            )
          : (info: await _uploadTorrent(torrentPath, operation), link: null);
      operation.check();
      final info = opened.info;
      final tracks = app.torrents.tracks(
        info,
        link: opened.link,
        album: release?.title,
        artist: inferredReleaseArtist(release?.title ?? info.title),
      );
      if (tracks.isEmpty) {
        throw const McpError(
          'no_audio',
          'This source has no supported audio files.',
        );
      }
      if (!importing) {
        return {
          'title': info.title,
          'file_count': tracks.length,
          'items': [
            for (final track in tracks)
              {
                'file_index': track.torrentIndex,
                'title': track.title,
                'artist': track.artist,
                'album': track.album,
                'format': track.format,
                'bytes': track.bytes,
              },
          ],
        };
      }
      if (indices != null &&
          !tracks
              .map((track) => track.torrentIndex)
              .toSet()
              .containsAll(indices)) {
        _invalid('One or more file_indices are absent from this source.');
      }
      final selected = indices == null
          ? tracks
          : tracks
                .where((track) => indices.contains(track.torrentIndex))
                .toList();
      final playlist = await _library.openSourceCollection(
        hash: info.hash,
        name: release?.title ?? info.title,
        tracks: selected,
      );
      return {
        'playlist_id': playlist.id,
        'track_count': playlist.trackIds.length,
        'items': playlist.trackIds
            .map(_library.byId)
            .whereType<Track>()
            .map(_trackJson)
            .toList(),
      };
    });
  }

  Future<TorrentInfo> _uploadTorrent(
    String path,
    SourceOperation operation,
  ) async {
    if (p.windows.extension(path).toLowerCase() != '.torrent' ||
        await operation.wait(FileSystemEntity.type(path, followLinks: false)) !=
            FileSystemEntityType.file) {
      _invalid('torrent_path must point to an existing .torrent file.');
    }
    final length = await operation.wait(File(path).length());
    if (length == 0 || length > 16 * 1024 * 1024) {
      _invalid('torrent_path must point to a .torrent file up to 16 MiB.');
    }
    return app.torrents.upload(path, operation: operation);
  }

  String _localPath(String path) {
    if (!RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) ||
        path.substring(2).contains(':') ||
        path.contains('\u0000')) {
      _invalid('Every path must be absolute on a local Windows drive.');
    }
    return p.windows.normalize(path);
  }

  Json _importLocal(Json args) {
    final paths = _strings(args, 'paths').map(_localPath).toSet();
    return _startOperation('import_local', (operation) async {
      for (final path in paths) {
        final type = await operation.wait(
          FileSystemEntity.type(path, followLinks: false),
        );
        if (type != FileSystemEntityType.directory &&
            !(type == FileSystemEntityType.file && isAudioPath(path))) {
          _invalid(
            'One or more paths do not refer to an existing audio file or directory.',
          );
        }
      }
      final tracks = await _library.importPaths(
        paths.toList(),
        checkCancelled: operation.check,
      );
      return {
        'track_count': tracks.length,
        'items': tracks.map(_trackJson).toList(),
      };
    }, timeout: const Duration(minutes: 10));
  }
}
