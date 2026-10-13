part of 'pages.dart';

class _AlbumPage extends StatelessWidget {
  const _AlbumPage(this.app, this.album);
  final AppController app;
  final Album album;
  @override
  Widget build(BuildContext context) => _PageBody(
    children: [
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (_, c) {
          final wide = c.maxWidth > 650;
          final information = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'АЛЬБОМ',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: muted,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                album.title,
                style: TextStyle(
                  fontSize: wide ? 42 : 28,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.2,
                ),
              ),
              const SizedBox(height: 12),
              ArtistLink(
                artist: album.artist,
                onOpen: () => app.openArtist(album.artist),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${album.year != null ? '${album.year} · ' : ''}${app.library.trackCountLabel(album.tracks)}${album.offline ? ' · Доступен офлайн' : ''}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              for (final collection in app.albumCollections) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  key: ValueKey('album-collection-${collection.id}'),
                  onPressed: () => app.openPlaylist(collection),
                  icon: const Icon(Icons.library_music_outlined, size: 18),
                  label: Text(
                    'В коллекцию «${collection.name}»',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          );
          final art = AlbumArtwork(
            app: app,
            album: album,
            size: wide ? 220 : 160,
            radius: 12,
          );
          return wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    art,
                    const SizedBox(width: 28),
                    Expanded(child: information),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(child: art),
                    const SizedBox(height: 24),
                    information,
                  ],
                );
        },
      ),
      const SizedBox(height: 28),
      Wrap(
        spacing: 14,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            key: const Key('play-album'),
            onPressed: () => app.playCollection(
              album.tracks,
              playlistId: app.albumPlaylistId,
            ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Слушать'),
          ),
          AlbumFavoriteButton(app: app, album: album, label: true),
          if (album.torrent && !album.offline)
            OutlinedButton.icon(
              onPressed: () => app.downloads.enqueue(album.tracks),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Скачать альбом'),
            ),
          IconButton(
            onPressed: () => choosePlaylist(
              context,
              app,
              album.tracks.map((t) => t.id).toList(),
            ),
            tooltip: 'В плейлист',
            icon: const Icon(Icons.playlist_add_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: 'Действия с альбомом',
            onSelected: (value) async {
              if (value == 'remove') {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Убрать альбом из медиатеки?'),
                    content: const Text(
                      'Исходные музыкальные файлы сохранятся.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Отмена'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Убрать'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await app.library.removeTracks(album.tracks.map((t) => t.id));
                  app.navigate(AppPage.library);
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'remove',
                child: Text('Убрать из медиатеки'),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: 28),
      const Divider(),
      const SizedBox(height: 8),
      _CollectionTracks(
        app: app,
        tracks: album.tracks,
        scope: 'album:${app.selectedAlbum}',
        playlistId: app.albumPlaylistId,
      ),
    ],
  );
}

class _TrackCollection extends StatelessWidget {
  const _TrackCollection({
    required this.app,
    required this.title,
    required this.eyebrow,
    required this.tracks,
    required this.icon,
    this.playlistId,
  });
  final AppController app;
  final String title, eyebrow;
  final List<Track> tracks;
  final IconData icon;
  final String? playlistId;
  @override
  Widget build(BuildContext context) => _PageBody(
    children: [
      const SizedBox(height: 20),
      Container(
        width: 90,
        height: 90,
        decoration: BoxDecoration(
          color: const Color(0xFF34422A),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, size: 40, color: accent),
      ),
      const SizedBox(height: 20),
      Text(
        eyebrow,
        style: const TextStyle(
          fontSize: 10,
          color: muted,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        title,
        key: const ValueKey('collection-title'),
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 8),
      Text(
        app.library.trackCountLabel(tracks),
        style: const TextStyle(color: muted),
      ),
      const SizedBox(height: 24),
      Wrap(
        spacing: 14,
        runSpacing: 12,
        children: [
          FilledButton.icon(
            onPressed: tracks.isEmpty
                ? null
                : () => app.playCollection(tracks, playlistId: playlistId),
            key: const ValueKey('play-collection'),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Слушать'),
          ),
          if (playlistId != null &&
              tracks.any((t) => t.source == TrackSource.torrent))
            OutlinedButton.icon(
              onPressed:
                  tracks.any(
                    (t) => t.source == TrackSource.torrent && !t.offline,
                  )
                  ? () => app.downloads.enqueue(tracks)
                  : null,
              icon: const Icon(Icons.download_rounded),
              label: const Text('Скачать коллекцию'),
            ),
          if (playlistId != null)
            PlaylistFavoriteButton(
              app: app,
              playlistId: playlistId!,
              label: true,
            ),
          if (playlistId != null)
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'rename') {
                  final name = await askName(
                    context,
                    'Название плейлиста',
                    initial: title,
                  );
                  if (name != null) {
                    await app.library.renamePlaylist(playlistId!, name);
                  }
                }
                if (value == 'delete') {
                  await app.library.deletePlaylist(playlistId!);
                  app.navigate(AppPage.library);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Переименовать')),
                PopupMenuItem(value: 'delete', child: Text('Удалить плейлист')),
              ],
            ),
        ],
      ),
      const SizedBox(height: 24),
      const Divider(),
      if (tracks.isEmpty)
        EmptyState(
          icon: icon,
          title: 'Добавь первые треки',
          description: 'Нажми на сердечко или добавь музыку через меню трека.',
        )
      else
        _CollectionTracks(
          app: app,
          tracks: tracks,
          scope: 'playlist:$playlistId',
          playlistId: playlistId,
          groupByAlbum: app.playlist?.sourceHash != null,
        ),
    ],
  );
}

class _CollectionTracks extends SliverContent {
  const _CollectionTracks({
    required this.app,
    required this.tracks,
    required this.scope,
    this.playlistId,
    this.groupByAlbum = false,
  });
  final AppController app;
  final List<Track> tracks;
  final String scope;
  final String? playlistId;
  final bool groupByAlbum;

  @override
  Widget build(BuildContext context) =>
      _CollectionTracksBody(key: ValueKey(scope), section: this);
}

class _CollectionTracksBody extends StatefulWidget {
  const _CollectionTracksBody({super.key, required this.section});
  final _CollectionTracks section;
  @override
  State<_CollectionTracksBody> createState() => _CollectionTracksBodyState();
}

class _CollectionTracksBodyState extends State<_CollectionTracksBody> {
  final _search = TextEditingController();
  late bool _albums = widget.section.groupByAlbum;
  bool _restored = false;

  String get _storageId => 'collection-view:${widget.section.scope}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    final saved = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _storageId);
    if (saved is ({String query, bool albums})) {
      _search.text = saved.query;
      _albums = saved.albums;
    }
  }

  void _saveView() {
    PageStorage.maybeOf(context)?.writeState(context, (
      query: _search.text,
      albums: _albums,
    ), identifier: _storageId);
  }

  void _clear() {
    _search.clear();
    _saveView();
    setState(() {});
  }

  void _moveTrack(int from, int to) {
    final section = widget.section;
    final playlist = section.app.library.playlists
        .where((playlist) => playlist.id == section.playlistId)
        .firstOrNull;
    if (playlist == null) return;
    final rows = section.app.library.matchedTracks(
      filterCollectionTracks(section.tracks, _search.text),
    );
    if (from < 0 ||
        to < 0 ||
        from >= rows.length ||
        to >= rows.length ||
        from == to) {
      return;
    }
    unawaited(
      section.app.library.movePlaylistTrackGroup(
        playlist.id,
        rows[from].group.ids,
        rows[to].group.ids,
        after: to > from,
      ),
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final tracks = section.tracks;
    final reorderable =
        section.playlistId != null && section.scope.startsWith('playlist:');
    final filtered = filterCollectionTracks(tracks, _search.text);
    final searching = _search.text.trim().isNotEmpty;
    final groups = section.groupByAlbum ? groupAlbums(tracks) : const <Album>[];
    final showAlbums = _albums && !searching && groups.length > 1;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('collection-search'),
                  controller: _search,
                  onChanged: (_) {
                    _saveView();
                    setState(() {});
                  },
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText: section.groupByAlbum
                        ? 'Поиск в коллекции'
                        : section.scope.startsWith('album:') ||
                              section.playlistId == null
                        ? 'Поиск в альбоме'
                        : 'Поиск в плейлисте',
                    suffixIcon: searching
                        ? IconButton(
                            key: const ValueKey('collection-search-clear'),
                            tooltip: 'Очистить поиск',
                            onPressed: _clear,
                            icon: const Icon(Icons.close_rounded),
                          )
                        : null,
                  ),
                ),
                if (groups.length > 1) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        key: const ValueKey('collection-albums-view'),
                        avatar: const Icon(Icons.album_outlined, size: 18),
                        label: Text('Альбомы · ${groups.length}'),
                        selected: showAlbums,
                        onSelected: searching
                            ? null
                            : (_) => setState(() {
                                _albums = true;
                                _saveView();
                              }),
                      ),
                      ChoiceChip(
                        key: const ValueKey('collection-tracks-view'),
                        avatar: const Icon(Icons.queue_music_rounded, size: 18),
                        label: const Text('Все треки'),
                        selected: !showAlbums,
                        onSelected: (_) => setState(() {
                          _albums = false;
                          _saveView();
                        }),
                      ),
                    ],
                  ),
                ],
                if (searching) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Найдено: ${section.app.library.matchedTracks(filtered).length} из ${section.app.library.matchedTracks(tracks).length}',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (showAlbums)
          _AlbumGrid(section.app, groups, playlistId: section.playlistId)
        else if (filtered.isEmpty)
          SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.search_off_rounded,
              title: 'Ничего не найдено',
              description:
                  'Попробуй другое название трека, альбома или исполнителя.',
              action: TextButton(
                onPressed: _clear,
                child: const Text('Сбросить поиск'),
              ),
            ),
          )
        else
          TrackList(
            app: section.app,
            tracks: filtered,
            queueTracks: tracks,
            playlistId: section.playlistId,
            onReorder: reorderable ? _moveTrack : null,
          ),
      ],
    );
  }
}
