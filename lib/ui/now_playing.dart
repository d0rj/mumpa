part of 'player.dart';

class _NowPlaying extends StatelessWidget {
  const _NowPlaying(this.app);
  final AppController app;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final availableHeight = math.max(0.0, constraints.maxHeight - 24);
      final wide =
          constraints.maxWidth >= 620 &&
          constraints.maxWidth > constraints.maxHeight * 1.25;
      final width = math.min(620.0, constraints.maxWidth - 32);
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final coverSize = wide
          ? math.min(
              availableHeight,
              math.min(340.0, (constraints.maxWidth - 56) * .4),
            )
          : math.min(width, math.max(144.0, availableHeight - 400 * scale));
      final controls = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SeekBar(app.playback, expanded: true),
          const SizedBox(height: 8),
          _Transport(app.playback, large: true),
        ],
      );
      final footer = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _NowPlayingVolume(app.playback),
          const SizedBox(height: 4),
          _NowPlayingStatus(app),
          if (app.playback.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                app.playback.error!,
                style: const TextStyle(color: Color(0xFFFF9292), fontSize: 12),
              ),
            ),
        ],
      );
      return SingleChildScrollView(
        key: const ValueKey('now-playing-scroll'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: availableHeight),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      flex: 4,
                      child: Center(child: _NowPlayingCover(app, coverSize)),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      flex: 6,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _NowPlayingInfo(app),
                          const SizedBox(height: 12),
                          controls,
                          const SizedBox(height: 12),
                          footer,
                        ],
                      ),
                    ),
                  ],
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: width),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: availableHeight),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _NowPlayingCover(app, coverSize),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: _NowPlayingInfo(app),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: controls,
                          ),
                          footer,
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      );
    },
  );
}

class _NowPlayingCover extends StatelessWidget {
  const _NowPlayingCover(this.app, this.size);
  final AppController app;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    key: const ValueKey('now-playing-cover'),
    dimension: size,
    child: Stack(
      children: [
        TrackArtwork(
          app: app,
          track: app.playback.current,
          size: size,
          radius: 20,
        ),
        if (app.playback.current != null)
          Positioned(
            top: 8,
            right: 8,
            child: Material(
              color: const Color(0xC918201C),
              shape: const CircleBorder(
                side: BorderSide(color: Color(0x667E8F84)),
              ),
              child: _NowPlayingMenu(app: app, track: app.playback.current!),
            ),
          ),
      ],
    ),
  );
}

class _NowPlayingInfo extends StatelessWidget {
  const _NowPlayingInfo(this.app);
  final AppController app;

  void _open(BuildContext context, VoidCallback navigate) {
    Navigator.pop(context);
    navigate();
  }

  @override
  Widget build(BuildContext context) {
    final track = app.playback.current;
    final artist = _NowPlayingLink(
      key: const ValueKey('now-playing-artist'),
      label: 'Исполнитель',
      title: track?.artist ?? 'Музыка всегда рядом',
      leading: const Icon(
        Icons.person_outline_rounded,
        color: Color(0xFFB9C9BE),
      ),
      onTap: track == null || !hasArtistPage(track.artist)
          ? null
          : () => _open(context, () => app.openArtist(track.artist)),
    );
    final album = _NowPlayingLink(
      key: const ValueKey('now-playing-album'),
      label: 'Альбом',
      title: track?.album ?? 'Выбери музыку',
      leading: _DiscArtwork(app: app, track: track),
      onTap: track == null
          ? null
          : () => _open(context, () => app.openTrackAlbum(track)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                track?.title ?? 'Выбери трек',
                key: const ValueKey('now-playing-title'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (track != null)
              IconButton(
                tooltip: app.library.isTrackLiked(track.id)
                    ? 'Убрать из любимого'
                    : 'В любимое',
                onPressed: () => app.library.toggleLike(track.id),
                icon: Icon(
                  app.library.isTrackLiked(track.id)
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: accent,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (_, constraints) {
            if (constraints.maxWidth >= 340 &&
                MediaQuery.textScalerOf(context).scale(14) <= 19) {
              return Row(
                children: [
                  Expanded(child: artist),
                  const SizedBox(width: 8),
                  Expanded(child: album),
                ],
              );
            }
            return Column(children: [artist, const SizedBox(height: 6), album]);
          },
        ),
      ],
    );
  }
}

class _NowPlayingLink extends StatelessWidget {
  const _NowPlayingLink({
    super.key,
    required this.label,
    required this.title,
    required this.leading,
    required this.onTap,
  });
  final String label, title;
  final Widget leading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: '$label: $title',
    child: Material(
      color: const Color(0xFF242E28),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                SizedBox.square(dimension: 32, child: Center(child: leading)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(color: muted, fontSize: 10),
                      ),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onTap != null)
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: muted,
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _DiscArtwork extends StatelessWidget {
  const _DiscArtwork({required this.app, required this.track});
  final AppController app;
  final Track? track;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    key: const ValueKey('now-playing-album-disc'),
    dimension: 32,
    child: Stack(
      alignment: Alignment.center,
      children: [
        ClipOval(
          child: TrackArtwork(app: app, track: track, size: 32, radius: 16),
        ),
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: .35)),
          ),
        ),
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: const Color(0xFF242E28),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: .6),
              width: 1.5,
            ),
          ),
        ),
      ],
    ),
  );
}

