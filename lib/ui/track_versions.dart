part of 'components.dart';

/// A distinct play target sits on the front cover; clicking the rest of a
/// grouped row opens the version picker without opening the decoder.
class TrackStackArtwork extends StatelessWidget {
  const TrackStackArtwork({
    super.key,
    required this.app,
    required this.track,
    required this.variants,
    required this.rowId,
    required this.onPlay,
  });
  final AppController app;
  final Track track;
  final List<Track> variants;
  final String rowId;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final behind = variants
        .where((item) => item.id != track.id)
        .take(2)
        .toList();
    return SizedBox(
      width: 52,
      height: 50,
      child: Stack(
        key: ValueKey('track-cover-stack-$rowId'),
        children: [
          for (var i = behind.length - 1; i >= 0; i--)
            Positioned(
              left: (i + 1) * 4,
              top: (i + 1) * 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(6),
                ),
                // Existing pixels/fallback suffice behind the front cover;
                // a stack never starts artwork requests for hidden versions.
                child: CoverArt(
                  key: ValueKey('track-cover-layer-${behind[i].id}'),
                  seed: behind[i].album,
                  path: app.artworkForTrack(behind[i]),
                  size: 40,
                  radius: 5,
                ),
              ),
            ),
          Positioned(
            left: 0,
            top: 0,
            child: TrackArtwork(app: app, track: track, size: 42, radius: 5),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: IconButton(
              key: ValueKey('track-cover-play-$rowId'),
              onPressed: onPlay,
              tooltip: 'Слушать ${track.title}',
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
              padding: EdgeInsets.zero,
              icon: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Color(0xCC162008),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  size: 24,
                  color: accent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<Track?> showKnownTrackVersions(
  BuildContext context,
  AppController app,
  MatchedTrack row,
) {
  return showDialog<Track>(
    context: context,
    builder: (context) => _KnownTrackVersions(app: app, row: row),
  );
}

class _KnownTrackVersions extends StatelessWidget {
  const _KnownTrackVersions({required this.app, required this.row});
  final AppController app;
  final MatchedTrack row;

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 660,
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.layers_rounded, color: accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Выбрать версию',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  key: const ValueKey('track-versions-close'),
                  onPressed: () => Navigator.pop(context),
                  tooltip: 'Закрыть',
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              '${row.anchor.artist} · ${row.anchor.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            const Text(
              'Только уже известные файлы. Совпадение по метаданным; аудио не сравнивалось. '
              'Звёздочка запоминает версию для play на обложке. Без выбора приоритет у офлайн-копии.',
              style: TextStyle(fontSize: 11, color: muted),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListenableBuilder(
                listenable: app.library,
                builder: (_, _) => ListView.separated(
                  shrinkWrap: true,
                  itemCount: row.group.variants.length,
                  separatorBuilder: (_, _) => const Divider(height: 16),
                  itemBuilder: (context, index) {
                    final original = row.group.variants[index];
                    final track = app.library.byId(original.id);
                    if (track == null) return const SizedBox.shrink();
                    final source = track.source == TrackSource.torrent
                        ? app.library.playlists
                                  .where(
                                    (playlist) =>
                                        playlist.sourceHash ==
                                        track.torrentHash,
                                  )
                                  .firstOrNull
                                  ?.name ??
                              track.album
                        : track.source == TrackSource.demo
                        ? 'Демо'
                        : 'Локальный файл';
                    final path = track.torrentPath ?? track.localPath ?? '';
                    final file = path.replaceAll('\\', '/').split('/').last;
                    final preferred = app.library.isPreferredVariant(track.id);
                    final edition = describeEdition(
                      '${track.title} ${track.album} $source $file',
                    );
                    return Material(
                      color: const Color(0xFF242D25),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        key: ValueKey('known-version-${track.id}'),
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => Navigator.pop(context, track),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TrackArtwork(
                                app: app,
                                track: track,
                                size: 42,
                                radius: 5,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${trackFormatDescription(track)} · ${track.durationMs > 0 ? formatTime(track.duration) : 'Длительность неизвестна'}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '$edition${track.offline ? ' · Офлайн' : ''}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: muted,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      track.album,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    Text(
                                      '$source${track.torrentHash == null ? '' : ' · ${track.torrentHash!.substring(0, math.min(8, track.torrentHash!.length))}'}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: muted,
                                      ),
                                    ),
                                    if (file.isNotEmpty)
                                      Text(
                                        file,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: muted,
                                        ),
                                      ),
                                    if (track.bytes > 0)
                                      Text(
                                        formatBytes(track.bytes),
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: muted,
                                        ),
                                      ),
                                    Wrap(
                                      children: [
                                        IconButton(
                                          key: ValueKey(
                                            'prefer-version-${track.id}',
                                          ),
                                          tooltip: preferred
                                              ? 'Версия по умолчанию'
                                              : 'Выбрать по умолчанию',
                                          onPressed: () => app.library
                                              .preferTrackVariant(track.id),
                                          icon: Icon(
                                            preferred
                                                ? Icons.star_rounded
                                                : Icons.star_border_rounded,
                                            color: preferred ? accent : muted,
                                            size: 20,
                                          ),
                                        ),
                                        TextButton(
                                          key: ValueKey(
                                            'separate-version-${track.id}',
                                          ),
                                          onPressed: () async {
                                            await app.library
                                                .setTrackMatchExcluded(
                                                  track.id,
                                                  true,
                                                );
                                            if (context.mounted) {
                                              Navigator.pop(context);
                                            }
                                          },
                                          child: const Text(
                                            'Это другой трек',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                key: ValueKey('play-known-version-${track.id}'),
                                onPressed: () => Navigator.pop(context, track),
                                tooltip: 'Слушать эту версию',
                                icon: const Icon(
                                  Icons.play_circle_fill_rounded,
                                  color: accent,
                                  size: 30,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
