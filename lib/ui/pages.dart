import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../data/download_repository.dart';
import '../domain/models.dart';
import '../domain/music_metadata.dart';
import '../domain/collection_filter.dart';
import '../data/rutracker_service.dart';
import 'catalog_widgets.dart';
import 'jackett_setup.dart';
import '../logic/app_controller.dart';
import 'components.dart';
import 'dialogs.dart';
import 'theme.dart';

class ContentPage extends StatelessWidget {
  const ContentPage({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => switch (app.page) {
    AppPage.home => _HomePage(app),
    AppPage.library => _LibraryPage(app),
    AppPage.search => _SearchPage(app),
    AppPage.liked => _LikedPage(app),
    AppPage.downloads => _DownloadsPage(app),
    AppPage.settings => SettingsPage(key: const ValueKey('settings'), app: app),
    AppPage.album =>
      app.album == null
          ? const EmptyState(
              icon: Icons.album_outlined,
              title: 'Альбом удалён',
              description: 'Открой другой альбом в медиатеке.',
            )
          : _AlbumPage(app, app.album!),
    AppPage.playlist => _TrackCollection(
      app: app,
      title: app.playlist?.name ?? 'Плейлист',
      eyebrow: app.playlist?.sourceHash != null ? 'КОЛЛЕКЦИЯ' : 'ПЛЕЙЛИСТ',
      tracks: app.playlistTracks,
      icon: Icons.queue_music_rounded,
      playlistId: app.playlist?.id,
    ),
    AppPage.artist => _ArtistPage(app),
  };
}

class _PageBody extends StatelessWidget {
  const _PageBody({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, c) => CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            c.maxWidth > 700 ? 32 : 18,
            12,
            c.maxWidth > 700 ? 32 : 18,
            36,
          ),
          sliver: SliverMainAxisGroup(
            slivers: children
                .map(
                  (child) => child is SliverContent
                      ? child
                      : SliverToBoxAdapter(child: child),
                )
                .toList(),
          ),
        ),
      ],
    ),
  );
}

Widget albumGrid(AppController app, List<Album> albums, {int? limit}) =>
    _AlbumGrid(app, limit == null ? albums : albums.take(limit).toList());

