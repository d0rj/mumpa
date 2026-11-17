import 'dart:async';

import '../data/catalog_repository.dart';
import '../data/library_repository.dart';
import '../data/source_operation.dart';
import '../domain/catalog_identity.dart';
import '../domain/models.dart';

/// Lazy enrichment of one playing, available file. Never scans the library.
class CatalogEnrichment {
  CatalogEnrichment(this.library, this.catalog);
  final LibraryRepository library;
  final CatalogRepository catalog;
  final Map<String, DateTime> _attempts = {};
  String? _pendingKey;
  SourceOperation? _operation;
  bool _disposed = false;

  void consider(Track? current) {
    final track = current == null ? null : library.byId(current.id);
    if (_disposed ||
        track == null ||
        track.catalogLink != null ||
        track.catalogMatchingDisabled ||
        track.durationMs <= 0 ||
        library.settings['catalogAutoMatch'] == false ||
        !(track.source == TrackSource.local ||
            track.albumSource == TrackAlbumSource.tags)) {
      return;
    }
    final key = '${track.id}:${track.catalogEvidenceKey}';
    if (_pendingKey == key || _attempts[key]?.isAfter(DateTime.now()) == true) {
      return;
    }
    _operation?.cancel();
    final operation = _operation = SourceOperation();
    _pendingKey = key;
    unawaited(_match(track, key, operation));
  }

  Future<void> _match(
    Track track,
    String key,
    SourceOperation operation,
  ) async {
    try {
      if (await library.localPathFor(track) == null) return;
      operation.check();
      if (_attempts.length >= 256) _attempts.remove(_attempts.keys.first);
      _attempts[key] = DateTime.now().add(const Duration(minutes: 10));
      final result = await catalog.match(track, operation: operation);
      operation.check();
      final match = result.automatic;
      if (match != null && !_disposed) {
        await library.setCatalogLink(
          track.id,
          TrackCatalogLink(
            recording: match.recording,
            matchedAt: DateTime.now().toUtc(),
            manual: false,
            evidence: match.evidence,
          ),
          expectedEvidenceKey: track.catalogEvidenceKey,
          automatic: true,
        );
      }
    } catch (_) {
      // Metadata outages and abstentions must never interrupt playback.
    } finally {
      if (_pendingKey == key) _pendingKey = null;
    }
  }

  void dispose() {
    _disposed = true;
    _operation?.cancel();
  }
}
