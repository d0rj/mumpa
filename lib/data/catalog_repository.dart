import 'dart:async';

import '../domain/catalog_matching.dart';
import '../domain/models.dart';
import '../domain/music_metadata.dart';
import 'deezer_catalog_repository.dart';
import 'music_metadata_repository.dart';
import 'source_operation.dart';

class CatalogSearchResult {
  const CatalogSearchResult(this.recordings, this.unavailableProviders);
  final List<MusicRecording> recordings;
  final List<String> unavailableProviders;
}

class CatalogMatchResult {
  const CatalogMatchResult(this.matches, this.unavailableProviders);
  final List<CatalogMatch> matches;
  final List<String> unavailableProviders;
  CatalogMatch? get automatic => automaticCatalogMatch(matches);
}

class CatalogRepository {
  CatalogRepository({
    required this.musicBrainz,
    DeezerCatalogRepository? deezer,
    this.providerTimeout = const Duration(seconds: 12),
  }) : deezer =
           deezer ??
           DeezerCatalogRepository(
             cache: musicBrainz.cache,
             client: musicBrainz.client,
           );
  final MusicMetadataRepository musicBrainz;
  final DeezerCatalogRepository deezer;
  final Duration providerTimeout;
  final Set<SourceOperation> _active = {};
  bool _disposed = false;

  Future<CatalogSearchResult> _collect(
    Future<List<MusicRecording>> Function(SourceOperation) mb,
    Future<List<MusicRecording>> Function(SourceOperation) dz,
    SourceOperation? caller,
  ) async {
    final unavailable = <String>[];
    final generation = musicBrainz.cache.generation;
    Future<List<MusicRecording>> fetch(
      String name,
      Future<List<MusicRecording>> Function(SourceOperation) job,
    ) async {
      final operation = SourceOperation();
      final remove = caller?.onCancel(operation.cancel);
      _active.add(operation);
      final timer = Timer(providerTimeout, operation.cancel);
      try {
        caller?.check();
        if (_disposed) throw const SourceCancelled();
        return await operation.wait(job(operation));
      } catch (_) {
        caller?.check();
        if (_disposed || generation != musicBrainz.cache.generation) {
          throw const SourceCancelled();
        }
        unavailable.add(name);
        return const [];
      } finally {
        timer.cancel();
        remove?.call();
        operation.cancel();
        _active.remove(operation);
      }
    }

    final results = await Future.wait([
      fetch('MusicBrainz', mb),
      fetch('Deezer', dz),
    ]);
    caller?.check();
    if (_disposed || generation != musicBrainz.cache.generation) {
      throw const SourceCancelled();
    }
    return CatalogSearchResult(
      mergeCatalogRecordings(results.expand((r) => r)),
      List.unmodifiable(unavailable),
    );
  }

  Future<CatalogSearchResult> search(
    String query, {
    SourceOperation? operation,
  }) => _collect(
    (op) => musicBrainz.searchRecordings(query, operation: op),
    (op) => deezer.search(query, operation: op),
    operation,
  );

  Future<CatalogMatchResult> match(
    Track track, {
    SourceOperation? operation,
  }) async {
    final result = await _collect(
      (op) => musicBrainz.findRecordings(
        catalogArtistNames(track.artist).firstOrNull ?? track.artist,
        track.title,
        operation: op,
      ),
      (op) async {
        final rows = await deezer.search(
          '${catalogArtistNames(track.artist).firstOrNull ?? track.artist} ${track.title}',
          operation: op,
        );
        final ranked = rankCatalogMatches(track, rows);
        // Details supply all credited performers, not just the search's primary artist.
        final enriched = <MusicRecording>[];
        for (final row in ranked.take(3)) {
          enriched.add(await deezer.recording(row.recording.id, operation: op));
        }
        return [...enriched, ...ranked.skip(3).map((m) => m.recording)];
      },
      operation,
    );
    return CatalogMatchResult(
      List.unmodifiable(rankCatalogMatches(track, result.recordings)),
      result.unavailableProviders,
    );
  }

  Future<MusicRecording> details(
    MusicRecording recording, {
    SourceOperation? operation,
  }) async {
    final details = recording.provider == 'deezer'
        ? await deezer.recording(recording.id, operation: operation)
        : await musicBrainz.recordingWithAlbums(
            recording,
            operation: operation,
          );
    return details.withLinks(recording);
  }

  void dispose() {
    _disposed = true;
    for (final operation in _active.toList()) {
      operation.cancel();
    }
    deezer.dispose();
  }
}