class _AlbumGrid extends SliverContent {
  const _AlbumGrid(this.app, this.items, {this.playlistId});
  final AppController app;
  final List<Album> items;
  final String? playlistId;
  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (_, c) => SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: (c.crossAxisExtent / 190).floor().clamp(2, 8),
        childAspectRatio: .76,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => AlbumCard(
        app: app,
        album: items[i],
        onOpen: () => app.openAlbum(items[i], playlistId: playlistId),
        onPlay: () =>
            app.playCollection(items[i].tracks, playlistId: playlistId),
        onArtist: () => app.openArtist(items[i].artist),
      ),
    ),
  );
}

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
      TextField(
        key: const Key('catalog-home-search'),
        onChanged: app.setQuery,
        onSubmitted: (_) {
          app.navigate(AppPage.search);
          app.searchSources();
        },
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded),
          hintText: 'Исполнитель или альбом',
          suffixIcon: IconButton(
            icon: const Icon(Icons.arrow_forward_rounded),
            tooltip: 'Найти музыку',
            onPressed: () {
              app.navigate(AppPage.search);
              app.searchSources();
            },
          ),
        ),
      ),
      const SizedBox(height: 14),
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
      if (app.usesIndexer)
        ...sourceContent(context, app)
      else
        ...catalogContent(context, app, home: true),
      if (app.recentAlbums.isNotEmpty) ...[
        const SectionTitle('Недавно слушал'),
        albumGrid(app, app.recentAlbums, limit: 6),
      ],
      SectionTitle(
        'Твоя медиатека',
        subtitle:
            '${app.library.tracks.length} треков · ${app.albums.length} альбомов',
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
            'Добавь альбом из каталога или выбери папку с локальной музыкой.',
            style: TextStyle(color: muted),
          ),
        ),
      if (app.library.playlists.isNotEmpty) ...[
        const SectionTitle('Плейлисты'),
        _PlaylistGrid(app),
      ],
    ],
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
  Widget build(BuildContext context) => _PageBody(
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
      if (app.albums.isEmpty)
        const EmptyState(
          icon: Icons.album_outlined,
          title: 'Здесь пока тихо',
          description: 'Добавь альбом или выбери другой фильтр.',
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
  );
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
    itemCount: (playlists ?? app.library.playlists).length,
    itemBuilder: (_, i) {
      final list = (playlists ?? app.library.playlists)[i];
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
                        '${list.sourceHash == null ? 'Плейлист' : 'Коллекция'} · ${list.trackIds.length} треков',
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
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
  Widget build(BuildContext context) => _PageBody(
    children: [
      const SectionTitle(
        'Любимое',
        subtitle:
            'Треки, плейлисты и коллекции, к которым хочется возвращаться',
      ),
      if (app.library.favoritePlaylists.isNotEmpty) ...[
        const SectionTitle('Плейлисты и коллекции'),
        _PlaylistGrid(app, playlists: app.library.favoritePlaylists),
      ],
      SectionTitle(
        'Любимые треки',
        subtitle: '${app.likedTracks.length} треков',
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
          title: app.library.favoritePlaylists.isEmpty
              ? 'Сохрани музыку в любимое'
              : 'Любимых треков пока нет',
          description: app.library.favoritePlaylists.isEmpty
              ? 'Сердечко у трека, плейлиста или коллекции добавит их сюда.'
              : 'Нажми сердечко у трека, чтобы сохранить его здесь.',
        ),
    ],
  );
}

class _ArtistPage extends StatelessWidget {
  const _ArtistPage(this.app);
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final profile = app.artistProfile;
    final name = profile?.name ?? app.selectedArtist ?? 'Исполнитель';
    final tracks = app.artistTracks;
    final albums = app.artistAlbums;
    return _PageBody(
      children: [
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(26),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF365342), Color(0xFF18251D)],
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: LayoutBuilder(
            builder: (_, constraints) {
              final wide = constraints.maxWidth > 520;
              final information = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ИСПОЛНИТЕЛЬ',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.7,
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    name,
                    key: const ValueKey('artist-title'),
                    style: TextStyle(
                      fontSize: wide ? 44 : 28,
                      height: 1.15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${tracks.length} треков · ${albums.length} альбомов в медиатеке',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  if (profile != null) ...[
                    const SizedBox(height: 7),
                    Text(
                      [
                        if (profile.type.isNotEmpty) _artistType(profile.type),
                        if (profile.country.isNotEmpty) profile.country,
                        if (profile.disambiguation.isNotEmpty)
                          profile.disambiguation,
                      ].join(' · '),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              );
              final avatar = Container(
                width: wide ? 130 : 82,
                height: wide ? 130 : 82,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: .08),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .12),
                  ),
                ),
                child: Icon(
                  profile?.type == 'Group'
                      ? Icons.groups_rounded
                      : Icons.person_rounded,
                  size: wide ? 65 : 42,
                  color: accent,
                ),
              );
              return wide
                  ? Row(
                      children: [
                        avatar,
                        const SizedBox(width: 26),
                        Expanded(child: information),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        avatar,
                        const SizedBox(height: 20),
                        information,
                      ],
                    );
            },
          ),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              key: const ValueKey('play-artist'),
              onPressed: tracks.isEmpty
                  ? null
                  : () => app.playCollection(tracks),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Слушать'),
            ),
            OutlinedButton.icon(
              onPressed: () {
                app.setTrackSearchMode(false);
                app.setQuery(name);
                app.navigate(AppPage.search);
                unawaited(app.searchSources());
              },
              icon: const Icon(Icons.search_rounded, size: 18),
              label: const Text('Найти в источниках'),
            ),
          ],
        ),
        if (tracks.isNotEmpty) ...[
          const SectionTitle('Треки в твоей медиатеке'),
          TrackList(app: app, tracks: tracks),
        ],
        if (albums.isNotEmpty) ...[
          const SectionTitle('Твои альбомы'),
          albumGrid(app, albums),
        ],
        if (app.artistLoading) ...[
          const SectionTitle('Узнаём исполнителя'),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (app.artistError != null)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text(
              app.artistError!,
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ),
        if (profile != null && profile.albums.isNotEmpty) ...[
          const SectionTitle(
            'Дискография',
            subtitle:
                'MusicBrainz · выбери альбом, чтобы найти его в источниках',
          ),
          _DiscographyGrid(app, profile.albums),
        ],
        if (profile != null && profile.recordings.isNotEmpty) ...[
          const SectionTitle(
            'Треки из каталога',
            subtitle: 'Выбери трек для поиска доступных версий',
          ),
          RecordingRows(app: app, recordings: profile.recordings),
        ],
        if (profile != null) ...[
          SectionTitle(
            'Об исполнителе',
            subtitle: 'Метаданные: MusicBrainz · обложки: Cover Art Archive',
          ),
          if (profile.aliases.isNotEmpty)
            Text(
              'Также известен как: ${profile.aliases.take(8).join(', ')}',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
        ] else if (!app.artistLoading && tracks.isEmpty)
          const EmptyState(
            icon: Icons.person_search_rounded,
            title: 'Пока нет треков этого исполнителя',
            description:
                'Найди его альбом в подключённых источниках или добавь локальные файлы.',
          ),
      ],
    );
  }
}

