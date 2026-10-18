import 'dart:io';
import 'package:path/path.dart' as p;
import '../domain/models.dart';
import '../domain/music_metadata.dart';
import 'media_cache.dart';
import 'source_operation.dart';
import 'torrent_metainfo.dart';
import 'torrent_service.dart';
import 'public_music_catalog.dart';

class TrackSearchService {
  TrackSearchService({
    required this.indexer,
    required this.torrents,
    required this.cache,
    required this.workDirectory,
  });
  final IndexerService indexer;
  final TorrentService torrents;
  final DiskMediaCache cache;
  final Directory workDirectory;

  Future<List<TrackVariant>> find(
    MusicRecording recording, {
    required String endpoint,
    required String key,
    required SourceOperation operation,
    void Function(String)? onStatus,
    void Function(List<TrackVariant>)? onResults,
  }) async {
    final generation = cache.generation;
    final releases = <String, SearchRelease>{};
    final artist = recording.catalogArtist;
    final queries = recording.albumTitles
        .take(2)
        .map((title) => '$artist $title')
        .toSet();
    if (queries.isEmpty) queries.add(artist);
    for (final query in queries) {
      operation.check();
      onStatus?.call('Ищем раздачи: $query');
      final found = await indexer.search(
        endpoint,
        key,
        query,
        operation: operation,
      );
      for (final release in found) {
        releases[release.link] = release;
      }
    }
    if (releases.isEmpty && !queries.contains(artist)) {
      onStatus?.call('Ищем коллекции исполнителя: $artist');
      for (final release in await indexer.search(
        endpoint,
        key,
        artist,
        operation: operation,
      )) {
        releases[release.link] = release;
      }
    }
    final candidates = releases.values.toList()
      ..sort((a, b) {
        int relevance(SearchRelease r) =>
            recording.albumTitles.any(
              (album) => normalizeMusicName(
                r.title,
              ).contains(normalizeMusicName(album)),
            )
            ? 1
            : 0;
        final related = relevance(b).compareTo(relevance(a));
        return related == 0 ? b.seeders.compareTo(a.seeders) : related;
      });
    // Give different formats a place even when one format has many mirrors.
    final selected = <SearchRelease>[];
    final formats = <String>{};
    for (final release in candidates) {
      if (formats.add(describeReleaseFormats(release.title))) {
        selected.add(release);
      }
    }
    for (final release in candidates) {
      if (!selected.contains(release)) selected.add(release);
    }
    final limited = selected.take(12).toList();
    final variants = <TrackVariant>[];
    var cursor = 0, inspected = 0, failed = 0;
    Future<void> worker() async {
      while (cursor < limited.length) {
        operation.check();
        final release = limited[cursor++];
        onStatus?.call(
          'Проверяем файлы коллекций · ${inspected + 1}/${limited.length}',
        );
        Directory? temporary;
        try {
          final cacheKey = 'torrentmeta:${release.link}';
          var source = await cache.pathFor(cacheKey);
          TorrentInfo? magnetInfo;
          if (source == null) {
            await workDirectory.create(recursive: true);
            temporary = await workDirectory.createTemp('inspect-');
            final result = await indexer.resolve(
              release.link,
              temporary,
              operation: operation,
              preferCachedMetainfo: endpoint == PublicMusicCatalog.endpoint,
            );
            operation.check();
            if (!result.file) {
              source = result.source;
              magnetInfo = await torrents.add(source, operation: operation);
            } else {
              final bytes = await File(result.source).readAsBytes();
              // Validate before retaining external metainfo.
              readTorrentMetainfo(bytes);
              source = await cache.put(
                cacheKey,
                bytes,
                extension: 'torrent',
                ttl: const Duration(days: 7),
                expectedGeneration: generation,
              );
            }
          }
          operation.check();
          if (source == null) continue;
          final info =
              magnetInfo ??
              readTorrentMetainfo(await File(source).readAsBytes());
          final identity = parseReleaseIdentity(release.title);
          final tracks = torrents.tracks(
            info,
            album: identity?.album ?? release.title,
            artist: artist,
            link: release.link,
          );
          for (final track in tracks) {
            if (!matchesRecordingFilename(track.torrentPath!, recording)) {
              continue;
            }
            variants.add(
              TrackVariant(
                release: release,
                track: track,
                info: info,
                source: source,
                edition: describeEdition('${release.title} ${track.title}'),
              ),
            );
          }
          onResults?.call(List.unmodifiable(variants));
        } on SourceCancelled {
          rethrow;
        } catch (_) {
          failed++;
        } finally {
          inspected++;
          if (temporary != null &&
              p.isWithin(workDirectory.path, temporary.path)) {
            await temporary.delete(recursive: true);
          }
        }
      }
    }

    await Future.wait([worker(), worker()]);
    operation.check();
    onStatus?.call(
      'Проверено коллекций: $inspected${failed == 0 ? '' : ' · недоступны: $failed'}'
      '${candidates.length > limited.length ? ' · показаны первые 12' : ''}',
    );
    return List.unmodifiable(variants);
  }
}
