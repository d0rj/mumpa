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
  });
  final AppController app;
  final List<Track> tracks;
  final List<Track>? queueTracks;
  final String? playlistId;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      app.playback.trackState,
      app.library,
      app.downloads,
      app,
    ]),
    builder: (_, _) => SliverList.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = app.library.byId(tracks[i].id) ?? tracks[i];
        final active = app.playback.current?.id == t.id;
        final downloading = app.downloads.jobs
            .where(
              (j) => j.track.id == t.id && j.state == DownloadState.downloading,
            )
            .firstOrNull;
        return LayoutBuilder(
          builder: (context, c) => InkWell(
            key: ValueKey('track-row-${t.id}'),
            onTap: () {
              final queue = queueTracks ?? tracks;
              final index = queue.indexWhere((item) => item.id == t.id);
              if (index < 0) return;
              app.playCollection(queue, index: index, playlistId: playlistId);
            },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: active && app.playback.buffering
                        ? const Center(
                            child: SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
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
                  TrackArtwork(app: app, track: t, size: 42, radius: 5),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.title,
                          key: ValueKey('track-title-${t.id}'),
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
                      child: Text(
                        t.album,
                        key: ValueKey('track-album-${t.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: muted),
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
                  SizedBox(
                    key: ValueKey('track-status-${t.id}'),
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
                    onPressed: () => app.library.toggleLike(t.id),
                    tooltip: app.library.isTrackLiked(t.id)
                        ? 'Убрать из любимого'
                        : 'В любимое',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      app.library.isTrackLiked(t.id)
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      size: 19,
                      color: app.library.isTrackLiked(t.id) ? accent : muted,
                    ),
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
                    key: ValueKey('track-actions-${t.id}'),
                    tooltip: 'Действия с треком',
                    icon: const Icon(
                      Icons.more_horiz_rounded,
                      color: muted,
                      size: 20,
                    ),
                    onSelected: (action) async {
                      switch (action) {
                        case 'next':
                          app.playback.enqueue(t, next: true);
                        case 'queue':
                          app.playback.enqueue(t);
                        case 'download':
                          app.downloads.enqueue([t]);
                        case 'removeCache':
                          await app.downloads.removeOffline(t);
                        case 'artist':
                          app.openArtist(t.artist);
                        case 'removePlaylist':
                          await app.library.removeFromPlaylist(
                            playlistId!,
                            t.id,
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
                      if (playlistId != null)
                        const PopupMenuItem(
                          value: 'removePlaylist',
                          child: Text('Убрать из плейлиста'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
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
        ...app.library.playlists.map(
          (l) => SimpleDialogOption(
            onPressed: () => Navigator.pop(context, l.id),
            child: Text(l.name),
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
