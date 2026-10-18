import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../domain/models.dart';
import '../domain/collection_filter.dart';
import '../domain/music_metadata.dart';
import 'library_repository.dart';
import 'music_metadata_repository.dart';
import 'rutracker_service.dart';
import 'similar_artists_repository.dart';
import 'source_operation.dart';
import 'public_music_catalog.dart';
import 'torrent_metainfo.dart';
import 'torrent_service.dart';

String radioArtist(Track track) => track.albumArtist?.trim().isNotEmpty == true
    ? track.albumArtist!
    : track.artist;
String _normalizedRadioArtist(Track track) {
  final names = normalizedTrackArtistNames(track);
  return names[1].isEmpty ? names[0] : names[1];
}

String radioSongKey(Track track) =>
    '${_normalizedRadioArtist(track)}\u0000${normalizedTrackTitle(track)}';

class PreparedRadioTrack {
  const PreparedRadioTrack(this.track, this.uri);
  final Track track;
  final Uri uri;
}

abstract class RadioSource {
  Stream<Track> candidates(
    List<Track> seeds,
    Set<String> excluded,
    SourceOperation operation,
  );
  Future<PreparedRadioTrack> prepare(Track track, SourceOperation operation);
}

/// Bounded discovery, using existing catalogues and metainfo, never a crawl.
class RadioRepository implements RadioSource {
  RadioRepository({
    required this.library,
    required this.torrents,
    required this.metadata,
    required this.similar,
    required this.indexer,
    required this.catalog,
    Random? random,
    this.sourceTimeout = const Duration(seconds: 25),
    this.audioTimeout = const Duration(seconds: 8),
  }) : random = random ?? Random();

  final LibraryRepository library;
  final TorrentService torrents;
  final MusicMetadataRepository metadata;
  final SimilarArtistsRepository similar;
  final IndexerService indexer;
  final RuTrackerService catalog;
  final Random random;
  final Duration sourceTimeout, audioTimeout;
  final Map<String, DateTime> _failedReleases = {};

  bool _unavailable(String link) =>
      _failedReleases[link]?.isAfter(DateTime.now()) ?? false;

  void _rejectRelease(String link) {
    if (_failedReleases.length >= 100) {
      _failedReleases.remove(_failedReleases.keys.first);
    }
    _failedReleases[link] = DateTime.now().add(const Duration(minutes: 10));
  }

  List<Track> _known(String artist, Set<String> excluded) {
    final name = normalizeMusicName(artist);
    final tracks =
        library.mediaTracks
            .where(
              (track) =>
                  track.source != TrackSource.demo &&
                  _normalizedRadioArtist(track) == name &&
                  !excluded.contains(radioSongKey(track)),
            )
            .toList()
          ..shuffle(random);
    // Offline files do not depend on peers. Shuffle within each availability tier.
    tracks.sort((a, b) => (b.offline ? 1 : 0).compareTo(a.offline ? 1 : 0));
    return tracks.take(4).toList();
  }

