part of 'player.dart';

class _NowPlaying extends StatelessWidget {
  const _NowPlaying(this.app);
  final AppController app;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final compact =
            constraints.maxHeight < 560 ||
            (scale > 1.4 && constraints.maxHeight < 700);
        final wide =
            constraints.maxWidth >= 560 &&
            constraints.maxWidth > constraints.maxHeight * 1.25;
        final gap = compact ? 6.0 : 12.0;
        final info = _NowPlayingInfo(app, compact: compact);
        final status = _NowPlayingStatus(app);
        final volume = _NowPlayingVolume(app.playback, compact: compact);
        final error = app.playback.error == null
            ? null
            : trMessage(app.playback.error!);
        final errorMessage = error == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Tooltip(
                  message: error,
                  child: Text(
                    error,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFFF9292),
                      fontSize: 12,
                    ),
                  ),
                ),
              );
        Widget artwork() => LayoutBuilder(
          builder: (_, space) => Center(
            child: _NowPlayingCover(
              app,
              math.min(
                620.0,
                math.max(0.0, math.min(space.maxWidth, space.maxHeight)),
              ),
              showActions: !compact,
            ),
          ),
        );
        final controls = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SeekBar(app.playback, expanded: true),
            SizedBox(height: compact ? 2 : 8),
            _Transport(app.playback, large: true, compact: compact),
          ],
        );
        if (wide) {
          // Leave the controls their natural height. Artwork gets the remainder,
          // including on a short desktop window or a tablet in landscape.
          final coverWidth = math.max(
            0.0,
            math.min(
              (constraints.maxWidth - 16) * (compact ? .32 : .4),
              constraints.maxWidth - 16 - (compact ? 460 : 380),
            ),
          );
          return Row(
            key: const ValueKey('now-playing-viewport'),
            children: [
              SizedBox(
                width: coverWidth,
                child: Column(
                  children: [
                    Expanded(child: artwork()),
                    if (compact) status,
                    if (compact && errorMessage != null) errorMessage,
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    info,
                    SizedBox(height: gap),
                    if (compact) ...[
                      _SeekBar(app.playback, expanded: true, inlineTimes: true),
                      SizedBox(height: gap),
                      Row(
                        children: [
                          SizedBox(
                            width: 256,
                            child: _Transport(
                              app.playback,
                              large: true,
                              compact: true,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: volume),
                        ],
                      ),
                    ] else ...[
                      controls,
                      SizedBox(height: gap),
                      volume,
                      const SizedBox(height: 4),
                      status,
                      ?errorMessage,
                    ],
                  ],
                ),
              ),
            ],
          );
        }
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              key: const ValueKey('now-playing-viewport'),
              children: [
                Expanded(child: artwork()),
                SizedBox(height: gap),
                info,
                SizedBox(height: gap),
                controls,
                SizedBox(height: gap),
                volume,
                const SizedBox(height: 4),
                status,
                ?errorMessage,
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _NowPlayingCover extends StatelessWidget {
  const _NowPlayingCover(this.app, this.size, {this.showActions = true});
  final AppController app;
  final double size;
  final bool showActions;

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
        if (showActions && app.playback.current != null)
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
  const _NowPlayingInfo(this.app, {this.compact = false});
  final AppController app;
  final bool compact;

  void _open(BuildContext context, VoidCallback navigate) {
    Navigator.pop(context);
    navigate();
  }

  @override
  Widget build(BuildContext context) {
    final track = app.playback.current;
    final artist = _NowPlayingLink(
      key: const ValueKey('now-playing-artist'),
      compact: compact,
      label: tr("Исполнитель"),
      title: track?.artist ?? tr("Музыка всегда рядом"),
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
      compact: compact,
      label: tr("Альбом"),
      title: track?.album ?? tr("Выбери музыку"),
      leading: _DiscArtwork(app: app, track: track),
      onTap: track == null
          ? null
          : () => _open(context, () => app.openTrackAlbum(track)),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                track?.title ?? tr("Выбери трек"),
                key: const ValueKey('now-playing-title'),
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (track != null)
              IconButton(
                tooltip: app.library.isTrackLiked(track.id)
                    ? tr("Убрать из любимого")
                    : tr("В любимое"),
                onPressed: () => app.library.toggleLike(track.id),
                icon: Icon(
                  app.library.isTrackLiked(track.id)
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: accent,
                ),
              ),
            if (track != null && compact)
              _NowPlayingMenu(app: app, track: track),
          ],
        ),
        SizedBox(height: compact ? 4 : 8),
        LayoutBuilder(
          builder: (_, constraints) {
            if (compact ||
                (constraints.maxWidth >= 340 &&
                    MediaQuery.textScalerOf(context).scale(14) <= 19)) {
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
    this.compact = false,
  });
  final String label, title;
  final Widget leading;
  final VoidCallback? onTap;
  final bool compact;

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
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 10,
              vertical: compact ? 4 : 8,
            ),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: compact ? 24 : 32,
                  child: Center(child: leading),
                ),
                SizedBox(width: compact ? 6 : 10),
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
                        maxLines: compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onTap != null && !compact)
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
  const _NowPlayingVolume(this.player, {this.compact = false});
  final PlaybackController player;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Container(
        key: const ValueKey('now-playing-volume-panel'),
        padding: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1B2935),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF3C5365)),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: player.volume == 0
                  ? tr("Включить звук")
                  : tr("Без звука"),
              onPressed: () => player.setVolume(player.volume == 0 ? .8 : 0),
              icon: Icon(
                player.volume == 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                color: _volumeBlue,
              ),
            ),
            Expanded(child: _slider(context)),
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
      );
    }
    return Container(
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
            tooltip: player.volume == 0 ? tr("Включить звук") : tr("Без звука"),
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
                      Text(
                        tr("Громкость"),
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
                _slider(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider(BuildContext context) => SliderTheme(
    data: SliderTheme.of(context).copyWith(
      activeTrackColor: _volumeBlue,
      inactiveTrackColor: const Color(0xFF536E83),
      thumbColor: _volumeBlue,
      overlayColor: _volumeBlue.withValues(alpha: .15),
      trackHeight: 4,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
    ),
    child: Semantics(
      label: tr("Громкость"),
      child: AccessibleSlider(
        child: Slider(
          key: const ValueKey('now-playing-volume'),
          value: player.volume.clamp(0, 1),
          semanticFormatterCallback: (value) => '${(value * 100).round()}%',
          onChanged: player.setVolume,
        ),
      ),
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
                ? tr("МУЗЫКА ВСЕГДА РЯДОМ")
                : track.offline
                ? tr("ЛОКАЛЬНЫЙ ФАЙЛ")
                : tr("ТОРРЕНТ-ПОТОК"),
          ),
        ),
        PopupMenuButton<int>(
          tooltip: tr("Таймер сна"),
          icon: Icon(
            Icons.bedtime_outlined,
            color: player.sleepUntil != null ? accent : muted,
            size: 22,
          ),
          onSelected: (minutes) =>
              player.setSleep(minutes == 0 ? null : Duration(minutes: minutes)),
          itemBuilder: (_) => [
            PopupMenuItem(value: 15, child: Text(tr("Выключить через 15 мин"))),
            PopupMenuItem(value: 30, child: Text(tr("Выключить через 30 мин"))),
            PopupMenuItem(value: 60, child: Text(tr("Выключить через час"))),
            PopupMenuItem(value: 0, child: Text(tr("Отключить таймер"))),
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
      tooltip: tr("Действия с треком"),
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
                tr("Не удалось открыть расположение трека в проводнике."),
              );
            }
          case 'removeCache':
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(tr("Удалить офлайн-копию?")),
                content: Text(
                  tr(
                    "Трек сохранится в библиотеке и избранном, но для прослушивания потребуется сеть.",
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(tr("Отмена")),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(tr("Удалить копию")),
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
        _item('album', Icons.album_outlined, tr("Перейти к альбому")),
        if (hasArtistPage(latest.artist))
          _item(
            'artist',
            Icons.person_outline_rounded,
            tr("Перейти к исполнителю"),
          ),
        if (currentPlaylist != null)
          _item(
            'playlist',
            Icons.queue_music_rounded,
            tr("Открыть плейлист «{0}»", [currentPlaylist.name]),
          ),
        if (collection != null && collection.id != currentPlaylist?.id)
          _item(
            'collection',
            Icons.library_music_outlined,
            tr("Открыть коллекцию"),
          ),
        const PopupMenuDivider(),
        _item(
          'addPlaylist',
          Icons.playlist_add_rounded,
          tr("Добавить в плейлист"),
        ),
        _item(
          'like',
          app.library.isTrackLiked(latest.id)
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          app.library.isTrackLiked(latest.id)
              ? tr("Убрать из любимого")
              : tr("В любимое"),
        ),
        _item('next', Icons.playlist_play_rounded, tr("Слушать следующим")),
        _item('queue', Icons.queue_music_rounded, tr("В конец очереди")),
        const PopupMenuDivider(),
        if (latest.source == TrackSource.torrent && !latest.offline)
          _item('download', Icons.download_rounded, tr("Скачать для офлайн")),
        if (latest.cachedPath != null)
          _item(
            'removeCache',
            Icons.delete_outline_rounded,
            tr("Удалить офлайн-копию"),
          ),
        if (FileLocationService.canReveal(app.library, latest))
          _item(
            'reveal',
            Icons.folder_open_rounded,
            tr("Показать в проводнике"),
          ),
        _item('copy', Icons.copy_rounded, tr("Скопировать название")),
      ],
    );
  }
}
