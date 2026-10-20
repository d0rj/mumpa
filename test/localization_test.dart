import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/l10n/app_localizations.dart';
import 'package:mumpa/l10n/messages_en.dart';

void main() {
  tearDown(() => AppLanguage.current = 'ru');
  test('English catalog covers source messages and preserves placeholders', () {
    expect(englishMessages.length, greaterThan(500));
    final placeholders = RegExp(r'\{\d+\}');
    for (final entry in englishMessages.entries) {
      expect(entry.value, isNotEmpty, reason: entry.key);
      expect(
        placeholders.allMatches(entry.value).map((m) => m[0]).toSet(),
        placeholders.allMatches(entry.key).map((m) => m[0]).toSet(),
        reason: entry.key,
      );
    }
    final roots = [Directory('lib/ui'), Directory('lib/logic')];
    final literal = RegExp(r'tr\(\s*("(?:\\.|[^"\\])*")');
    for (final root in roots) {
      for (final file
          in root
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        for (final match in literal.allMatches(file.readAsStringSync())) {
          final source = jsonDecode(match[1]!) as String;
          expect(
            englishMessages.containsKey(source),
            isTrue,
            reason: '${file.path}: $source',
          );
        }
      }
    }
  });
  test(
    'runtime language and interpolation leave track titles and braces intact',
    () {
      expect(tr('Настройки'), 'Настройки');
      AppLanguage.current = 'en';
      expect(tr('Настройки'), 'Settings');
      expect(tr('Слушать {0}', ['Песня {1}']), 'Play Песня {1}');
      expect(tr('Неизвестное сообщение'), 'Неизвестное сообщение');
      expect(
        trMessage('Доступна Mumpa 1.2.3 (42.0 МБ).'),
        'Mumpa 1.2.3 is available (42.0 MB).',
      );
      expect(trMessage('Скачиваем обновление…'), 'Downloading update…');
      AppLanguage.current = 'ru';
      expect(trMessage('Play Песня {1}'), 'Слушать Песня {1}');
    },
  );
}
