part of 'app_controller.dart';

extension MusicSharing on AppController {
  /// Serialize activations so a second click during metadata lookup is retained.
  Future<void> openMusicLink(String value) {
    final pending = _musicLinkTail.then((_) async {
      while (busy != null && !_disposed && _shutdown == null) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_disposed || _shutdown != null) return;
      await run(tr('Открываем ссылку Mumpa…'), () async {
        final link = MusicShareLink.parse(value);
        var tracks = library.tracks.where(link.selects).toList();
        final collection = library.playlists
            .where((p) => p.sourceHash?.toLowerCase() == link.hash)
            .firstOrNull;
        // An existing release collection establishes the full file inventory.
        // For a subset, every requested index must already be known.
        final known = link.kind == MusicShareKind.release
            ? collection != null && tracks.isNotEmpty
            : tracks
                  .map((t) => t.torrentIndex)
                  .toSet()
                  .containsAll(link.indices);
        MusicPlaylist? openedCollection = collection;
        if (!known) {
          final operation = SourceOperation();
          _musicLinkOperation = operation;
          TorrentInfo info;
          try {
            info = await torrents.add(link.magnet, operation: operation);
          } finally {
            operation.cancel();
            if (identical(_musicLinkOperation, operation)) {
              _musicLinkOperation = null;
            }
          }
          if (_disposed) return;
          if (info.hash.toLowerCase() != link.hash) {
            throw const FormatException(
              'Раздача не соответствует ссылке Mumpa.',
            );
          }
          final all = torrents.tracks(info, link: link.magnet);
          tracks = all.where(link.selects).toList();
          if (tracks.isEmpty ||
              (link.kind != MusicShareKind.release &&
                  !tracks
                      .map((t) => t.torrentIndex)
                      .toSet()
                      .containsAll(link.indices))) {
            throw const FormatException(
              'В раздаче нет файлов из ссылки Mumpa.',
            );
          }
          if (link.kind == MusicShareKind.release) {
            openedCollection = await library.openSourceCollection(
              hash: info.hash,
              name: info.title,
              tracks: all,
            );
          } else {
            // Preserve edits and offline metadata for previously known files.
            await library.upsert(tracks.map((t) => library.byId(t.id) ?? t));
          }
          tracks = tracks.map((t) => library.byId(t.id) ?? t).toList();
        }
        if (_disposed) return;
        final missing = <Track>[];
        final stale = <String, Track>{};
        for (final track in tracks) {
          if (await library.localPathFor(track) == null) {
            missing.add(track);
            for (final copy in library.localCopiesFor(track)) {
              if (copy.cachedPath != null) {
                stale[copy.id] = copy.copyWith(clearCache: true);
              }
            }
          }
        }
        if (stale.isNotEmpty) {
          await library.upsert(stale.values, preserveCache: false);
          tracks = tracks.map((t) => library.byId(t.id) ?? t).toList();
        }
        if (_disposed) return;
        if (link.kind == MusicShareKind.release && openedCollection != null) {
          openPlaylist(openedCollection);
        } else {
          // A track link opens a focused page with that exact recording.
          openAlbum(Album(tracks), playlistId: collection?.id);
        }
        // Select the exact source from the link, regardless of the
        // recipient's preference for a different codec of the same recording.
        if (missing.isNotEmpty) downloads.enqueue(missing, exact: true);
        message = missing.isEmpty
            ? tr('Уже скачано — открываем музыку.')
            : tr('Добавлено в загрузки: {0}', [missing.length]);
      });
    });
    _musicLinkTail = pending;
    return pending;
  }

  Future<void> initializeMusicLinks(Iterable<String> arguments) async {
    for (final value in arguments.where(MusicShareLink.isMusicLink)) {
      unawaited(openMusicLink(value));
    }
    if (Platform.isWindows) {
      _musicLinksInitialized = true;
      const channel = MethodChannel('app.mumpa/links');
      channel.setMethodCallHandler((call) async {
        if (call.method == 'open' && call.arguments is String) {
          unawaited(openMusicLink(call.arguments as String));
        }
      });
      try {
        final links = await channel.invokeListMethod<String>('takeLinks');
        for (final link in links ?? <String>[]) {
          unawaited(openMusicLink(link));
        }
      } on MissingPluginException catch (_) {
      } on PlatformException catch (_) {}
    }
  }
}
