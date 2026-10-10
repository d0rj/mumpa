import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/domain/search_query_correction.dart';

void main() {
  test('corrects a close Russian artist and adjacent transposition', () {
    expect(
      planMusicQueryCorrection('Ежемесечные', [
        'Ежемесячные',
        'Слава КПСС',
      ]).correctedQuery,
      'Ежемесячные',
    );
    expect(
      planMusicQueryCorrection('Daft Pnuk', ['Daft Punk']).correctedQuery,
      'Daft Punk',
    );
    expect(
      planMusicQueryCorrection('Discovery Daft Pnuk', [
        'Discovery Daft Punk',
      ]).correctedQuery,
      'Discovery Daft Punk',
    );
  });

  test('equally close artists require an explicit choice', () {
    final plan = planMusicQueryCorrection('Les Cats', [
      'Les Cots',
      'Les Cuts',
      'Les Cots',
    ]);
    expect(plan.correctedQuery, isNull);
    expect(plan.suggestions, ['Les Cots', 'Les Cuts']);
    expect(() => plan.suggestions.add('other'), throwsUnsupportedError);
  });

  test('exact known names suppress a nearby artist and normalize ё', () {
    final plan = planMusicQueryCorrection(' еЖЁМЕСЯЧНЫЕ ', [
      'Ежемесячные',
      'Ежемесячное',
    ]);
    expect(plan.exactMatch, isTrue);
    expect(plan.correctedQuery, isNull);
    expect(plan.suggestions, isEmpty);
  });

  test('short, distant and different token structures are not corrected', () {
    for (final pair in [
      ('Blur', 'Blue'),
      ('Metallica', 'Madonna'),
      ('DaftPunk', 'Daft Punk'),
      ('2020', '2021'),
    ]) {
      final plan = planMusicQueryCorrection(pair.$1, [pair.$2]);
      expect(plan.correctedQuery, isNull);
      expect(plan.suggestions, isEmpty);
    }
  });
}
