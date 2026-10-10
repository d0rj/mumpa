import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/corrected_music_search.dart';

const _release = SearchRelease(
  title: 'Ежемесячные — Альбом',
  link: 'https://example.com/album.torrent',
);

void main() {
  test(
    'original results return without spelling or metadata requests',
    () async {
      final requests = <String>[];
      final result = await searchMusicWithCorrections(
        query: 'Ежемесечные',
        knownNames: ['Ежемесячные'],
        operation: SourceOperation(),
        search: (query) async {
          requests.add(query);
          return [_release];
        },
        suggestArtists: (_) => throw StateError('unneeded metadata request'),
      );
      expect(requests, ['Ежемесечные']);
      expect(result.correctedQuery, isNull);
      expect(result.releases, [_release]);
    },
  );

  test('empty exact search tries one close library query visibly', () async {
    final requests = <String>[];
    final attempts = <String>[];
    final result = await searchMusicWithCorrections(
      query: 'Ежемесечные',
      knownNames: ['Ежемесячные'],
      operation: SourceOperation(),
      search: (query) async {
        requests.add(query);
        return query == 'Ежемесячные' ? [_release] : [];
      },
      suggestArtists: (_) =>
          throw StateError('library match already available'),
      onCorrectionAttempt: attempts.add,
    );
    expect(requests, ['Ежемесечные', 'Ежемесячные']);
    expect(attempts, ['Ежемесячные']);
    expect(result.correctedQuery, 'Ежемесячные');
    expect(result.releases.single, _release);
  });

  test(
    'public hints are filtered and tracker retries remain bounded',
    () async {
      final requests = <String>[];
      var lookups = 0;
      final result = await searchMusicWithCorrections(
        query: 'Ежемесечные',
        knownNames: [],
        operation: SourceOperation(),
        search: (query) async {
          requests.add(query);
          return [];
        },
        suggestArtists: (query) async {
          expect(query, 'Ежемесечные');
          lookups++;
          return ['Ежемесячные', 'Unrelated artist'];
        },
      );
      expect(lookups, 1);
      expect(requests, ['Ежемесечные', 'Ежемесячные']);
      expect(result.correctedQuery, 'Ежемесячные');
      expect(result.releases, isEmpty);
    },
  );

  test(
    'ambiguous names produce suggestions without another tracker call',
    () async {
      final requests = <String>[];
      final result = await searchMusicWithCorrections(
        query: 'Les Cats',
        knownNames: ['Les Cots', 'Les Cuts'],
        operation: SourceOperation(),
        search: (query) async {
          requests.add(query);
          return [];
        },
        suggestArtists: (_) => throw StateError('must not override ambiguity'),
      );
      expect(requests, ['Les Cats']);
      expect(result.correctedQuery, isNull);
      expect(result.suggestions, ['Les Cots', 'Les Cuts']);
    },
  );

  test('metadata outage leaves empty successful Jackett results', () async {
    final result = await searchMusicWithCorrections(
      query: 'Unrecognized',
      knownNames: [],
      operation: SourceOperation(),
      search: (_) async => [],
      suggestArtists: (_) => throw StateError('offline'),
    );
    expect(result.releases, isEmpty);
    expect(result.correctedQuery, isNull);
  });

  test(
    'cancelling a delayed hint prevents any corrected tracker request',
    () async {
      final operation = SourceOperation();
      final requested = Completer<void>();
      final hints = Completer<List<String>>();
      final queries = <String>[];
      final pending = searchMusicWithCorrections(
        query: 'Ежемесечные',
        knownNames: [],
        operation: operation,
        search: (query) async {
          queries.add(query);
          return [];
        },
        suggestArtists: (_) {
          requested.complete();
          return hints.future;
        },
      );
      await requested.future;
      operation.cancel();
      await expectLater(pending, throwsA(isA<SourceCancelled>()));
      hints.complete(['Ежемесячные']);
      await Future<void>.delayed(Duration.zero);
      expect(queries, ['Ежемесечные']);
    },
  );

  test(
    'cancelling delayed corrected results rejects the entire search',
    () async {
      final operation = SourceOperation();
      final requested = Completer<void>();
      final corrected = Completer<List<SearchRelease>>();
      final pending = searchMusicWithCorrections(
        query: 'Ежемесечные',
        knownNames: ['Ежемесячные'],
        operation: operation,
        search: (query) {
          if (query == 'Ежемесечные') return Future.value([]);
          requested.complete();
          return corrected.future;
        },
      );
      await requested.future;
      operation.cancel();
      await expectLater(pending, throwsA(isA<SourceCancelled>()));
      corrected.complete([_release]);
      await Future<void>.delayed(Duration.zero);
    },
  );
}
