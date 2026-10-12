import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../data/download_repository.dart';
import '../domain/models.dart';
import '../domain/music_metadata.dart';
import '../domain/track_matching.dart';
import '../logic/app_controller.dart';
import 'theme.dart';

part 'artwork.dart';
part 'track_list.dart';
part 'track_versions.dart';

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
