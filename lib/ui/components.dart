import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../data/download_repository.dart';
import '../domain/models.dart';
import '../logic/app_controller.dart';
import 'theme.dart';

class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    this.path,
    required this.seed,
    this.size = 64,
    this.radius = 8,
  });
  final String? path;
  final String seed;
  final double size, radius;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: SizedBox(
      width: size,
      height: size,
      child: path == null
          ? CustomPaint(painter: _CoverPainter(seed))
          : Image.file(
              File(path!),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  CustomPaint(painter: _CoverPainter(seed)),
            ),
    ),
  );
}

class _CoverPainter extends CustomPainter {
  _CoverPainter(this.seed);
  final String seed;
  static const palettes = [
    [Color(0xFF7FB999), Color(0xFF0E4334)],
    [Color(0xFFED9866), Color(0xFF613839)],
    [Color(0xFF8D88BE), Color(0xFF373453)],
    [Color(0xFFB4C770), Color(0xFF4D5E24)],
    [Color(0xFF73B3C6), Color(0xFF204B63)],
    [Color(0xFFDD91B6), Color(0xFF602C55)],
  ];
  @override
  void paint(Canvas canvas, Size size) {
    final hash = seed.codeUnits.fold<int>(
      0,
      (a, b) => (a * 31 + b) & 0x7fffffff,
    );
    final colors = palettes[hash % palettes.length];
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(rect),
    );
    canvas.save();
    canvas.clipRect(rect);
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .015;
    final center = Offset(size.width * .67, size.height * .45);
    for (var i = 0; i < 10; i++) {
      canvas.drawCircle(center, size.width * (.08 + i * .05), paint);
    }
    final wave = Path();
    for (var i = 0; i <= 100; i++) {
      final x = i / 100 * size.width;
      final y =
          size.height *
          (.65 + math.sin(i * .08 + hash) * .08 + math.sin(i * .2) * .03);
      if (i == 0) {
        wave.moveTo(x, y);
      } else {
        wave.lineTo(x, y);
      }
    }
    canvas.drawPath(
      wave,
      Paint()
        ..color = Colors.white.withValues(alpha: .8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * .013,
    );
    final text = TextPainter(
      text: TextSpan(
        text: seed.isEmpty ? 'M' : seed.substring(0, 1).toUpperCase(),
        style: TextStyle(
          color: Colors.white.withValues(alpha: .9),
          fontSize: size.width * .3,
          fontFamily: 'Manrope',
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset(size.width * .1, size.height * .08));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CoverPainter old) => old.seed != seed;
}

class AlbumCard extends StatefulWidget {
  const AlbumCard({
    super.key,
    required this.album,
    required this.onOpen,
    required this.onPlay,
  });
  final Album album;
  final VoidCallback onOpen, onPlay;
  @override
  State<AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<AlbumCard> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => hovered = true),
    onExit: (_) => setState(() => hovered = false),
    child: InkWell(
      onTap: widget.onOpen,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: hovered ? const Color(0xFF262D25) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (_, c) => Stack(
                  children: [
                    Positioned.fill(
                      child: CoverArt(
                        seed: widget.album.title,
                        path: widget.album.artPath,
                        size: c.maxWidth,
                        radius: 10,
                      ),
                    ),
                    if (widget.album.offline)
                      const Positioned(
                        left: 9,
                        top: 9,
                        child: BadgePill(
                          icon: Icons.download_done_rounded,
                          label: 'Офлайн',
                        ),
                      ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: AnimatedOpacity(
                        opacity: hovered ? 1 : .85,
                        duration: const Duration(milliseconds: 150),
                        child: IconButton.filled(
                          onPressed: widget.onPlay,
                          tooltip: 'Слушать альбом',
                          icon: const Icon(Icons.play_arrow_rounded),
                          style: IconButton.styleFrom(
                            backgroundColor: accent,
                            foregroundColor: const Color(0xFF162008),
                            minimumSize: const Size(42, 42),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 3),
            Text(
              widget.album.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );
}

class BadgePill extends StatelessWidget {
  const BadgePill({super.key, required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .58),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: accent),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.subtitle, this.action});
  final String title;
  final String? subtitle;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
            ],
          ),
        ),
        ?action,
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });
  final IconData icon;
  final String title, description;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: accent),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted),
            ),
            if (action != null) ...[const SizedBox(height: 22), action!],
          ],
        ),
      ),
    ),
  );
}

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
  });
  final AppController app;
  final List<Track> tracks;
  final String? playlistId;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app.playback,
    builder: (_, _) => SliverList.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        final active = app.playback.current?.id == t.id;
        final downloading = app.downloads.jobs
            .where(
              (j) => j.track.id == t.id && j.state == DownloadState.downloading,
            )
            .firstOrNull;
        return LayoutBuilder(
          builder: (context, c) => InkWell(
            key: ValueKey('track-row-${t.id}'),
            onTap: () =>
                app.playCollection(tracks, index: i, playlistId: playlistId),
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
                        ? Icon(
                            app.playback.playing
                                ? Icons.graphic_eq
                                : app.playback.stopped
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                            size: 18,
                            color: accent,
                          )
                        : Text(
                            '${i + 1}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: muted),
                          ),
                  ),
                  CoverArt(seed: t.album, path: t.artPath, size: 42, radius: 5),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: active ? accent : Colors.white,
                          ),
                        ),
                        Text(
                          t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                    ),
                  if (c.maxWidth > 500)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        t.format,
                        style: const TextStyle(fontSize: 10, color: muted),
                      ),
                    ),
                  if (t.offline)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(
                        Icons.download_done_rounded,
                        size: 14,
                        color: accent,
                      ),
                    ),
                  if (downloading != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Tooltip(
                        message: 'Сохраняется для офлайн',
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            value: downloading.progress,
                          ),
                        ),
                      ),
                    ),
                  IconButton(
                    onPressed: () => app.library.toggleLike(t.id),
                    tooltip: app.library.liked.contains(t.id)
                        ? 'Убрать из любимого'
                        : 'В любимое',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      app.library.liked.contains(t.id)
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      size: 19,
                      color: app.library.liked.contains(t.id) ? accent : muted,
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
