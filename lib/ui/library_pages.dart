part of 'pages.dart';

class _HomePage extends StatelessWidget {
  const _HomePage(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) => _PageBody(
    children: [
      const SizedBox(height: 12),
      const BadgePill(
        icon: Icons.graphic_eq_rounded,
        label: 'МУЗЫКА В ТВОЁМ РИТМЕ',
      ),
      const SizedBox(height: 18),
      Text(
        'Что сегодня слушаем?',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          if (!app.usesIndexer)
            TextButton.icon(
              onPressed: () => app.connectCatalog(),
              icon: const Icon(Icons.login_rounded, size: 18),
              label: Text(
                app.catalog.username == null
                    ? 'Войти в RuTracker'
                    : 'RuTracker · ${app.catalog.username}',
              ),
            ),
          TextButton.icon(
            onPressed: () => showAddMusic(context, app),
            icon: const Icon(Icons.folder_open_rounded, size: 18),
            label: const Text('Моя музыка с диска'),
          ),
        ],
      ),
      SearchOptionsPanel(app: app),
      const SectionTitle(
        'Твой топ на устройстве',
        subtitle: 'Любимые по числу прослушиваний',
      ),
      _DeviceTopCard(app),
      if (app.library.frequentPlaylists.isNotEmpty) ...[
        const SectionTitle(
          'Часто слушаешь',
          subtitle: 'Плейлисты и коллекции по числу прослушиваний треков',
        ),
        HorizontalMusicShelf(
          key: const ValueKey('home-frequent-playlists'),
          height: 164,
          itemCount: app.library.frequentPlaylists.length,
          itemBuilder: (_, index) {
            final list = app.library.frequentPlaylists[index];
            return Material(
              color: const Color(0xFF202621),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: () => app.openPlaylist(list),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.queue_music_rounded, color: accent),
                      const Spacer(),
                      Text(
                        list.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Прослушиваний треков: ${app.library.playlistPlayCount(list.id)}',
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
      if (app.usesIndexer)
        ...sourceContent(context, app, home: true)
      else
        ...catalogContent(context, app, home: true),
      if (app.recentAlbums.isNotEmpty) ...[
        const SectionTitle('Недавно слушал'),
        albumGrid(app, app.recentAlbums, limit: 6),
      ],
      SectionTitle(
        'Твоя медиатека',
        subtitle:
            '${app.library.mediaTracks.length} треков · ${app.albums.length} альбомов',
        action: TextButton(
          onPressed: () => app.navigate(AppPage.library),
          child: const Text('Открыть всё'),
        ),
      ),
      if (app.albums.isNotEmpty)
        albumGrid(app, app.albums, limit: 6)
      else
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Text(
            'Включи трек из каталога или выбери папку с локальной музыкой.',
            style: TextStyle(color: muted),
          ),
        ),
      if (app.library.mediaPlaylists.isNotEmpty) ...[
        const SectionTitle('Плейлисты'),
        _PlaylistGrid(app, playlists: app.library.mediaPlaylists),
      ],
    ],
  );
}

class _DeviceTopCard extends StatelessWidget {
  const _DeviceTopCard(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF304535),
    borderRadius: BorderRadius.circular(14),
    child: ListTile(
      key: const ValueKey('device-top-50'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      leading: const Icon(Icons.bar_chart_rounded, size: 40, color: accent),
      title: Text(
        app.library.topTracksPlaylist.name,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        app.library.topTracksPlaylist.trackIds.isEmpty
            ? 'Начни слушать — топ соберётся автоматически'
            : '${app.library.topTracksPlaylist.trackIds.length} треков · обновляется автоматически',
        style: const TextStyle(color: muted, fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => app.openPlaylist(app.library.topTracksPlaylist),
    ),
  );
}

class _Tab extends StatelessWidget {
  const _Tab(this.text, this.selected, this.tap);
  final String text;
  final bool selected;
  final VoidCallback tap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ActionChip(
      onPressed: tap,
      label: Text(text),
      backgroundColor: selected ? Colors.white : const Color(0xFF222823),
      side: BorderSide.none,
      labelStyle: TextStyle(
        color: selected ? Colors.black : Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
  );
}

class _LibraryPage extends StatelessWidget {
  const _LibraryPage(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final searching = normalizeMusicName(app.localQuery('library')).isNotEmpty;
    return _PageBody(
      children: [
        SectionTitle(
          'Медиатека',
          subtitle: 'Всё, что хочется слушать',
          action: IconButton(
            onPressed: () => showAddMusic(context, app),
            tooltip: 'Добавить музыку',
            icon: const Icon(Icons.add_rounded),
          ),
        ),
        LocalSearchField(
          app: app,
          scope: 'library',
          hint: 'Поиск в медиатеке: исполнитель, альбом, трек',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Tab(
              'Все альбомы',
              app.filter == LibraryFilter.all,
              () => app.setFilter(LibraryFilter.all),
            ),
            _Tab(
              'Офлайн',
              app.filter == LibraryFilter.offline,
              () => app.setFilter(LibraryFilter.offline),
            ),
            _Tab(
              'Торренты',
              app.filter == LibraryFilter.torrents,
              () => app.setFilter(LibraryFilter.torrents),
            ),
            PopupMenuButton<LibrarySort>(
              initialValue: app.sort,
              onSelected: app.setSort,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: LibrarySort.added,
                  child: Text('Недавно добавленные'),
                ),
                PopupMenuItem(
                  value: LibrarySort.name,
                  child: Text('По названию'),
                ),
                PopupMenuItem(
                  value: LibrarySort.artist,
                  child: Text('По исполнителю'),
                ),
              ],
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.sort_rounded, size: 16, color: muted),
                    SizedBox(width: 6),
                    Text(
                      'Сортировка',
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (searching)
          ..._localResultSections(app, app.librarySearchResults)
        else ...[
          if (app.albums.isEmpty)
            const EmptyState(
              icon: Icons.album_outlined,
              title: 'Здесь пока тихо',
              description:
                  'Включи трек, добавь музыку или выбери другой фильтр.',
            )
          else
            albumGrid(app, app.albums),
          SectionTitle(
            'Плейлисты',
            action: TextButton.icon(
              onPressed: () async {
                final name = await askName(context, 'Новый плейлист');
                if (name != null) {
                  app.openPlaylist(await app.library.createPlaylist(name));
                }
              },
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Создать'),
            ),
          ),
          _PlaylistGrid(app),
        ],
      ],
    );
  }
}

List<Widget> _localResultSections(
  AppController app,
  LocalMusicResults results,
) {
  final count =
      results.artists.length +
      results.albums.length +
      results.playlists.length +
      results.tracks.length;
  if (count == 0) {
    return const [
      EmptyState(
        icon: Icons.search_off_rounded,
        title: 'Ничего не найдено в этом разделе',
        description: 'Попробуй другой запрос или очисти поиск.',
      ),
    ];
  }
  return [
    if (results.artists.isNotEmpty) ...[
      SectionTitle(
        'Исполнители',
        subtitle: '${results.artists.length} найдено',
      ),
      LazyRows(
        count: results.artists.length,
        builder: (_, index) {
          final artist = results.artists[index];
          return ListTile(
            key: ValueKey('local-artist-$artist'),
            leading: const CircleAvatar(
              backgroundColor: Color(0xFF27382B),
              child: Icon(Icons.person_rounded, color: accent),
            ),
            title: Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right_rounded, color: muted),
            onTap: () => app.openArtist(artist),
          );
        },
      ),
    ],
    if (results.albums.isNotEmpty) ...[
      SectionTitle('Альбомы', subtitle: '${results.albums.length} найдено'),
      albumGrid(app, results.albums),
    ],
    if (results.playlists.isNotEmpty) ...[
      SectionTitle(
        'Плейлисты и коллекции',
        subtitle: '${results.playlists.length} найдено',
      ),
      _PlaylistGrid(app, playlists: results.playlists),
    ],
    if (results.tracks.isNotEmpty) ...[
      SectionTitle(
        'Треки',
        subtitle: '${app.library.matchedTracks(results.tracks).length} найдено',
      ),
      TrackList(app: app, tracks: results.tracks),
    ],
  ];
}

class _PlaylistGrid extends SliverContent {
  const _PlaylistGrid(this.app, {this.playlists});
  final AppController app;
  final List<MusicPlaylist>? playlists;
  @override
  Widget build(BuildContext context) => SliverGrid.builder(
    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 350,
      mainAxisExtent: 88,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
    ),
    itemCount:
        (playlists ??
                [app.library.topTracksPlaylist, ...app.library.mediaPlaylists])
            .length,
    itemBuilder: (_, i) {
      final list =
          (playlists ??
          [app.library.topTracksPlaylist, ...app.library.mediaPlaylists])[i];
      return Material(
        color: const Color(0xFF202621),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => app.openPlaylist(list),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CoverArt(seed: list.name, size: 60),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        list.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        '${list.isSystem
                            ? 'На этом устройстве'
                            : list.sourceHash == null
                            ? 'Плейлист'
                            : 'Коллекция'} · ${list.trackIds.length} треков',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                if (!list.isSystem)
                  PlaylistFavoriteButton(app: app, playlistId: list.id),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _LikedPage extends StatelessWidget {
  const _LikedPage(this.app);
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final albums = app.library.favoriteAlbums;
    final searching = normalizeMusicName(app.localQuery('liked')).isNotEmpty;
    return _PageBody(
      children: [
        const SectionTitle(
          'Любимое',
          subtitle:
              'Треки, альбомы, плейлисты и коллекции, к которым хочется возвращаться',
        ),
        LocalSearchField(
          app: app,
          scope: 'liked',
          hint: 'Поиск в любимом: треки, альбомы, плейлисты',
        ),
        if (searching)
          ..._localResultSections(app, app.likedSearchResults)
        else ...[
          if (albums.isNotEmpty) ...[
            const SectionTitle('Любимые альбомы'),
            albumGrid(app, albums),
          ],
          if (app.library.favoritePlaylists.isNotEmpty) ...[
            const SectionTitle('Плейлисты и коллекции'),
            _PlaylistGrid(app, playlists: app.library.favoritePlaylists),
          ],
          SectionTitle(
            'Любимые треки',
            subtitle: app.library.trackCountLabel(app.likedTracks),
            action: app.likedTracks.isEmpty
                ? null
                : FilledButton.icon(
                    onPressed: () => app.playCollection(app.likedTracks),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Слушать'),
                  ),
          ),
          if (app.likedTracks.isNotEmpty)
            TrackList(app: app, tracks: app.likedTracks)
          else
            EmptyState(
              icon: Icons.favorite_border_rounded,
              title: app.library.favoritePlaylists.isEmpty && albums.isEmpty
                  ? 'Сохрани музыку в любимое'
                  : 'Любимых треков пока нет',
              description:
                  app.library.favoritePlaylists.isEmpty && albums.isEmpty
                  ? 'Сердечко у трека, альбома, плейлиста или коллекции добавит их сюда.'
                  : 'Нажми сердечко у трека, чтобы сохранить его здесь.',
            ),
        ],
      ],
    );
  }
}
