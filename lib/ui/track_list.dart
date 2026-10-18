part of 'components.dart';

abstract class SliverContent extends StatelessWidget {
  const SliverContent({super.key});
}

class LazyRows extends SliverContent {
  const LazyRows({super.key, required this.count, required this.builder});
  final int count;
  final IndexedWidgetBuilder builder;
  @override
  Widget build(BuildContext context) =>
      SliverList.builder(itemCount: count, itemBuilder: builder);
}

class TrackList extends SliverContent {
  const TrackList({
    super.key,
    required this.app,
    required this.tracks,
    this.playlistId,
    this.queueTracks,
    this.onReorder,
  });
  final AppController app;
  final List<Track> tracks;
  final List<Track>? queueTracks;
  final String? playlistId;
  final ReorderCallback? onReorder;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      app.playback.trackState,
      app.library,
      app.downloads,
      app,
    ]),
    builder: (_, _) {
      final rows = app.library.matchedTracks(tracks);
      final occurrences = <String, int>{};
      final keys = [
        for (final row in rows)
          ValueKey((
            row.anchor.id,
            occurrences.update(row.anchor.id, (n) => n + 1, ifAbsent: () => 0),
          )),
      ];
      Widget buildRow(BuildContext context, int i) {
        final row = rows[i];
        final anchor = row.anchor;
        final current = app.playback.current;
        final active = current != null && row.group.ids.contains(current.id);
        final t = active ? current : row.preferred;
        final liked = row.group.ids.any(app.library.isTrackLiked);
        void play([Track? version]) {
          final queue = queueTracks ?? tracks;
          final index = queue.indexWhere((item) => item.id == anchor.id);
          if (index < 0) return;
          app.playCollection(
            queue,
            index: index,
            playlistId: playlistId,
            selectedVariant: version,
          );
        }

        Future<void> chooseVersion() async {
          final version = await showKnownTrackVersions(context, app, row);
          if (version != null && context.mounted) play(version);
        }

        final downloading = app.downloads.jobs
            .where(
              (j) => j.track.id == t.id && j.state == DownloadState.downloading,
            )
            .firstOrNull;
        final canReveal = FileLocationService.canReveal(app.library, t);
        Future<void> revealFile() async {
          try {
            await FileLocationService.revealTrack(app.library, t);
          } on FileSystemException catch (error) {
            app.reportError(error.message);
          } catch (_) {
            app.reportError(
              'Не удалось открыть расположение трека в проводнике.',
            );
          }
        }

        return LayoutBuilder(
          key: keys[i],
          builder: (context, c) => InkWell(
            key: ValueKey('track-row-${anchor.id}'),
            onTap: row.group.multiple ? chooseVersion : () => play(),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
              child: Row(
                children: [
                  if (onReorder == null || c.maxWidth > 450)
                    SizedBox(
                      width: 30,
                      height: 30,
                      child: active && app.playback.buffering
                          ? const Center(
                              child: SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : active
                          ? Center(
                              child: app.playback.stopped
                                  ? const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 18,
                                      color: accent,
                                    )
                                  : PlayingIndicator(
                                      key: ValueKey('playing-wave-${t.id}'),
                                      playing: app.playback.playing,
                                      size: 20,
                                    ),
                            )
                          : Text(
                              '${i + 1}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: muted),
                            ),
                    ),
                  TrackStackArtwork(
                    app: app,
                    track: row.preferred,
                    variants: row.group.variants,
                    rowId: anchor.id,
                    onPlay: () => play(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.title,
                          key: ValueKey('track-title-${anchor.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: active ? accent : Colors.white,
                          ),
                        ),
                        ArtistLink(
                          artist: t.artist,
                          onOpen: () => app.openArtist(t.artist),
                          style: const TextStyle(color: muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  if (c.maxWidth > 700)
                    Expanded(
                      flex: 3,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: AlbumLink(
                          album: t.album,
                          onOpen: () => app.openTrackAlbum(t),
                          key: ValueKey('track-album-${anchor.id}'),
                          style: const TextStyle(fontSize: 12, color: muted),
                        ),
                      ),
                    ),
                  if (c.maxWidth > 500)
                    SizedBox(
                      width: 64,
                      child: Text(
                        t.format,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 10, color: muted),
                      ),
                    ),
                  if (row.group.multiple)
                    TextButton(
                      key: ValueKey('track-versions-${anchor.id}'),
                      onPressed: chooseVersion,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        foregroundColor: accent,
                      ),
                      child: Text(
                        '×${row.group.variants.length}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  if (onReorder == null || c.maxWidth > 450)
                    SizedBox(
                      key: ValueKey('track-status-${anchor.id}'),
                      width: 28,
                      height: 22,
                      child: Center(
                        child: t.offline
                            ? const Tooltip(
                                message: 'Доступен офлайн',
                                child: Icon(
                                  Icons.download_done_rounded,
                                  size: 14,
                                  color: accent,
                                ),
                              )
                            : downloading != null
                            ? Tooltip(
                                message: 'Сохраняется для офлайн',
                                child: SizedBox.square(
                                  dimension: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    value: downloading.progress,
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  IconButton(
                    onPressed: () =>
                        app.library.toggleMatchedTrackLike(row.group, t.id),
                    tooltip: liked ? 'Убрать из любимого' : 'В любимое',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      size: 19,
                      color: liked ? accent : muted,
                    ),
                  ),
                  if (FileLocationService.available && c.maxWidth > 450)
                    SizedBox(
                      width: 40,
                      child: canReveal
                          ? IconButton(
                              key: ValueKey('track-reveal-${anchor.id}'),
                              onPressed: revealFile,
                              tooltip: 'Показать в проводнике',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(
                                Icons.folder_open_rounded,
                                size: 19,
                                color: muted,
                              ),
                            )
                          : null,
                    ),
                  if (c.maxWidth > 450)
                    SizedBox(
                      width: 40,
                      child: Text(
                        t.durationMs > 0 ? formatTime(t.duration) : '—',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 11, color: muted),
                      ),
                    ),
                  PopupMenuButton<String>(
                    key: ValueKey('track-actions-${anchor.id}'),
                    tooltip: 'Действия с треком',
                    icon: const Icon(
                      Icons.more_horiz_rounded,
                      color: muted,
                      size: 20,
                    ),
                    onSelected: (action) async {
                      switch (action) {
                        case 'moveUp':
                          onReorder!(i, i - 1);
                        case 'moveDown':
                          onReorder!(i, i + 1);
                        case 'versions':
                          await chooseVersion();
                        case 'joinMatching':
                          await app.library.setTrackMatchExcluded(
                            anchor.id,
                            false,
                          );
                        case 'next':
                          app.playback.enqueue(t, next: true);
                        case 'queue':
                          app.playback.enqueue(t);
                        case 'download':
                          app.downloads.enqueue([t]);
                        case 'revealFile':
                          await revealFile();
                        case 'removeCache':
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Удалить офлайн-копию?'),
                              content: const Text(
                                'Трек сохранится в библиотеке и избранном, '
                                'но для прослушивания потребуется сеть.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Отмена'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Удалить копию'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await app.downloads.removeOffline(
                              t,
                              userRequested: true,
                            );
                          }
                        case 'artist':
                          app.openArtist(t.artist);
                        case 'album':
                          app.openTrackAlbum(t);
                        case 'removePlaylist':
                          await app.library.removePlaylistTracks(
                            playlistId!,
                            row.members.map((track) => track.id),
                          );
                        case 'addPlaylist':
                          if (context.mounted) {
                            await choosePlaylist(context, app, [t.id]);
                          }
                        case 'currentPlaylist':
                          await app.addToCurrentPlaylist(t);
                      }
                    },
                    itemBuilder: (_) => [
                      if (onReorder != null) ...[
                        PopupMenuItem(
                          value: 'moveUp',
                          enabled: i > 0,
                          child: const Text('Выше в плейлисте'),
                        ),
                        PopupMenuItem(
                          value: 'moveDown',
                          enabled: i < rows.length - 1,
                          child: const Text('Ниже в плейлисте'),
                        ),
                      ],
                      const PopupMenuItem(
                        value: 'album',
                        child: Text('Перейти к альбому'),
                      ),
                      if (row.group.multiple)
                        const PopupMenuItem(
                          value: 'versions',
                          child: Text('Выбрать версию'),
                        ),
                      if (app.library.isMatchExcluded(anchor.id))
                        const PopupMenuItem(
                          value: 'joinMatching',
                          child: Text('Снова объединять похожие версии'),
                        ),
                      const PopupMenuItem(
                        value: 'next',
                        child: Text('Слушать следующим'),
                      ),
                      const PopupMenuItem(
                        value: 'queue',
                        child: Text('В конец очереди'),
                      ),
                      const PopupMenuItem(
                        value: 'addPlaylist',
                        child: Text('Добавить в плейлист'),
                      ),
                      if (app.currentPlaylist != null &&
                          !app.currentPlaylist!.trackIds.contains(t.id))
                        PopupMenuItem(
                          value: 'currentPlaylist',
                          child: Text(
                            'В текущий плейлист «${app.currentPlaylist!.name}»',
                          ),
                        ),
                      if (hasArtistPage(t.artist))
                        const PopupMenuItem(
                          value: 'artist',
                          child: Text('Все треки исполнителя'),
                        ),
                      if (t.source == TrackSource.torrent &&
                          t.cachedPath == null)
                        const PopupMenuItem(
                          value: 'download',
                          child: Text('Скачать для офлайн'),
                        ),
                      if (t.cachedPath != null)
                        const PopupMenuItem(
                          value: 'removeCache',
                          child: Text('Удалить офлайн-копию'),
                        ),
                      if (canReveal)
                        const PopupMenuItem(
                          value: 'revealFile',
                          child: Text('Показать в проводнике'),
                        ),
                      if (playlistId != null)
                        const PopupMenuItem(
                          value: 'removePlaylist',
                          child: Text('Убрать из плейлиста'),
                        ),
                    ],
                  ),
                  if (onReorder != null)
                    ReorderableDragStartListener(
                      key: ValueKey('playlist-drag-${anchor.id}'),
                      index: i,
                      child: const Tooltip(
                        message: 'Переместить трек',
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: SizedBox.square(
                            dimension: 48,
                            child: Icon(
                              Icons.drag_handle_rounded,
                              color: muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      }

      return onReorder == null
          ? SliverList.builder(itemCount: rows.length, itemBuilder: buildRow)
          : SliverReorderableList(
              itemCount: rows.length,
              itemBuilder: buildRow,
              onReorderItem: onReorder,
              proxyDecorator: (child, _, animation) => Material(
                color: surface,
                borderRadius: BorderRadius.circular(8),
                child: child,
              ),
            );
    },
  );
}

Future<String?> askName(
  BuildContext context,
  String title, {
  String initial = '',
}) async {
  final field = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: field,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Название'),
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            if (field.text.trim().isNotEmpty) {
              Navigator.pop(context, field.text.trim());
            }
          },
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
  // The route can still animate out while its field is mounted.
  return value;
}

Future<void> choosePlaylist(
  BuildContext context,
  AppController app,
  List<String> ids,
) async {
  final selected = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Добавить в плейлист'),
      children: [
        ...app.library.playlists
            .where((playlist) => playlist.sourceHash == null)
            .map(
              (playlist) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, playlist.id),
                child: Text(playlist.name),
              ),
            ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, '__new__'),
          child: const Text(
            '+ Новый плейлист',
            style: TextStyle(color: accent),
          ),
        ),
      ],
    ),
  );
  if (selected == null) return;
  var id = selected;
  if (selected == '__new__' && context.mounted) {
    final name = await askName(context, 'Новый плейлист');
    if (name == null) return;
    id = (await app.library.createPlaylist(name)).id;
  }
  await app.library.addToPlaylist(id, ids);
}
