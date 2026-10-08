import 'dart:io';
import 'package:flutter/material.dart';
import '../data/download_repository.dart';
import '../domain/models.dart';
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
    AppPage.liked => _TrackCollection(
      app: app,
      title: 'Любимые треки',
      eyebrow: 'ТВОЯ КОЛЛЕКЦИЯ',
      tracks: app.likedTracks,
      icon: Icons.favorite_rounded,
    ),
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
      eyebrow: 'ПЛЕЙЛИСТ',
      tracks: app.playlistTracks,
      icon: Icons.queue_music_rounded,
      playlistId: app.playlist?.id,
    ),
    AppPage.artist => _TrackCollection(
      app: app,
      title: app.selectedArtist ?? '',
      eyebrow: 'ИСПОЛНИТЕЛЬ',
      tracks: app.library.tracks
          .where(
            (t) =>
                t.artist == app.selectedArtist ||
                t.albumArtist == app.selectedArtist,
          )
          .toList(),
      icon: Icons.person_rounded,
    ),
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
  const _AlbumGrid(this.app, this.items);
  final AppController app;
  final List<Album> items;
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
        album: items[i],
        onOpen: () => app.openAlbum(items[i]),
        onPlay: () => app.playback.playTracks(items[i].tracks),
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
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          _Tab('Всё', true, () {}),
          _Tab('Альбомы', false, () => app.navigate(AppPage.library)),
          _Tab('Офлайн', false, () {
            app.setFilter(LibraryFilter.offline);
            app.navigate(AppPage.library);
          }),
        ],
      ),
      const SizedBox(height: 22),
      LayoutBuilder(
        builder: (_, c) => Container(
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFF263425),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Stack(
            children: [
              if (c.maxWidth > 620)
                Positioned(
                  right: -45,
                  top: -38,
                  bottom: -45,
                  child: Opacity(
                    opacity: .55,
                    child: Transform.rotate(
                      angle: -.15,
                      child: const CoverArt(
                        seed: 'Mumpa Sessions',
                        size: 380,
                        radius: 0,
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.all(c.maxWidth > 620 ? 36 : 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const BadgePill(
                      icon: Icons.graphic_eq_rounded,
                      label: 'МУЗЫКА БЕЗ ГРАНИЦ',
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Твоя музыка.\nТвои правила.',
                      style: TextStyle(
                        fontSize: c.maxWidth > 700 ? 48 : 34,
                        height: 1.05,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.7,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const SizedBox(
                      width: 330,
                      child: Text(
                        'Любимые альбомы с диска и из торрентов.\nВ одной коллекции, в твоём ритме.',
                        style: TextStyle(
                          color: Color(0xFFBCC6B6),
                          height: 1.6,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: app.busy == null
                          ? () => showAddMusic(context, app)
                          : null,
                      icon: const Icon(Icons.add_rounded, size: 20),
                      label: const Text('Добавить музыку'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      if (app.recentAlbums.isNotEmpty) ...[
        const SectionTitle(
          'Снова в твоих наушниках',
          subtitle: 'Недавно слушал',
        ),
        albumGrid(app, app.recentAlbums, limit: 6),
      ],
      SectionTitle(
        'Твоя медиатека',
        subtitle:
            '${app.library.tracks.length} треков · ${app.albums.length} альбомов',
        action: TextButton(
          onPressed: () => app.navigate(AppPage.library),
          child: const Text(
            'Открыть всё',
            style: TextStyle(color: muted, fontSize: 11),
          ),
        ),
      ),
      if (app.albums.isEmpty)
        EmptyState(
          icon: Icons.library_music_rounded,
          title: 'Начни с любимого альбома',
          description:
              'Выбери папку с музыкой, аудиофайлы или вставь magnet-ссылку.',
          action: FilledButton(
            onPressed: () => showAddMusic(context, app),
            child: const Text('Добавить музыку'),
          ),
        )
      else
        albumGrid(app, app.albums, limit: 12),
      if (app.library.playlists.isNotEmpty) ...[
        const SectionTitle('Плейлисты на любой момент'),
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
  const _PlaylistGrid(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) => SliverGrid.builder(
    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 350,
      mainAxisExtent: 88,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
    ),
    itemCount: app.library.playlists.length,
    itemBuilder: (_, i) {
      final list = app.library.playlists[i];
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
                        '${list.trackIds.length} треков',
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
              InkWell(
                onTap: () => app.openArtist(album.artist),
                child: Text(
                  album.artist,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${album.year != null ? '${album.year} · ' : ''}${album.tracks.length} треков${album.offline ? ' · Доступен офлайн' : ''}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ],
          );
          final art = CoverArt(
            seed: album.title,
            path: album.artPath,
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
            onPressed: () => app.playback.playTracks(album.tracks),
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
      TrackList(app: app, tracks: album.tracks),
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
      Text(title, style: Theme.of(context).textTheme.headlineLarge),
      const SizedBox(height: 8),
      Text('${tracks.length} треков', style: const TextStyle(color: muted)),
      const SizedBox(height: 24),
      Wrap(
        spacing: 14,
        children: [
          FilledButton.icon(
            onPressed: tracks.isEmpty
                ? null
                : () => app.playback.playTracks(tracks),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Слушать'),
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
        TrackList(app: app, tracks: tracks, playlistId: playlistId),
    ],
  );
}

class _SearchPage extends StatelessWidget {
  const _SearchPage(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) => _PageBody(
    children: [
      SectionTitle(
        'Найди свой звук',
        subtitle: 'Поиск по трекам, альбомам и исполнителям',
      ),
      TextFormField(
        key: const Key('music-search'),
        initialValue: app.query,
        autofocus: true,
        onChanged: app.setQuery,
        onFieldSubmitted: (_) => app.searchSources(),
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search_rounded),
          hintText: 'Что хочешь послушать?',
        ),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: app.searching ? null : app.searchSources,
        icon: app.searching
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.travel_explore_rounded, size: 18),
        label: const Text('Искать в подключённых источниках'),
      ),
      if (app.query.trim().isEmpty)
        const EmptyState(
          icon: Icons.search_rounded,
          title: 'Музыка начинается с поиска',
          description:
              'Введи название трека, альбома или исполнителя. Подключи свой Torznab API в настройках, чтобы искать торрент-релизы.',
        )
      else ...[
        SectionTitle(
          'В твоей медиатеке',
          subtitle: 'Найдено: ${app.searchTracks.length}',
        ),
        if (app.searchTracks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'Пока ничего не найдено.',
              style: TextStyle(color: muted),
            ),
          )
        else
          TrackList(app: app, tracks: app.searchTracks),
        if (app.releases.isNotEmpty) ...[
          const SectionTitle('В подключённых источниках'),
          LazyRows(
            count: app.releases.length,
            builder: (context, i) {
              final item = app.releases[i];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.album_outlined, color: accent),
                title: Text(item.title, style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  '${formatBytes(item.bytes)} · ${item.seeders} сидов',
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
                trailing: const Icon(Icons.add_circle_outline_rounded),
                onTap: () async {
                  final info = await app.inspectTorrent(item.link);
                  if (info != null && context.mounted) {
                    await selectTorrent(context, app, info, link: item.link);
                  }
                },
              );
            },
          ),
        ],
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
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('Торрент-движок'),
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
            const SectionTitle('Поиск в источниках'),
            const Text(
              'Подключи Torznab-совместимый API, например Jackett или Prowlarr. В приложении нет предустановленных музыкальных трекеров.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: source,
              decoration: const InputDecoration(
                labelText: 'URL Torznab API',
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
              onPressed: () async {
                await widget.app.library.setSetting(
                  'indexerUrl',
                  source.text.trim(),
                );
                await widget.app.library.setSetting(
                  'indexerKey',
                  apiKey.text.trim(),
                );
                widget.app.reportMessage('Источник поиска сохранён.');
              },
              child: const Text('Сохранить источник'),
            ),
            const SectionTitle('Mumpa 1.0'),
            const Text(
              'Музыка из твоих файлов и источников.\nДемо Mumpa Sessions — оригинальные синтезированные фрагменты.\nFlutter · media_kit · TorrServer MatriX.145.2',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Mumpa',
                applicationVersion: '1.0.0',
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