String _artistType(String type) => switch (type) {
  'Group' => 'Группа',
  'Person' => 'Исполнитель',
  'Orchestra' => 'Оркестр',
  'Choir' => 'Хор',
  _ => type,
};

class _DiscographyGrid extends SliverContent {
  const _DiscographyGrid(this.app, this.groups);
  final AppController app;
  final List<MusicReleaseGroup> groups;

  @override
  Widget build(BuildContext context) => SliverGrid.builder(
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 220,
      childAspectRatio: .75,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
    ),
    itemCount: groups.length,
    itemBuilder: (_, index) {
      final group = groups[index];
      return InkWell(
        key: ValueKey('discography-${group.id}'),
        onTap: () => app.searchAlbumMetadata(group),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (_, constraints) => AsyncCoverArt(
                    requestKey:
                        '${app.metadata.cache.generation}:release-group-${group.id}',
                    load: () => app.loadReleaseGroupArtwork(group),
                    seed: group.title,
                    size: constraints.maxWidth,
                    radius: 10,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                group.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (group.year.isNotEmpty) group.year,
                  if (group.type.isNotEmpty) group.type,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: muted),
              ),
            ],
          ),
        ),
      );
    },
  );
}

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
                '${album.year != null ? '${album.year} · ' : ''}${album.tracks.length} треков${album.offline ? ' · Доступен офлайн' : ''}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
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
      Text('${tracks.length} треков', style: const TextStyle(color: muted)),
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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final tracks = section.tracks;
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
                        : section.playlistId == null
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
                    'Найдено: ${filtered.length} из ${tracks.length}',
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
          ),
      ],
    );
  }
}

class _SearchPage extends StatefulWidget {
  const _SearchPage(this.app);
  final AppController app;
  @override
  State<_SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<_SearchPage> {
  late final TextEditingController _query;
  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController(text: app.query);
  }

