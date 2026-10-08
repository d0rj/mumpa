import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../logic/app_controller.dart';
import '../logic/playback_controller.dart';
import 'components.dart';
import 'theme.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.app, required this.compact});
  final AppController app;
  final bool compact;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app.playback,
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
                      CoverArt(
                        seed: t?.album ?? 'Mumpa',
                        path: t?.artPath,
                        size: 42,
                        radius: 6,
                      ),
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
                            Text(
                              t?.artist ?? 'Музыка всегда рядом',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
                        tooltip: p.playing ? 'Пауза' : 'Слушать',
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
                        onPressed: p.queue.isEmpty ? null : p.next,
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
                child: LinearProgressIndicator(
                  minHeight: 2,
                  value: p.duration.inMilliseconds > 0
                      ? (p.position.inMilliseconds / p.duration.inMilliseconds)
                            .clamp(0, 1)
                      : 0,
                  backgroundColor: Colors.white.withValues(alpha: .07),
                  color: accent,
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
                    child: CoverArt(
                      seed: t?.album ?? 'Mumpa',
                      path: t?.artPath,
                      size: 58,
                    ),
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
                          Text(
                            t?.artist ?? 'Твоя музыка всегда рядом',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10, color: muted),
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
                        app.library.liked.contains(t.id)
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 18,
                        color: app.library.liked.contains(t.id)
                            ? accent
                            : muted,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [_Transport(p), _SeekBar(p)],
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: () => showNowPlaying(context, app, tab: 1),
                    tooltip: 'Очередь',
                    icon: const Icon(
                      Icons.queue_music_rounded,
                      size: 20,
                      color: muted,
                    ),
                  ),
                  IconButton(
                    onPressed: () => showNowPlaying(context, app, tab: 2),
                    tooltip: 'Текст песни',
                    icon: const Icon(
                      Icons.lyrics_outlined,
                      size: 18,
                      color: muted,
                    ),
                  ),
                  IconButton(
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
                  SizedBox(
                    width: 60,
                    child: Slider(
                      value: p.volume.clamp(0, 1),
                      onChanged: p.setVolume,
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
        onPressed: p.queue.isEmpty ? null : p.previous,
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
          tooltip: p.playing ? 'Пауза' : 'Слушать',
          style: IconButton.styleFrom(
            backgroundColor: large ? accent : Colors.white,
            foregroundColor: Colors.black,
            padding: EdgeInsets.zero,
          ),
          icon: p.buffering
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.black,
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
        onPressed: p.queue.isEmpty ? null : p.next,
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
  const _SeekBar(this.player);
  final PlaybackController player;
  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? drag;
  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final max = p.duration.inMilliseconds.toDouble();
    final value = drag ?? p.position.inMilliseconds.toDouble().clamp(0, max);
    return Row(
      children: [
        Text(
          formatTime(Duration(milliseconds: value.toInt())),
          style: const TextStyle(color: muted, fontSize: 10),
        ),
        Expanded(
          child: Slider(
            value: max > 0 ? value.clamp(0, max) : 0,
            max: max > 0 ? max : 1,
            onChanged: max > 0 ? (value) => setState(() => drag = value) : null,
            onChangeEnd: (value) {
              p.seek(Duration(milliseconds: value.toInt()));
              setState(() => drag = null);
            },
          ),
        ),
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
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: surface,
    constraints: const BoxConstraints(maxWidth: 850),
    builder: (context) => SizedBox(
      height: MediaQuery.sizeOf(context).height * .94,
      child: DefaultTabController(
        length: 3,
        initialIndex: tab,
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
            const TabBar(
              tabs: [
                Tab(text: 'Плеер'),
                Tab(text: 'Очередь'),
                Tab(text: 'Текст'),
              ],
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: app.playback,
                builder: (context, _) => TabBarView(
                  children: [_NowPlaying(app), _Queue(app), _Lyrics(app)],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final p = app.playback;
    final t = p.current;
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: CoverArt(
                    seed: t?.album ?? 'Mumpa',
                    path: t?.artPath,
                    size: (c.maxHeight * .5).clamp(150, 340),
                    radius: 16,
                  ),
                ),
                const SizedBox(height: 26),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t?.title ?? 'Выбери трек',
                            maxLines: 2,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            t?.artist ?? 'Музыка всегда рядом',
                            style: const TextStyle(color: muted),
                          ),
                        ],
                      ),
                    ),
                    if (t != null)
                      IconButton(
                        onPressed: () => app.library.toggleLike(t.id),
                        icon: Icon(
                          app.library.liked.contains(t.id)
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: accent,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _SeekBar(p),
                const SizedBox(height: 12),
                _Transport(p, large: true),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    BadgePill(
                      icon: t?.offline == true
                          ? Icons.offline_bolt_rounded
                          : Icons.wifi_rounded,
                      label: t?.offline == true
                          ? 'ЛОКАЛЬНЫЙ ФАЙЛ'
                          : 'ТОРРЕНТ-ПОТОК',
                    ),
                    PopupMenuButton<int>(
                      tooltip: 'Таймер сна',
                      icon: Icon(
                        Icons.bedtime_outlined,
                        color: p.sleepUntil != null ? accent : muted,
                        size: 22,
                      ),
                      onSelected: (minutes) => p.setSleep(
                        minutes == 0 ? null : Duration(minutes: minutes),
                      ),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 15,
                          child: Text('Выключить через 15 мин'),
                        ),
                        PopupMenuItem(
                          value: 30,
                          child: Text('Выключить через 30 мин'),
                        ),
                        PopupMenuItem(
                          value: 60,
                          child: Text('Выключить через час'),
                        ),
                        PopupMenuItem(
                          value: 0,
                          child: Text('Отключить таймер'),
                        ),
                      ],
                    ),
                  ],
                ),
                if (p.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      p.error!,
                      style: const TextStyle(
                        color: Color(0xFFFF9292),
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Queue extends StatelessWidget {
  const _Queue(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final p = app.playback;
    final queue = p.queue;
    return queue.isEmpty
        ? const EmptyState(
            icon: Icons.queue_music_rounded,
            title: 'Очередь пуста',
            description: 'Включи альбом или добавь треки через меню.',
          )
        : ListView.builder(
            padding: const EdgeInsets.all(18),
            itemCount: queue.length,
            itemBuilder: (context, i) {
              final t = queue[i];
              return ListTile(
                onTap: () => p.jump(i),
                leading: CoverArt(seed: t.album, path: t.artPath, size: 44),
                title: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: i == p.index ? accent : Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  t.artist,
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
                trailing: IconButton(
                  onPressed: () => p.removeQueue(i),
                  tooltip: 'Убрать из очереди',
                  icon: const Icon(Icons.close_rounded, size: 18, color: muted),
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
    final text = app.playback.current?.lyrics;
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