const _volumeBlue = Color(0xFF8FCBFF);

class _NowPlayingVolume extends StatelessWidget {
  const _NowPlayingVolume(this.player);
  final PlaybackController player;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('now-playing-volume-panel'),
    padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
    decoration: BoxDecoration(
      color: const Color(0xFF1B2935),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFF3C5365)),
    ),
    child: Row(
      children: [
        IconButton(
          tooltip: player.volume == 0 ? 'Включить звук' : 'Без звука',
          onPressed: () => player.setVolume(player.volume == 0 ? .8 : 0),
          icon: Icon(
            player.volume == 0
                ? Icons.volume_off_rounded
                : Icons.volume_up_rounded,
            color: _volumeBlue,
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Громкость',
                      style: TextStyle(color: _volumeBlue, fontSize: 11),
                    ),
                    Text(
                      '${(player.volume * 100).round()}%',
                      key: const ValueKey('now-playing-volume-percent'),
                      style: const TextStyle(
                        color: _volumeBlue,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: _volumeBlue,
                  inactiveTrackColor: const Color(0xFF536E83),
                  thumbColor: _volumeBlue,
                  overlayColor: _volumeBlue.withValues(alpha: .15),
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                  ),
                ),
                child: Semantics(
                  label: 'Громкость',
                  child: Slider(
                    key: const ValueKey('now-playing-volume'),
                    value: player.volume.clamp(0, 1),
                    semanticFormatterCallback: (value) =>
                        '${(value * 100).round()}%',
                    onChanged: player.setVolume,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _NowPlayingStatus extends StatelessWidget {
  const _NowPlayingStatus(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final player = app.playback;
    final track = player.current;
    return Row(
      key: const ValueKey('now-playing-status'),
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: BadgePill(
            icon: track?.offline == true
                ? Icons.offline_bolt_rounded
                : Icons.wifi_rounded,
            label: track == null
                ? 'МУЗЫКА ВСЕГДА РЯДОМ'
                : track.offline
                ? 'ЛОКАЛЬНЫЙ ФАЙЛ'
                : 'ТОРРЕНТ-ПОТОК',
          ),
        ),
        PopupMenuButton<int>(
          tooltip: 'Таймер сна',
          icon: Icon(
            Icons.bedtime_outlined,
            color: player.sleepUntil != null ? accent : muted,
            size: 22,
          ),
          onSelected: (minutes) =>
              player.setSleep(minutes == 0 ? null : Duration(minutes: minutes)),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 15, child: Text('Выключить через 15 мин')),
            PopupMenuItem(value: 30, child: Text('Выключить через 30 мин')),
            PopupMenuItem(value: 60, child: Text('Выключить через час')),
            PopupMenuItem(value: 0, child: Text('Отключить таймер')),
          ],
        ),
      ],
    );
  }
}

class _NowPlayingMenu extends StatelessWidget {
  const _NowPlayingMenu({required this.app, required this.track});
  final AppController app;
  final Track track;

  PopupMenuItem<String> _item(String value, IconData icon, String label) =>
      PopupMenuItem(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 20, color: muted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final latest = app.library.byId(track.id) ?? track;
    final currentPlaylist = app.currentPlaylist;
    final collection = app.library.playlists
        .where(
          (p) =>
              latest.torrentHash != null &&
              p.sourceHash == latest.torrentHash &&
              p.trackIds.contains(latest.id),
        )
        .firstOrNull;
    void navigate(VoidCallback open) {
      Navigator.pop(context);
      open();
    }

    return PopupMenuButton<String>(
      key: const ValueKey('now-playing-actions'),
      tooltip: 'Действия с треком',
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 340),
      icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
      onSelected: (action) async {
        if (!context.mounted) return;
        switch (action) {
          case 'artist':
            navigate(() => app.openArtist(latest.artist));
          case 'album':
            navigate(() => app.openTrackAlbum(latest));
          case 'playlist':
            navigate(() => app.openPlaylist(currentPlaylist!));
          case 'collection':
            navigate(() => app.openPlaylist(collection!));
          case 'addPlaylist':
            await choosePlaylist(context, app, [latest.id]);
          case 'like':
            await app.library.toggleLike(latest.id);
          case 'next':
            app.playback.enqueue(latest, next: true);
          case 'queue':
            app.playback.enqueue(latest);
          case 'download':
            app.downloads.enqueue([latest]);
          case 'copy':
            await Clipboard.setData(
              ClipboardData(text: '${latest.artist} — ${latest.title}'),
            );
          case 'reveal':
            try {
              await FileLocationService.revealTrack(app.library, latest);
            } on FileSystemException catch (error) {
              app.reportError(error.message);
            } catch (_) {
              app.reportError(
                'Не удалось открыть расположение трека в проводнике.',
              );
            }
          case 'removeCache':
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Удалить офлайн-копию?'),
                content: const Text(
                  'Трек сохранится в библиотеке и избранном, но для прослушивания потребуется сеть.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
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
              await app.downloads.removeOffline(latest, userRequested: true);
            }
        }
      },
      itemBuilder: (_) => [
        _item('album', Icons.album_outlined, 'Перейти к альбому'),
        if (hasArtistPage(latest.artist))
          _item(
            'artist',
            Icons.person_outline_rounded,
            'Перейти к исполнителю',
          ),
        if (currentPlaylist != null)
          _item(
            'playlist',
            Icons.queue_music_rounded,
            'Открыть плейлист «${currentPlaylist.name}»',
          ),
        if (collection != null && collection.id != currentPlaylist?.id)
          _item(
            'collection',
            Icons.library_music_outlined,
            'Открыть коллекцию',
          ),
        const PopupMenuDivider(),
        _item('addPlaylist', Icons.playlist_add_rounded, 'Добавить в плейлист'),
        _item(
          'like',
          app.library.isTrackLiked(latest.id)
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          app.library.isTrackLiked(latest.id)
              ? 'Убрать из любимого'
              : 'В любимое',
        ),
        _item('next', Icons.playlist_play_rounded, 'Слушать следующим'),
        _item('queue', Icons.queue_music_rounded, 'В конец очереди'),
        const PopupMenuDivider(),
        if (latest.source == TrackSource.torrent && !latest.offline)
          _item('download', Icons.download_rounded, 'Скачать для офлайн'),
        if (latest.cachedPath != null)
          _item(
            'removeCache',
            Icons.delete_outline_rounded,
            'Удалить офлайн-копию',
          ),
        if (FileLocationService.canReveal(app.library, latest))
          _item('reveal', Icons.folder_open_rounded, 'Показать в проводнике'),
        _item('copy', Icons.copy_rounded, 'Скопировать название'),
      ],
    );
  }
}
