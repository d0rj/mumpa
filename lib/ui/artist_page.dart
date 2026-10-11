part of 'pages.dart';

class _ArtistPage extends StatelessWidget {
  const _ArtistPage(this.app);
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final profile = app.artistProfile;
    final name = profile?.name ?? app.selectedArtist ?? 'Исполнитель';
    final tracks = app.artistTracks;
    final albums = app.artistAlbums;
    final visibleTracks = app.artistSearchTracks;
    final visibleAlbums = app.artistSearchAlbums;
    final artistTrackIds = tracks.map((track) => track.id).toSet();
    final likedTracks = app.likedTracks
        .where((track) => artistTrackIds.contains(track.id))
        .toList();
    final visibleTrackIds = visibleTracks.map((track) => track.id).toSet();
    final visibleLikedTracks = likedTracks
        .where((track) => visibleTrackIds.contains(track.id))
        .toList();
    final discography = app.artistSearchDiscography;
    final recordings = app.artistSearchRecordings;
    final searching = normalizeMusicName(
      app.localQuery(app.artistSearchScope),
    ).isNotEmpty;
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
                app.openGlobalSearch(name, tracks: false);
                unawaited(app.searchSources());
              },
              icon: const Icon(Icons.search_rounded, size: 18),
              label: const Text('Найти в источниках'),
            ),
          ],
        ),
        LocalSearchField(
          app: app,
          scope: app.artistSearchScope,
          hint: 'Поиск у исполнителя: альбом или трек',
        ),
        if (visibleLikedTracks.isNotEmpty) ...[
          SectionTitle(
            'Любимые треки',
            key: const ValueKey('artist-liked-section'),
            subtitle: '${visibleLikedTracks.length} треков',
            action: IconButton(
              key: const ValueKey('play-artist-liked'),
              tooltip: 'Слушать любимые треки исполнителя',
              onPressed: () => app.playCollection(likedTracks),
              icon: const Icon(Icons.play_arrow_rounded, color: accent),
            ),
          ),
          TrackList(
            key: const ValueKey('artist-liked-tracks'),
            app: app,
            tracks: visibleLikedTracks,
            queueTracks: likedTracks,
          ),
        ],
        if (visibleAlbums.isNotEmpty) ...[
          const SectionTitle('Твои альбомы'),
          albumGrid(app, visibleAlbums),
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
        if (discography.isNotEmpty) ...[
          const SectionTitle(
            'Дискография',
            subtitle:
                'MusicBrainz · выбери альбом, чтобы найти его в источниках',
          ),
          _DiscographyGrid(app, discography),
        ],
        if (visibleTracks.isNotEmpty) ...[
          const SectionTitle('Треки в твоей медиатеке'),
          TrackList(app: app, tracks: visibleTracks),
        ],
        if (recordings.isNotEmpty) ...[
          const SectionTitle(
            'Треки из каталога',
            subtitle: 'Выбери трек для поиска доступных версий',
          ),
          RecordingRows(app: app, recordings: recordings),
        ],
        if (!searching && app.similarArtistResults.isNotEmpty) ...[
          const SectionTitle(
            'Похожие исполнители',
            key: ValueKey('similar-artists-section'),
            subtitle: 'ListenBrainz · по совместным прослушиваниям',
          ),
          LazyRows(
            count: app.similarArtistResults.length,
            builder: (context, index) {
              final artist = app.similarArtistResults[index];
              return ListTile(
                key: ValueKey('similar-artist-${artist.id}'),
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFF2D3D2B),
                  child: Icon(Icons.person_rounded, color: accent),
                ),
                title: Text(
                  artist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: artist.disambiguation.isEmpty
                    ? null
                    : Text(
                        artist.disambiguation,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: const Icon(Icons.chevron_right_rounded, color: muted),
                onTap: () => app.openArtist(artist.name, artistId: artist.id),
              );
            },
          ),
        ],
        if (searching &&
            !app.artistLoading &&
            visibleTracks.isEmpty &&
            visibleAlbums.isEmpty &&
            discography.isEmpty &&
            recordings.isEmpty)
          const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Ничего не найдено у этого исполнителя',
            description: 'Попробуй другой запрос или очисти поиск.',
          ),
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
        ] else if (!searching && !app.artistLoading && tracks.isEmpty)
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
