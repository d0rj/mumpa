part of 'components.dart';

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
      label: open == null ? null : tr("Исполнитель {0}", [artist]),
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

class AlbumLink extends StatelessWidget {
  const AlbumLink({
    super.key,
    required this.album,
    required this.onOpen,
    this.style = const TextStyle(color: muted, fontSize: 12),
  });

  final String album;
  final VoidCallback onOpen;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: tr("Открыть альбом {0}", [album]),
    child: Tooltip(
      message: tr("Перейти к альбому"),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(3),
        child: Text(
          album,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    ),
  );
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
    label: widget.playing ? tr("Сейчас играет") : tr("На паузе"),
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