  @override
  void didUpdateWidget(covariant _SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_query.text != app.query) {
      _query.value = TextEditingValue(
        text: app.query,
        selection: TextSelection.collapsed(offset: app.query.length),
      );
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PageBody(
    children: [
      SectionTitle(
        'Найди свой звук',
        subtitle: app.usesIndexer
            ? 'Твоя медиатека и музыкальные трекеры Jackett'
            : 'Твоя медиатека и музыкальный каталог RuTracker',
      ),
      TextFormField(
        key: ValueKey('music-search'),
        controller: _query,
        autofocus: app.catalogTrail.isEmpty,
        onChanged: app.setQuery,
        onFieldSubmitted: (_) => app.searchSources(),
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search_rounded),
          hintText: 'Исполнитель, альбом или трек',
        ),
      ),
      const SizedBox(height: 16),
      SearchOptionsPanel(app: app),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: app.searching ? null : app.searchSources,
            icon: app.searching
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.search_rounded, size: 18),
            label: Text(
              app.trackSearchMode
                  ? 'Искать треки'
                  : app.usesIndexer
                  ? 'Искать через Jackett'
                  : 'Искать на RuTracker',
            ),
          ),
          if (!app.usesIndexer && app.catalog.username == null)
            TextButton(
              onPressed: () => app.connectCatalog(),
              child: const Text('Войти в RuTracker'),
            ),
        ],
      ),
      if (app.trackSearchMode && app.selectedRecording != null) ...[
        SectionTitle(
          'Версии «${app.selectedRecording!.title}»',
          subtitle: app.selectedRecording!.artist,
          action: app.versionLoading
              ? TextButton(
                  onPressed: app.cancelVersionSearch,
                  child: const Text('Отменить'),
                )
              : null,
        ),
        if (app.versionLoading) const LinearProgressIndicator(minHeight: 2),
        if (app.versionStatus != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.versionStatus!,
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ),
        if (app.versionError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.versionError!,
              style: const TextStyle(color: Color(0xFFFF9292), fontSize: 12),
            ),
          ),
        if (app.trackVariants.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Выбери формат и раздачу. Метки Clean и «без цензуры» взяты из описания версии.',
              style: TextStyle(color: muted, fontSize: 11),
            ),
          ),
          TrackVariantRows(app: app),
        ],
      ],
      if (app.query.trim().isEmpty && !app.trackSearchMode)
        ...(app.usesIndexer
            ? sourceContent(context, app)
            : catalogContent(context, app))
      else if (app.trackSearchMode) ...[
        if (app.metadataError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.metadataError!,
              style: const TextStyle(color: Color(0xFFFF9292), fontSize: 12),
            ),
          ),
        SectionTitle(
          'Треки в MusicBrainz',
          subtitle: app.searching
              ? 'Ищем…'
              : app.recordingResults.isNotEmpty
              ? 'Найдено: ${app.recordingResults.length}'
              : 'Введи название трека и исполнителя',
        ),
        if (app.recordingResults.isNotEmpty)
          RecordingRows(app: app, recordings: app.recordingResults)
        else if (!app.searching &&
            app.searchCompleted &&
            app.metadataError == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Треки не найдены. Попробуй добавить имя исполнителя или поискать альбом в источниках.',
              style: TextStyle(color: muted),
            ),
          ),
      ] else ...[
        if (app.indexerNotice != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.indexerNotice!,
              style: const TextStyle(color: muted),
            ),
          ),
        if (!app.usesIndexer && app.catalogError != null)
          CatalogNotice(app: app),
      ],
      if (app.query.trim().isNotEmpty && !app.trackSearchMode) ...[
        if (app.searchCorrectionCandidate != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'По исходному запросу ничего не найдено. Проверяем «${app.searchCorrectionCandidate}»…',
              style: const TextStyle(color: muted),
            ),
          )
        else if (app.correctedSearchQuery != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.releases.isNotEmpty
                  ? 'По запросу «${app.query.trim()}» ничего не найдено. Показаны результаты для «${app.correctedSearchQuery}».'
                  : 'Также проверили «${app.correctedSearchQuery}»: раздачи не найдены.',
              style: const TextStyle(color: muted),
            ),
          ),
        if (app.searchCorrectionSuggestions.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Есть несколько похожих названий. Уточни запрос:',
              style: TextStyle(color: muted),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final suggestion in app.searchCorrectionSuggestions)
                ActionChip(
                  label: Text(suggestion),
                  onPressed: () {
                    app.setQuery(suggestion);
                    app.searchSources();
                  },
                ),
            ],
          ),
        ],
        SectionTitle(
          app.usesIndexer ? 'В трекерах Jackett' : 'На RuTracker',
          subtitle: app.searching
              ? 'Ищем…'
              : app.searchCompleted
              ? 'Найдено: ${app.releases.length}'
              : 'Начни вводить запрос',
        ),
        if (app.releases.isNotEmpty)
          ReleaseRows(app: app, releases: app.releases)
        else if (!app.searching && app.catalogError == null)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.searchCompleted
                  ? 'В подключённых источниках ничего не найдено. Проверь название или подключи другой музыкальный трекер.'
                  : 'Нажми «Искать», чтобы найти альбомы в каталоге.',
              style: const TextStyle(color: muted),
            ),
          ),
      ],
      if (app.query.trim().isNotEmpty) ...[
        SectionTitle(
          'В твоей медиатеке',
          subtitle: 'Найдено: ${app.searchTracks.length}',
        ),
        if (app.searchTracks.isNotEmpty)
          TrackList(app: app, tracks: app.searchTracks)
        else
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text(
              'В локальной медиатеке пока ничего не найдено.',
              style: TextStyle(color: muted),
            ),
          ),
      ],
    ],
  );
}

