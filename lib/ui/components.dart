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
    this.imageProvider,
    required this.seed,
    this.size = 64,
    this.radius = 8,
  });
  final String? path;
  final ImageProvider<Object>? imageProvider;
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
          : Image(
              image: imageProvider ?? FileImage(File(path!)),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  CustomPaint(painter: _CoverPainter(seed)),
            ),
    ),
  );
}

bool hasArtistPage(String artist) {
  final name = artist.trim().toLowerCase();
  return name.isNotEmpty &&
      !const {
        'неизвестный исполнитель',
        'неизвестен',
        'unknown artist',
        'unknown',
      }.contains(name);
}

class ArtistLink extends StatelessWidget {
  const ArtistLink({
    super.key,
    required this.artist,
    required this.onOpen,
    this.style = const TextStyle(color: muted, fontSize: 12),
    this.maxLines = 1,
  });

  final String artist;
  final VoidCallback? onOpen;
  final TextStyle style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final open = hasArtistPage(artist) ? onOpen : null;
    return Semantics(
      button: open != null,
      label: open == null ? null : 'Исполнитель $artist',
      child: InkWell(
        onTap: open,
        borderRadius: BorderRadius.circular(3),
        mouseCursor: open == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: Text(
          artist,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
  }
}

class AsyncCoverArt extends StatefulWidget {
  const AsyncCoverArt({
    super.key,
    required this.requestKey,
    required this.load,
    required this.seed,
    this.path,
    this.size = 64,
    this.radius = 8,
  });

  final String requestKey, seed;
  final Future<String?> Function() load;
  final String? path;
  final double size, radius;

  @override
  State<AsyncCoverArt> createState() => _AsyncCoverArtState();
}

class TrackArtwork extends StatelessWidget {
  const TrackArtwork({
    super.key,
    required this.app,
    this.track,
    this.size = 64,
    this.radius = 8,
  });

  final AppController app;
  final Track? track;
  final double size, radius;

  @override
  Widget build(BuildContext context) {
    final value = track;
    if (value == null) {
      return CoverArt(seed: 'Mumpa', size: size, radius: radius);
    }
    final artist = value.albumArtist?.trim().isNotEmpty == true
        ? value.albumArtist!
        : value.artist;
    return AsyncCoverArt(
      requestKey:
          '${app.metadata.cache.generation}:album:$artist:${value.album}:${value.torrentHash}:${value.torrentAlbumPath}',
      load: () => app.loadTrackArtwork(value),
      seed: value.album,
      path: app.artworkForTrack(value),
      size: size,
      radius: radius,
    );
  }
}

class AlbumArtwork extends StatelessWidget {
  const AlbumArtwork({
    super.key,
    required this.app,
    required this.album,
    this.size = 64,
    this.radius = 8,
  });

  final AppController app;
  final Album album;
  final double size, radius;

  @override
  Widget build(BuildContext context) => AsyncCoverArt(
    requestKey:
        '${app.metadata.cache.generation}:album:${album.artist}:${album.title}:${album.tracks.first.torrentHash}:${album.tracks.first.torrentAlbumPath}',
    load: () => app.loadTrackArtwork(album.tracks.first),
    seed: album.title,
    path: album.artPath ?? app.artworkForTrack(album.tracks.first),
    size: size,
    radius: radius,
  );
}

class _AsyncCoverArtState extends State<AsyncCoverArt> {
  late Future<_CoverArtifact?> _cover;

  Future<_CoverArtifact?> _loadCover() async {
    final requestKey = widget.requestKey;
    final path = await widget.load();
    if (path == null) return null;
    // Keep I/O out of build. A new lookup reads the file revision once, so a
    // refreshed TTL entry at the same path cannot reuse old decoded pixels.
    final stat = await File(path).stat();
    return _CoverArtifact(
      path,
      _RevisionFileImage(
        File(path),
        requestKey: requestKey,
        modified: stat.modified.microsecondsSinceEpoch,
        bytes: stat.size,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _cover = widget.path != null ? Future.value(null) : _loadCover();
  }

  @override
  void didUpdateWidget(AsyncCoverArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.requestKey != widget.requestKey ||
        oldWidget.path != widget.path) {
      _cover = widget.path != null ? Future.value(null) : _loadCover();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_CoverArtifact?>(
    key: ValueKey(widget.requestKey),
    future: _cover,
    builder: (_, snapshot) => CoverArt(
      seed: widget.seed,
      path: widget.path ?? snapshot.data?.path,
      imageProvider: widget.path == null ? snapshot.data?.imageProvider : null,
      size: widget.size,
      radius: widget.radius,
    ),
  );
}

class _CoverArtifact {
  const _CoverArtifact(this.path, this.imageProvider);
  final String path;
  final ImageProvider<Object> imageProvider;
}

/// FileImage normally keys decoded pixels by path and scale alone. Include the
/// lookup generation and asynchronous stat revision without evicting unrelated
/// covers or re-reading the disk on every player update.
class _RevisionFileImage extends FileImage {
  const _RevisionFileImage(
    super.file, {
    required this.requestKey,
    required this.modified,
    required this.bytes,
  });

  final String requestKey;
  final int modified, bytes;

  @override
  bool operator ==(Object other) =>
      other is _RevisionFileImage &&
      other.file.path == file.path &&
      other.scale == scale &&
      other.requestKey == requestKey &&
      other.modified == modified &&
      other.bytes == bytes;

  @override
  int get hashCode =>
      Object.hash(file.path, scale, requestKey, modified, bytes);
}

/// A decorative playback indicator; its motion follows the player state.
class PlayingIndicator extends StatefulWidget {
  const PlayingIndicator({
    super.key,
    required this.playing,
    this.size = 20,
    this.color = accent,
  });

  final bool playing;
  final double size;
  final Color color;

  @override
  State<PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<PlayingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(PlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.playing && !_reduceMotion) {
      if (!_animation.isAnimating) _animation.repeat();
    } else {
      _animation.stop();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.playing ? 'Сейчас играет' : 'На паузе',
    child: SizedBox.square(
      dimension: widget.size,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _EqualizerPainter(
            animation: _animation,
            color: widget.color,
            animated: widget.playing && !_reduceMotion,
          ),
        ),
      ),
    ),
  );
}

class _EqualizerPainter extends CustomPainter {
  _EqualizerPainter({
    required this.animation,
    required this.color,
    required this.animated,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final bool animated;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width * .12;
    final gap = size.width * .075;
    final left = (size.width - width * 5 - gap * 4) / 2;
    final paint = Paint()..color = color;
    for (var i = 0; i < 5; i++) {
      final phase = i * 1.13;
      final pulse = animated
          ? (math.sin(animation.value * math.pi * 2 * (i % 3 + 1) + phase) +
                    1) /
                2
          : const [.35, .7, 1.0, .6, .3][i];
      final height = size.height * (.18 + .72 * pulse);
      final x = left + i * (width + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - height) / 2, width, height),
          Radius.circular(width / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_EqualizerPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.animated != animated;
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
    this.onArtist,
    this.app,
  });
  final Album album;
  final VoidCallback onOpen, onPlay;
  final VoidCallback? onArtist;
  final AppController? app;
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
                      child: widget.app == null
                          ? CoverArt(
                              seed: widget.album.title,
                              path: widget.album.artPath,
                              size: c.maxWidth,
                              radius: 10,
                            )
                          : AlbumArtwork(
                              app: widget.app!,
                              album: widget.album,
                              size: c.maxWidth,
                              radius: 10,
                            ),
                    ),
                    if (widget.album.offline)
                      Positioned(
                        left: 9,
                        right: widget.app == null ? null : 54,
                        top: 9,
                        child: const BadgePill(
                          icon: Icons.download_done_rounded,
                          label: 'Офлайн',
                        ),
                      ),
                    if (widget.app != null)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: AlbumFavoriteButton(
                          app: widget.app!,
                          album: widget.album,
                          overlay: true,
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
            ArtistLink(artist: widget.album.artist, onOpen: widget.onArtist),
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
        Flexible(
          child: Tooltip(
            message: label,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class AlbumFavoriteButton extends StatelessWidget {
  const AlbumFavoriteButton({
    super.key,
    required this.app,
    required this.album,
    this.label = false,
    this.overlay = false,
  });

  final AppController app;
  final Album album;
  final bool label, overlay;

  @override
  Widget build(BuildContext context) {
    final liked = app.library.isAlbumLiked(album);
    final icon = Icon(
      liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      color: liked
          ? accent
          : overlay
          ? Colors.white
          : muted,
      size: 20,
    );
    final key = ValueKey('favorite-album-${album.id}');
    final description = liked
        ? 'Убрать альбом из любимого'
        : 'Добавить альбом в любимое';
    return label
        ? OutlinedButton.icon(
            key: key,
            onPressed: () => app.library.toggleAlbumLike(album),
            icon: icon,
            label: Text(liked ? 'В любимом' : 'В любимое'),
          )
        : IconButton(
            key: key,
            onPressed: () => app.library.toggleAlbumLike(album),
            tooltip: description,
            icon: icon,
            style: overlay
                ? IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: .65),
                  )
                : null,
          );
  }
}

class PlaylistFavoriteButton extends StatelessWidget {
  const PlaylistFavoriteButton({
    super.key,
    required this.app,
    required this.playlistId,
    this.label = false,
  });

  final AppController app;
  final String playlistId;
  final bool label;

  @override
  Widget build(BuildContext context) {
    final liked = app.library.isPlaylistLiked(playlistId);
    final icon = Icon(
      liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      color: liked ? accent : muted,
      size: 20,
    );
    final description = liked ? 'Убрать из любимого' : 'В любимое';
    return label
        ? OutlinedButton.icon(
            key: ValueKey('favorite-playlist-$playlistId'),
            onPressed: () => app.library.togglePlaylistLike(playlistId),
            icon: icon,
            label: Text(liked ? 'В любимом' : 'В любимое'),
          )
        : IconButton(
            key: ValueKey('favorite-playlist-$playlistId'),
            onPressed: () => app.library.togglePlaylistLike(playlistId),
            tooltip: description,
            icon: icon,
          );
  }
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
    this.queueTracks,
  });
  final AppController app;
  final List<Track> tracks;
  final List<Track>? queueTracks;
  final String? playlistId;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      app.playback.trackState,
      app.library,
      app.downloads,
      app,
    ]),
    builder: (_, _) => SliverList.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = app.library.byId(tracks[i].id) ?? tracks[i];
        final active = app.playback.current?.id == t.id;
        final downloading = app.downloads.jobs
            .where(
              (j) => j.track.id == t.id && j.state == DownloadState.downloading,
            )
            .firstOrNull;
        return LayoutBuilder(
          builder: (context, c) => InkWell(
            key: ValueKey('track-row-${t.id}'),
            onTap: () {
              final queue = queueTracks ?? tracks;
              final index = queue.indexWhere((item) => item.id == t.id);
              if (index < 0) return;
              app.playCollection(queue, index: index, playlistId: playlistId);
            },
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
                        ? Center(
                            child: app.playback.stopped
                                ? const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 18,
                                    color: accent,
                                  )
                                : PlayingIndicator(
                                    key: ValueKey('playing-wave-${t.id}'),
                                    playing: app.playback.playing,
                                    size: 20,
                                  ),
                          )
                        : Text(
                            '${i + 1}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: muted),
                          ),
                  ),
                  TrackArtwork(app: app, track: t, size: 42, radius: 5),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.title,
                          key: ValueKey('track-title-${t.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: active ? accent : Colors.white,
                          ),
                        ),
                        ArtistLink(
                          artist: t.artist,
                          onOpen: () => app.openArtist(t.artist),
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
                        key: ValueKey('track-album-${t.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                    ),
                  if (c.maxWidth > 500)
                    SizedBox(
                      width: 64,
                      child: Text(
                        t.format,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 10, color: muted),
                      ),
                    ),
                  SizedBox(
                    key: ValueKey('track-status-${t.id}'),
                    width: 28,
                    height: 22,
                    child: Center(
                      child: t.offline
                          ? const Tooltip(
                              message: 'Доступен офлайн',
                              child: Icon(
                                Icons.download_done_rounded,
                                size: 14,
                                color: accent,
                              ),
                            )
                          : downloading != null
                          ? Tooltip(
                              message: 'Сохраняется для офлайн',
                              child: SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  value: downloading.progress,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  IconButton(
                    onPressed: () => app.library.toggleLike(t.id),
                    tooltip: app.library.isTrackLiked(t.id)
                        ? 'Убрать из любимого'
                        : 'В любимое',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      app.library.isTrackLiked(t.id)
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      size: 19,
                      color: app.library.isTrackLiked(t.id) ? accent : muted,
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
                      if (hasArtistPage(t.artist))
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
