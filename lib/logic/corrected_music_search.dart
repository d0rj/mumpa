import '../data/source_operation.dart';
import '../domain/models.dart';
import '../domain/search_query_correction.dart';

class CorrectedMusicSearchResult {
  CorrectedMusicSearchResult({
    required Iterable<SearchRelease> releases,
    this.correctedQuery,
    Iterable<String> suggestions = const [],
  }) : releases = List.unmodifiable(releases),
       suggestions = List.unmodifiable(suggestions);

  final List<SearchRelease> releases;
  final String? correctedQuery;
  final List<String> suggestions;
}

/// One original tracker request, at most one public artist lookup and one
/// corrected tracker request. All names remain visible in the search UI.
Future<CorrectedMusicSearchResult> searchMusicWithCorrections({
  required String query,
  required Future<List<SearchRelease>> Function(String query) search,
  required Iterable<String> knownNames,
  required SourceOperation operation,
  Future<List<String>> Function(String query)? suggestArtists,
  void Function(String query)? onCorrectionAttempt,
}) async {
  operation.check();
  final original = await operation.wait(search(query));
  operation.check();
  if (original.isNotEmpty) {
    return CorrectedMusicSearchResult(releases: original);
  }

  var plan = planMusicQueryCorrection(query, knownNames);
  if (!plan.exactMatch &&
      plan.correctedQuery == null &&
      plan.suggestions.isEmpty &&
      suggestArtists != null) {
    try {
      final names = await operation.wait(suggestArtists(query));
      operation.check();
      plan = planMusicQueryCorrection(query, names);
    } on SourceCancelled {
      rethrow;
    } catch (_) {
      // A metadata outage must not turn a successful, empty Jackett search
      // into a source error or stop local-library search from working.
    }
  }
  operation.check();
  final corrected = plan.correctedQuery;
  if (corrected == null) {
    return CorrectedMusicSearchResult(
      releases: original,
      suggestions: plan.suggestions,
    );
  }
  onCorrectionAttempt?.call(corrected);
  operation.check();
  final results = await operation.wait(search(corrected));
  operation.check();
  return CorrectedMusicSearchResult(
    releases: results,
    correctedQuery: corrected,
  );
}
