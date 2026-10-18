import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/file_location_service.dart';
import '../domain/models.dart';
import '../logic/app_controller.dart';
import '../logic/playback_controller.dart';
import 'components.dart';
import 'theme.dart';

part 'now_playing.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.app, required this.compact});
  final AppController app;
  final bool compact;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      app.playback.controlsState,
      app.library,
      app,
    ]),
    builder: (context, _) {
      final p = app.playback;
      final t = p.current;
      if (compact) {
        return Container(
          margin: const EdgeInsets.fromLTRB(8, 2, 8, 4),
          decoration: BoxDecoration(
            color: const Color(0xFF263124),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () => showNowPlaying(context, app),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(9, 7, 6, 5),
                  child: Row(
                    children: [
                      TrackArtwork(app: app, track: t, size: 42, radius: 6),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t?.title ?? 'Выбери свой первый трек',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            ArtistLink(
                              artist: t?.artist ?? 'Музыка всегда рядом',
                              onOpen: t == null
                                  ? null
                                  : () => app.openArtist(t.artist),
                              style: const TextStyle(
                                fontSize: 10,
                                color: muted,
                              ),
                            ),
                            if (t != null)
                              AlbumLink(
                                key: const ValueKey('player-album'),
                                album: t.album,
                                onOpen: () => app.openTrackAlbum(t),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const Key('player-toggle'),
                        onPressed: t == null ? null : p.toggle,
                        tooltip: p.buffering
                            ? 'Отменить загрузку'
                            : p.playing
                            ? 'Пауза'
                            : 'Слушать',
                        icon: p.buffering
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                p.playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 28,
                              ),
                      ),
                      IconButton(
                        onPressed: p.hasQueue ? p.next : null,
                        tooltip: 'Следующий трек',
                        icon: const Icon(Icons.skip_next_rounded, size: 24),
                      ),
                    ],
                  ),
                ),
              ),
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(10),
                ),
                child: ListenableBuilder(
                  listenable: p,
                  builder: (_, _) => LinearProgressIndicator(
                    minHeight: 2,
                    value: p.duration.inMilliseconds > 0
                        ? (p.position.inMilliseconds /
                                  p.duration.inMilliseconds)
                              .clamp(0, 1)
                        : 0,
                    backgroundColor: Colors.white.withValues(alpha: .07),
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
        );
      }
      return Container(
        height: 100,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: const BoxDecoration(
          color: Color(0xFF0F1410),
          border: Border(top: BorderSide(color: Color(0xFF2B332C))),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  InkWell(
                    onTap: () => showNowPlaying(context, app),
                    child: TrackArtwork(app: app, track: t, size: 58),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: InkWell(
                      onTap: () => showNowPlaying(context, app),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t?.title ?? 'Выбери первый трек',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          ArtistLink(
                            artist: t?.artist ?? 'Твоя музыка всегда рядом',
                            onOpen: t == null
                                ? null
                                : () => app.openArtist(t.artist),
                            style: const TextStyle(fontSize: 10, color: muted),
                          ),
                          if (t != null)
                            AlbumLink(
                              key: const ValueKey('player-album'),
                              album: t.album,
                              onOpen: () => app.openTrackAlbum(t),
                              style: const TextStyle(
                                fontSize: 10,
                                color: muted,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (t != null)
                    IconButton(
                      onPressed: () => app.library.toggleLike(t.id),
                      tooltip: 'Любимый трек',
                      icon: Icon(
                        app.library.isTrackLiked(t.id)
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 18,
                        color: app.library.isTrackLiked(t.id) ? accent : muted,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [_Transport(p), _SeekBar(p)],
                ),
              ),
            ),
            SizedBox(
              width: 272,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    width: 40,
                    child: IconButton(
                      onPressed: () => showNowPlaying(context, app, tab: 1),
                      tooltip: 'Очередь',
                      icon: const Icon(
                        Icons.queue_music_rounded,
                        size: 20,
                        color: muted,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: IconButton(
                      key: const ValueKey('desktop-lyrics'),
                      onPressed: _hasLyrics(t)
                          ? () => showNowPlaying(context, app, tab: 2)
                          : null,
                      tooltip: 'Текст песни',
                      icon: Icon(
                        Icons.lyrics_outlined,
                        size: 18,
                        color: _hasLyrics(t)
                            ? muted
                            : muted.withValues(alpha: .35),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: IconButton(
                      onPressed: () => p.setVolume(p.volume == 0 ? 0.8 : 0),
                      tooltip: 'Без звука',
                      icon: Icon(
                        p.volume == 0
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        size: 20,
                        color: muted,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 152,
                    child: Semantics(
                      label: 'Громкость',
                      child: Slider(
                        key: const ValueKey('desktop-volume'),
                        value: p.volume.clamp(0, 1),
                        semanticFormatterCallback: (value) =>
                            '${(value * 100).round()}%',
                        onChanged: p.setVolume,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

bool _hasLyrics(Track? track) => track?.lyrics?.trim().isNotEmpty == true;

class _Transport extends StatelessWidget {
  const _Transport(this.p, {this.large = false});
  final PlaybackController p;
  final bool large;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        onPressed: p.toggleShuffle,
        tooltip: 'Перемешать',
        icon: Icon(
          Icons.shuffle_rounded,
          size: large ? 23 : 18,
          color: p.shuffle ? accent : muted,
        ),
      ),
      IconButton(
        onPressed: p.hasQueue ? p.previous : null,
        tooltip: 'Предыдущий трек',
        icon: Icon(Icons.skip_previous_rounded, size: large ? 32 : 25),
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: large ? 62 : 38,
        height: large ? 62 : 38,
        child: IconButton.filled(
          key: const Key('transport-toggle'),
          onPressed: p.current == null ? null : p.toggle,
          tooltip: p.buffering
              ? 'Отменить загрузку'
              : p.playing
              ? 'Пауза'
              : 'Слушать',
          style: IconButton.styleFrom(
            backgroundColor: large ? accent : Colors.white,
            foregroundColor: Colors.black,
            padding: EdgeInsets.zero,
          ),
          icon: p.buffering
              ? const Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black,
                    ),
                  ),
                )
              : Icon(
                  p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: large ? 38 : 27,
                ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton(
        onPressed: p.hasQueue ? p.next : null,
        tooltip: 'Следующий трек',
        icon: Icon(Icons.skip_next_rounded, size: large ? 32 : 25),
      ),
      IconButton(
        onPressed: p.cycleRepeat,
        tooltip: switch (p.repeat) {
          PlayerRepeatMode.off => 'Повтор выключен',
          PlayerRepeatMode.all => 'Повтор очереди',
          PlayerRepeatMode.one => 'Повтор трека',
        },
        icon: Icon(
          p.repeat == PlayerRepeatMode.one
              ? Icons.repeat_one_rounded
              : Icons.repeat_rounded,
          size: large ? 23 : 18,
          color: p.repeat == PlayerRepeatMode.off ? muted : accent,
        ),
      ),
    ],
  );
}

class _SeekBar extends StatefulWidget {
  const _SeekBar(this.player, {this.expanded = false});
  final PlaybackController player;
  final bool expanded;
  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? drag;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.player,
    builder: (context, _) => _timeline(context),
  );

  Widget _timeline(BuildContext context) {
    final p = widget.player;
    final max = p.duration.inMilliseconds.toDouble();
    final value = drag ?? p.position.inMilliseconds.toDouble().clamp(0, max);
    final slider = Semantics(
      label: 'Позиция воспроизведения',
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: accent,
          inactiveTrackColor: const Color(0xFF566359),
          disabledInactiveTrackColor: const Color(0xFF3C4740),
          trackHeight: widget.expanded ? 6 : 3,
          thumbColor: accent,
          thumbShape: RoundSliderThumbShape(
            enabledThumbRadius: widget.expanded ? 7 : 5,
          ),
        ),
        child: Slider(
          key: widget.expanded ? const ValueKey('now-playing-seek') : null,
          value: max > 0 ? value.clamp(0, max) : 0,
          max: max > 0 ? max : 1,
          semanticFormatterCallback: (value) =>
              formatTime(Duration(milliseconds: value.toInt())),
          onChanged: max > 0 ? (value) => setState(() => drag = value) : null,
          onChangeEnd: max > 0
              ? (value) {
                  p.seek(Duration(milliseconds: value.toInt()));
                  setState(() => drag = null);
                }
              : null,
        ),
      ),
    );
    if (widget.expanded) {
      return Column(
        children: [
          slider,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formatTime(Duration(milliseconds: value.toInt())),
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
                Text(
                  formatTime(p.duration),
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Text(
          formatTime(Duration(milliseconds: value.toInt())),
          style: const TextStyle(color: muted, fontSize: 10),
        ),
        Expanded(child: slider),
        Text(
          formatTime(p.duration),
          style: const TextStyle(color: muted, fontSize: 10),
        ),
      ],
    );
  }
}

Future<void> showNowPlaying(
  BuildContext context,
  AppController app, {
  int tab = 0,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: surface,
    constraints: const BoxConstraints(maxWidth: 850),
    builder: (_) => _NowPlayingSheet(app: app, initialTab: tab),
  );
}

class _NowPlayingSheet extends StatefulWidget {
  const _NowPlayingSheet({required this.app, required this.initialTab});
  final AppController app;
  final int initialTab;

  @override
  State<_NowPlayingSheet> createState() => _NowPlayingSheetState();
}

class _NowPlayingSheetState extends State<_NowPlayingSheet>
    with TickerProviderStateMixin {
  late TabController _tabs;
  late bool _lyrics;

  @override
  void initState() {
    super.initState();
    _lyrics = _hasLyrics(widget.app.playback.current);
    final count = _lyrics ? 3 : 2;
    _tabs = TabController(
      length: count,
      initialIndex: widget.initialTab.clamp(0, count - 1).toInt(),
      vsync: this,
    );
    widget.app.playback.controlsState.addListener(_refresh);
    widget.app.library.addListener(_refresh);
    widget.app.addListener(_refresh);
  }

  void _refresh() {
    if (!mounted) return;
    final lyrics = _hasLyrics(widget.app.playback.current);
    if (lyrics != _lyrics) {
      final index = _tabs.index;
      _tabs.dispose();
      _lyrics = lyrics;
      _tabs = TabController(
        length: lyrics ? 3 : 2,
        initialIndex: index == 2 && !lyrics ? 0 : index,
        vsync: this,
      );
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.app.playback.controlsState.removeListener(_refresh);
    widget.app.library.removeListener(_refresh);
    widget.app.removeListener(_refresh);
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .94,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
          child: Row(
            children: [
              const Icon(Icons.graphic_eq_rounded, color: accent, size: 19),
              const SizedBox(width: 8),
              const Text(
                'СЕЙЧАС ИГРАЕТ',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabs,
          tabs: [
            const Tab(text: 'Плеер'),
            const Tab(text: 'Очередь'),
            if (_lyrics) const Tab(text: 'Текст'),
          ],
        ),
        Expanded(
          child: TabBarView(
            key: ValueKey(_lyrics),
            controller: _tabs,
            children: [
              _NowPlaying(widget.app),
              _Queue(widget.app),
              if (_lyrics) _Lyrics(widget.app),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Queue extends StatelessWidget {
  const _Queue(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final p = app.playback;
    final queue = p.queue;
    final entryKeys = p.queueEntryKeys;
    return queue.isEmpty
        ? const EmptyState(
            icon: Icons.queue_music_rounded,
            title: 'Очередь пуста',
            description: 'Включи альбом или добавь треки через меню.',
          )
        : ReorderableListView.builder(
            key: const Key('playback-queue'),
            header: SwitchListTile.adaptive(
              key: const ValueKey('queue-radio-autoplay'),
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Радио после плейлиста',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                p.radioStatus,
                style: const TextStyle(color: muted, fontSize: 11),
              ),
              value: p.radioEnabled,
              onChanged: (value) => unawaited(p.setRadioEnabled(value)),
            ),
            padding: const EdgeInsets.all(18),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) => unawaited(p.moveQueue(from, to)),
            itemCount: queue.length,
            itemBuilder: (context, i) {
              final t = queue[i];
              final entry = entryKeys[i];
              return Material(
                key: ValueKey('queue-entry-$entry'),
                color: surface,
                borderRadius: BorderRadius.circular(12),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => p.jump(i),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            children: [
                              TrackArtwork(app: app, track: t, size: 44),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: i == p.index
                                            ? accent
                                            : Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    ArtistLink(
                                      artist: t.artist,
                                      onOpen: () {
                                        Navigator.pop(context);
                                        app.openArtist(t.artist);
                                      },
                                      style: const TextStyle(
                                        color: muted,
                                        fontSize: 11,
                                      ),
                                    ),
                                    AlbumLink(
                                      key: ValueKey('queue-album-$entry'),
                                      album: t.album,
                                      onOpen: () {
                                        Navigator.pop(context);
                                        app.openTrackAlbum(t);
                                      },
                                      style: const TextStyle(
                                        color: muted,
                                        fontSize: 11,
                                      ),
                                    ),
                                    if (p.isRadioEntry(i))
                                      const Text(
                                        'Радио после плейлиста',
                                        style: TextStyle(
                                          color: accent,
                                          fontSize: 10,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    PopupMenuButton<String>(
                      key: ValueKey('queue-actions-$entry'),
                      tooltip: 'Порядок трека',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: const Icon(Icons.more_vert_rounded, color: muted),
                      onSelected: (action) => unawaited(
                        p.moveQueue(i, action == 'up' ? i - 1 : i + 1),
                      ),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'up',
                          enabled: i > 0,
                          child: const Text('Выше в очереди'),
                        ),
                        PopupMenuItem(
                          value: 'down',
                          enabled: i < queue.length - 1,
                          child: const Text('Ниже в очереди'),
                        ),
                      ],
                    ),
                    IconButton(
                      onPressed: () => p.removeQueue(i),
                      tooltip: 'Убрать из очереди',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: muted,
                      ),
                    ),
                    ReorderableDragStartListener(
                      key: ValueKey('queue-drag-$entry'),
                      index: i,
                      child: Tooltip(
                        message: 'Переместить трек',
                        child: Semantics(
                          label: 'Переместить трек',
                          child: const MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: Icon(
                                Icons.drag_handle_rounded,
                                color: muted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
  }
}

class _Lyrics extends StatelessWidget {
  const _Lyrics(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final text = app.playback.current?.lyrics?.trim();
    return text == null || text.isEmpty
        ? const EmptyState(
            icon: Icons.lyrics_outlined,
            title: 'Текста пока нет',
            description:
                'Если текст песни записан в тегах файла, он появится здесь. Для торрент-трека теги читаются после полной загрузки.',
          )
        : SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: SelectableText(
              text.replaceAll(RegExp(r'\[\d{2}:\d{2}(\.\d{1,3})?\]'), ''),
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                height: 1.8,
              ),
            ),
          );
  }
}