  @override
  Stream<Track> candidates(
    List<Track> seeds,
    Set<String> excluded,
    SourceOperation operation,
  ) async* {
    final names = seeds.reversed
        .map(radioArtist)
        .where(
          (name) =>
              normalizeMusicName(name).isNotEmpty &&
              !const {
                'unknown artist',
                'unknown',
                'неизвестный исполнитель',
                'неизвестен',
              }.contains(normalizeMusicName(name)),
        )
        .toSet()
        .take(2)
        .toList();
    final emitted = Set<String>.of(excluded);
    // Yield an immediate fallback before any public API request.
    for (final name in names) {
      for (final track in _known(name, emitted).take(2)) {
        operation.check();
        if (emitted.add(radioSongKey(track))) yield track;
      }
    }
    final recommendations = <String>[];
    for (final name in names) {
      try {
        operation.check();
        final artist = await operation.wait(
          metadata.artist(name, operation: operation),
        );
        if (artist == null) continue;
        final artists = await operation.wait(
          similar.similarArtists(artist.id, operation: operation),
        );
        for (final item in artists.take(3)) {
          if (!recommendations.contains(item.name)) {
            recommendations.add(item.name);
          }
        }
      } on SourceCancelled {
        rethrow;
      } catch (_) {
        // Public metadata is optional; keep the local fallback.
      }
    }
    for (final name in recommendations.take(3)) {
      for (final track in _known(name, emitted)) {
        operation.check();
        if (emitted.add(radioSongKey(track))) yield track;
      }
    }
    // At most three artist searches and two releases per artist, per refill.
    final settings = library.settings;
    final direct = settings['searchProvider'] == 'rutracker';
    final automatic =
        settings['searchProvider'] == 'automatic' ||
        (settings['searchProvider'] == null &&
            (settings['indexerUrl'] as String? ?? '').isEmpty);
    final endpoint = automatic
        ? PublicMusicCatalog.endpoint
        : settings['indexerUrl'] as String? ?? '';
    if (direct || endpoint.isNotEmpty) {
      for (final name in {...recommendations, ...names}.take(3)) {
        operation.check();
        List<SearchRelease> releases;
        try {
          releases = await operation
              .wait(
                direct
                    ? catalog.search(name).then((listing) => listing.releases)
                    : indexer.search(
                        endpoint,
                        automatic
                            ? ''
                            : settings['indexerKey'] as String? ?? '',
                        name,
                        operation: operation,
                      ),
              )
              .timeout(sourceTimeout);
        } on SourceCancelled {
          rethrow;
        } catch (_) {
          continue;
        }
        final artistName = normalizeMusicName(name);
        releases = releases.where((release) {
          final parsed = parseReleaseIdentity(release.title);
          return normalizeMusicName(
                parsed?.artist ?? inferredReleaseArtist(release.title) ?? '',
              ) ==
              artistName;
        }).toList()..sort((a, b) => b.seeders.compareTo(a.seeders));
        for (final release in releases.take(2)) {
          if (_unavailable(release.link)) continue;
          final child = SourceOperation();
          unawaited(operation.whenCancelled.then((_) => child.cancel()));
          Directory? temporary;
          try {
            child.check();
            TorrentInfo? info;
            var sourceLink = release.link;
            if (direct) {
              final magnet = await child
                  .wait(catalog.magnet(release))
                  .timeout(sourceTimeout);
              sourceLink = magnet;
              if (_unavailable(magnet)) continue;
              info = await child
                  .wait(torrents.add(magnet, operation: child))
                  .timeout(sourceTimeout);
            } else {
              final cache = metadata.cache;
              final generation = cache.generation;
              final key = 'torrentmeta:${release.link}';
              var path = await cache.pathFor(key);
              if (path == null) {
                final work = Directory(
                  '${library.root.path}/radio-search-temp',
                );
                await work.create(recursive: true);
                temporary = await work.createTemp('release-');
                final source = await child
                    .wait(
                      indexer.resolve(
                        release.link,
                        temporary,
                        operation: child,
                      ),
                    )
                    .timeout(sourceTimeout);
                child.check();
                if (source.file) {
                  final bytes = await File(source.source).readAsBytes();
                  readTorrentMetainfo(bytes);
                  path = await cache.put(
                    key,
                    bytes,
                    extension: 'torrent',
                    ttl: const Duration(days: 7),
                    expectedGeneration: generation,
                  );
                } else {
                  sourceLink = source.source;
                  info = await child
                      .wait(torrents.add(source.source, operation: child))
                      .timeout(sourceTimeout);
                }
              }
              if (path != null) {
                // Engine file IDs can differ from metainfo ordinals. Upload also
                // retains the source for playback after cache eviction/restart.
                info = await child
                    .wait(torrents.upload(path, operation: child))
                    .timeout(sourceTimeout);
              }
            }
            child.check();
            if (info == null) continue;
            final tracks = torrents.tracks(
              info,
              link: sourceLink,
              album: release.title,
              artist: name,
            )..shuffle(random);
            for (final track in tracks.take(24)) {
              operation.check();
              if (emitted.add(radioSongKey(track))) yield track;
            }
          } on SourceCancelled {
            operation.check();
          } catch (_) {
            // One bad release must not prevent inspecting the next one.
            _rejectRelease(release.link);
          } finally {
            child.cancel();
            if (temporary != null) await temporary.delete(recursive: true);
          }
        }
      }
    }
    // More familiar music still works if discovery is absent or unreachable.
    for (final name in names) {
      for (final track in _known(name, emitted)) {
        operation.check();
        if (emitted.add(radioSongKey(track))) yield track;
      }
    }
  }

  @override
  Future<PreparedRadioTrack> prepare(
    Track track,
    SourceOperation operation,
  ) async {
    operation.check();
    track = library.byId(track.id) ?? track;
    final path = await operation.wait(library.localPathFor(track));
    operation.check();
    if (path != null) return PreparedRadioTrack(track, Uri.file(path));
    if (track.source != TrackSource.torrent) {
      throw const FileSystemException('Нет аудиофайла.');
    }
    try {
      final uri = await operation
          .wait(torrents.resolve(track, operation: operation))
          .timeout(sourceTimeout);
      await torrents.waitForAudio(
        uri,
        operation: operation,
        timeout: audioTimeout,
      );
      operation.check();
      return PreparedRadioTrack(track, uri);
    } catch (_) {
      operation.check();
      if (track.torrentLink != null) _rejectRelease(track.torrentLink!);
      rethrow;
    }
  }
}
