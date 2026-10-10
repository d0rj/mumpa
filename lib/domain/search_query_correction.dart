import 'music_metadata.dart';

/// Only a close, unique match may be searched automatically. Equally close
/// names stay suggestions so an unrelated artist is never picked silently.
class SearchCorrectionPlan {
  SearchCorrectionPlan({
    this.correctedQuery,
    this.exactMatch = false,
    Iterable<String> suggestions = const [],
  }) : suggestions = List.unmodifiable(suggestions);

  final String? correctedQuery;
  final bool exactMatch;
  final List<String> suggestions;
}

SearchCorrectionPlan planMusicQueryCorrection(
  String query,
  Iterable<String> knownNames,
) {
  final normalized = normalizeMusicName(query);
  if (normalized.length < 5 || normalized.length > 120) {
    return SearchCorrectionPlan();
  }
  final tokens = normalized.split(' ').length;
  final maxDistance = normalized.length >= 10 ? 2 : 1;
  final names = <String, String>{};
  for (final name in knownNames) {
    final key = normalizeMusicName(name);
    if (key == normalized) return SearchCorrectionPlan(exactMatch: true);
    if (key.length < 5 || key.length > 120) continue;
    names.putIfAbsent(key, () => name.trim());
    if (names.length >= 4096) break;
  }
  var closest = maxDistance + 1;
  final matches = <String>[];
  for (final entry in names.entries) {
    final key = entry.key;
    if ((normalized.length - key.length).abs() > maxDistance ||
        key.split(' ').length != tokens) {
      continue;
    }
    final distance = _editDistance(normalized, key);
    final length = normalized.length > key.length
        ? normalized.length
        : key.length;
    if (distance > maxDistance || 1 - distance / length < 0.84) continue;
    if (distance < closest) {
      closest = distance;
      matches.clear();
    }
    if (distance == closest) matches.add(entry.value);
  }
  matches.sort((a, b) => a.compareTo(b));
  return SearchCorrectionPlan(
    correctedQuery: matches.length == 1 ? matches.single : null,
    suggestions: matches.length > 1 ? matches.take(5) : const [],
  );
}

// Optimal string alignment distance treats an adjacent transposition as one
// typo. Use Unicode code points rather than splitting a surrogate pair.
int _editDistance(String left, String right) {
  final a = left.runes.toList();
  final b = right.runes.toList();
  var previous = List<int>.generate(b.length + 1, (i) => i);
  List<int>? beforePrevious;
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      final insertion = current[j - 1] + 1;
      final deletion = previous[j] + 1;
      var distance = substitution < insertion ? substitution : insertion;
      if (deletion < distance) distance = deletion;
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
        final transposition = beforePrevious![j - 2] + 1;
        if (transposition < distance) distance = transposition;
      }
      current[j] = distance;
    }
    beforePrevious = previous;
    previous = current;
  }
  return previous.last;
}