class _DownloadsPage extends StatelessWidget {
  const _DownloadsPage(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) => _PageBody(
    children: [
      SectionTitle(
        'С тобой без интернета',
        subtitle:
            '${app.offlineTracks.length} скачанных треков · ${formatBytes(app.offlineTracks.fold<int>(0, (a, t) => a + t.bytes))}',
      ),
      if (app.downloads.jobs.isNotEmpty) ...[
        const SectionTitle('Загрузки'),
        LazyRows(
          count: app.downloads.jobs.length,
          builder: (_, i) {
            final job = app.downloads.jobs[i];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  CoverArt(
                    seed: job.track.album,
                    path: job.track.artPath,
                    size: 46,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          job.track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 5),
                        if (job.state == DownloadState.downloading)
                          LinearProgressIndicator(
                            value: job.progress,
                            minHeight: 3,
                          ),
                        const SizedBox(height: 5),
                        Text(
                          job.error ??
                              switch (job.state) {
                                DownloadState.queued => 'В очереди',
                                DownloadState.downloading =>
                                  '${formatBytes(job.received)} / ${formatBytes(job.total)}',
                                DownloadState.paused =>
                                  'Приостановлено · ${formatBytes(job.received)}',
                                DownloadState.complete => 'Готово для офлайн',
                                DownloadState.failed => 'Ошибка загрузки',
                              },
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: job.state == DownloadState.failed
                                ? const Color(0xFFFF9292)
                                : muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (job.state == DownloadState.downloading ||
                      job.state == DownloadState.queued)
                    IconButton(
                      onPressed: () => app.downloads.pause(job.track.id),
                      tooltip: 'Приостановить',
                      icon: const Icon(Icons.pause_rounded),
                    )
                  else if (job.state == DownloadState.paused ||
                      job.state == DownloadState.failed)
                    IconButton(
                      onPressed: () => app.downloads.retry(job.track.id),
                      tooltip: 'Продолжить',
                      icon: const Icon(Icons.play_arrow_rounded, color: accent),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.check_circle_rounded, color: accent),
                    ),
                ],
              ),
            );
          },
        ),
      ],
      if (app.offlineTracks.isNotEmpty) ...[
        const SectionTitle('Скачанные треки'),
        TrackList(app: app, tracks: app.offlineTracks),
      ] else
        const EmptyState(
          icon: Icons.offline_bolt_rounded,
          title: 'Сохрани музыку для дороги',
          description:
              'Открой торрент-альбом и нажми «Скачать альбом». Завершённые загрузки играют без сети.',
        ),
    ],
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app});
  final AppController app;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.app.refreshMetadataCache());
    if (Platform.isWindows) {
      unawaited(widget.app.refreshTorrentNetworks());
    }
  }

  late final server = TextEditingController(
    text: widget.app.library.settings['serverUrl'] as String? ?? '',
  );
  late final source = TextEditingController(
    text: widget.app.library.settings['indexerUrl'] as String? ?? '',
  );
  late final apiKey = TextEditingController(
    text: widget.app.library.settings['indexerKey'] as String? ?? '',
  );
  late final limit = TextEditingController(
    text: '${widget.app.library.settings['cacheLimitMb'] ?? 4096}',
  );
  @override
  void dispose() {
    server.dispose();
    source.dispose();
    apiKey.dispose();
    limit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PageBody(
    children: [
      const SectionTitle('Настройки', subtitle: 'Сделай Mumpa своей'),
      if (widget.app.windowsPlayer != null)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('Плеер в Windows'),
              const Text(
                'Крестик скрывает Mumpa в трее, и музыка продолжает играть. '
                'Нажми значок в трее, чтобы вернуть окно. '
                'Кнопки на колонках и под превью на панели задач управляют плеером.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('quit-mumpa'),
                onPressed: widget.app.windowsPlayer!.available
                    ? () async {
                        try {
                          await widget.app.windowsPlayer!.requestQuit();
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Не удалось завершить Mumpa. Попробуй ещё раз.',
                                ),
                              ),
                            );
                          }
                        }
                      }
                    : null,
                icon: const Icon(Icons.exit_to_app_rounded, size: 18),
                label: const Text('Завершить Mumpa'),
              ),
              if (!widget.app.windowsPlayer!.available)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Управление через Windows сейчас недоступно.',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('Jackett · основной каталог'),
            if (Platform.isWindows)
              FilledButton.icon(
                onPressed: widget.app.busy == null
                    ? () async {
                        await setupJackett(context, widget.app, embedded: true);
                        source.text =
                            widget.app.library.settings['indexerUrl']
                                as String? ??
                            '';
                        apiKey.text =
                            widget.app.library.settings['indexerKey']
                                as String? ??
                            '';
                      }
                    : null,
                icon: const Icon(Icons.settings_rounded, size: 18),
                label: const Text('Запустить Jackett и настроить RuTracker'),
              ),
            if (Platform.isWindows) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: widget.app.busy == null
                    ? widget.app.prepareCloudflare
                    : null,
                icon: const Icon(Icons.verified_user_outlined, size: 18),
                label: Text(
                  widget.app.cloudflareEnabled
                      ? 'FlareSolverr подключён · проверить'
                      : 'Настроить FlareSolverr для Cloudflare',
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Если Jackett сообщает Challenge detected, подключи проверку Cloudflare и повтори сохранение трекера. Первый запуск может занять около минуты.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            const Text(
              'Добавь RuTracker.org в Jackett и сохрани аккаунт. Можно использовать встроенный Jackett на Windows или подключить свой сервер Jackett/Prowlarr по адресу и API key.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: source,
              decoration: const InputDecoration(
                labelText: 'Адрес Jackett или URL Torznab API',
                hintText:
                    'http://localhost:9117/api/v2.0/indexers/all/results/torznab/api',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: apiKey,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'API key'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => widget.app.saveIndexer(source.text, apiKey.text),
              child: const Text('Сохранить и проверить подключение'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Использовать Jackett для поиска',
                style: TextStyle(fontSize: 13),
              ),
              value: widget.app.usesIndexer,
              onChanged: (value) =>
                  widget.app.setSearchProvider(value ? 'torznab' : 'rutracker'),
            ),
          ],
        ),
      ),
      const SectionTitle('Прямой доступ к RuTracker'),
      Text(
        widget.app.catalog.username == null
            ? 'Войди в свой аккаунт для поиска исполнителей и альбомов.'
            : 'Выполнен вход: ${widget.app.catalog.username}',
        style: const TextStyle(color: muted),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: () => widget.app.connectCatalog(),
            icon: const Icon(Icons.login_rounded, size: 18),
            label: const Text('Войти в RuTracker'),
          ),
          TextButton(
            onPressed: () => widget.app.connectCatalog(login: false),
            child: const Text('Открыть сайт'),
          ),
          if (widget.app.catalog.username != null)
            TextButton(
              onPressed: () async {
                await widget.app.catalog.logout();
                await widget.app.refreshCatalog();
              },
              child: const Text('Выйти'),
            ),
        ],
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: widget.app.catalog.base.toString(),
        decoration: const InputDecoration(labelText: 'Зеркало RuTracker'),
        items: RuTrackerService.mirrors
            .map(
              (url) => DropdownMenuItem(
                value: url,
                child: Text(Uri.parse(url).host),
              ),
            )
            .toList(),
        onChanged: (url) async {
          if (url == null) return;
          await widget.app.catalog.setMirror(url);
          await widget.app.library.setSetting('rutrackerMirror', url);
          await widget.app.refreshCatalog();
        },
      ),
      const SizedBox(height: 20),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('Торрент-движок'),
            if (Platform.isWindows) ...[
              DropdownButtonFormField<String>(
                key: ValueKey(widget.app.torrentInterface),
                initialValue: widget.app.torrentInterface,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Интерфейс встроенного торрент-движка',
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('Системный маршрут (по умолчанию)'),
                  ),
                  for (final name in {
                    ...widget.app.torrentNetworks.map((n) => n.name),
                    if (widget.app.torrentInterface.isNotEmpty)
                      widget.app.torrentInterface,
                  })
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: widget.app.busy == null
                    ? (name) {
                        if (name != null) {
                          unawaited(widget.app.saveTorrentInterface(name));
                        }
                      }
                    : null,
              ),
              const SizedBox(height: 8),
              const Text(
                'Выбор Wi-Fi или Ethernet может отправлять торрент-трафик напрямую: '
                'трекеры и пиры увидят IP провайдера. Системный маршрут учитывает VPN. '
                'Настройка применяется после перезапуска Mumpa. '
                'Другой интерфейс не будет выбран автоматически.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              TextButton.icon(
                onPressed: widget.app.refreshTorrentNetworks,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Обновить список интерфейсов'),
              ),
              const SizedBox(height: 12),
            ],
            const Text(
              'Встроенный движок работает автоматически. Можно подключить свой TorrServer — например, на домашнем сервере.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: server,
              decoration: const InputDecoration(
                labelText: 'Внешний TorrServer (необязательно)',
                hintText: 'http://192.168.1.10:8090',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton(
                  onPressed: () async {
                    final url = server.text.trim();
                    final uri = Uri.tryParse(url);
                    if (url.isNotEmpty &&
                        (uri == null ||
                            !{'http', 'https'}.contains(uri.scheme) ||
                            uri.host.isEmpty)) {
                      widget.app.reportError(
                        'Укажите корректный HTTP/HTTPS URL.',
                      );
                      return;
                    }
                    await widget.app.library.setSetting('serverUrl', url);
                    await widget.app.checkEngine();
                  },
                  child: const Text('Сохранить и проверить'),
                ),
                TextButton(
                  onPressed: widget.app.checkEngine,
                  child: const Text('Проверить движок'),
                ),
              ],
            ),
            if (widget.app.engineVersion != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Подключён: ${widget.app.engineVersion}',
                  style: const TextStyle(color: accent, fontSize: 12),
                ),
              ),
            const SectionTitle('Офлайн и кеш'),
            const Text(
              'Временный торрент-буфер используется во время стриминга. Полные офлайн-копии сохраняются до удаления через меню трека.',
              style: TextStyle(color: muted),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Скачивать прослушиваемые треки',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              subtitle: const Text(
                'Автоматически сохранять торрент-треки для офлайн',
                style: TextStyle(fontSize: 11, color: muted),
              ),
              value: widget.app.library.settings['autoCache'] == true,
              onChanged: (v) => widget.app.library.setSetting('autoCache', v),
            ),
            TextField(
              controller: limit,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Лимит офлайн-загрузок, МБ',
                hintText: '4096',
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () async {
                final value = int.tryParse(limit.text);
                if (value != null && value >= 64) {
                  await widget.app.library.setSetting('cacheLimitMb', value);
                }
              },
              child: const Text('Сохранить лимит'),
            ),
            const SectionTitle('Обложки и музыкальные метаданные'),
            const Text(
              'MusicBrainz помогает сопоставлять исполнителей и альбомы. '
              'Cover Art Archive предоставляет обложки. Данные сохраняются на диске; '
              'при заполнении кеша удаляются самые старые записи.',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: ValueKey(
                'metadata-cache-${widget.app.library.settings['metadataCacheMb'] ?? 256}',
              ),
              initialValue:
                  widget.app.library.settings['metadataCacheMb'] as int? ?? 256,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Лимит кеша обложек и метаданных',
              ),
              items: [
                for (final mb in {
                  64,
                  128,
                  256,
                  512,
                  1024,
                  widget.app.library.settings['metadataCacheMb'] as int? ?? 256,
                }.toList()..sort())
                  DropdownMenuItem(value: mb, child: Text('$mb МБ')),
              ],
              onChanged: widget.app.cacheBusy
                  ? null
                  : (value) {
                      if (value != null) {
                        unawaited(widget.app.setMetadataCacheLimit(value));
                      }
                    },
            ),
            const SizedBox(height: 12),
            if (widget.app.cacheStats != null)
              Text(
                '${formatBytes(widget.app.cacheStats!.bytes)} из '
                '${formatBytes(widget.app.cacheStats!.maxBytes)} · '
                '${widget.app.cacheStats!.count} записей',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                TextButton.icon(
                  key: const ValueKey('clear-metadata-cache'),
                  onPressed: widget.app.cacheBusy
                      ? null
                      : widget.app.clearMetadataCache,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Очистить кеш'),
                ),
                TextButton(
                  onPressed: widget.app.cacheBusy
                      ? null
                      : widget.app.refreshMetadataCache,
                  child: const Text('Обновить размер'),
                ),
              ],
            ),
            const SectionTitle('Mumpa'),
            const Text(
              'Музыка из твоих файлов и источников.\nДемо Mumpa Sessions — оригинальные синтезированные фрагменты.\nFlutter · media_kit · TorrServer MatriX.145.2',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Mumpa',
                applicationVersion: '1.2.2',
                applicationLegalese:
                    'GPL-3.0 · TorrServer: github.com/YouROK/TorrServer, MatriX.145.2\nEngine source: commit bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9',
              ),
              child: const Text('Лицензии компонентов'),
            ),
            const SizedBox(height: 12),
            SelectableText(
              'Библиотека: ${widget.app.library.root.path}',
              style: const TextStyle(fontSize: 10, color: muted),
            ),
            if (Platform.isAndroid)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Импорт на Android сохраняет копии в приватной папке приложения.',
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}
