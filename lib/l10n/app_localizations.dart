import 'package:flutter/foundation.dart';
import 'messages_en.dart';

/// Source messages are Russian; placeholders keep user metadata untouched.
class AppLanguage {
  static String current = 'ru';
  static bool get english => current == 'en';
}

String tr(String source, [List<Object?> arguments = const []]) {
  var translated = AppLanguage.english
      ? englishMessages[source] ?? source
      : source;
  // Replace once so a track title containing "{1}" remains literal data.
  return translated.replaceAllMapped(RegExp(r'\{(\d+)\}'), (match) {
    final i = int.parse(match[1]!);
    return i < arguments.length ? '${arguments[i]}' : match[0]!;
  });
}

final _messageCache = <(String, String), String>{};
final _reverseMessages = {
  for (final entry in englishMessages.entries) entry.value: entry.key,
};
final _messagePatterns = englishMessages.entries
    .where((e) => e.key.contains('{0}'))
    .map((entry) {
      (RegExp, List<int>) pattern(String template) {
        final ids = <int>[];
        var offset = 0;
        final parts = <String>['^'];
        for (final match in RegExp(r'\{(\d+)\}').allMatches(template)) {
          parts.add(RegExp.escape(template.substring(offset, match.start)));
          parts.add('(.*?)');
          ids.add(int.parse(match[1]!));
          offset = match.end;
        }
        parts.add(RegExp.escape(template.substring(offset)));
        parts.add(r'$');
        return (RegExp(parts.join(), dotAll: true), ids);
      }

      return (
        entry: entry,
        forward: pattern(entry.key),
        reverse: pattern(entry.value),
      );
    })
    .toList();

/// Localize service errors/status at display time, including after a language
/// change. This is deliberately used only for app messages, never music data.
String trMessage(String source) {
  final key = (AppLanguage.current, source);
  final cached = _messageCache[key];
  if (cached != null) return cached;
  final direct = AppLanguage.english
      ? englishMessages[source]
      : _reverseMessages[source];
  if (direct != null) return direct;
  for (final entry in _messagePatterns) {
    final pattern = AppLanguage.english ? entry.forward : entry.reverse;
    final match = pattern.$1.firstMatch(source);
    if (match == null) continue;
    final values = <int, String>{
      for (var i = 0; i < pattern.$2.length; i++) pattern.$2[i]: match[i + 1]!,
    };
    final template = AppLanguage.english ? entry.entry.value : entry.entry.key;
    final result = template.replaceAllMapped(
      RegExp(r'\{(\d+)\}'),
      (m) => values[int.parse(m[1]!)] ?? m[0]!,
    );
    if (_messageCache.length >= 512) _messageCache.clear();
    _messageCache[key] = result;
    return result;
  }
  return source;
}

@visibleForTesting
Set<String> get untranslatedMessages => englishMessages.entries
    .where((e) => e.value.isEmpty)
    .map((e) => e.key)
    .toSet();
