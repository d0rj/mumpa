import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/domain/collection_filter.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  test(
    'removing tracks during collection index preparation leaves no dangling IDs',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-index-race-');
      final library = LibraryRepository(root);
      addTearDown(() async {
        await library.flush();
        library.dispose();
        await root.delete(recursive: true);
      });
      final tracks = List.generate(
        10000,
        (i) => Track(
          id: '$i',
          title: 'Song $i',
          artist: 'Band',
          album: 'Album',
          source: TrackSource.local,
        ),
      );
      final opening = library.openSourceCollection(
        hash: 'test-source',
        name: 'Collection',
        tracks: tracks,
      );
      await library.removeTracks([tracks.last.id]);
      await opening;
      expect(library.byId(tracks.last.id), isNull);
      expect(
        library.playlists.single.trackIds,
        isNot(contains(tracks.last.id)),
      );
      expect(library.playlists.single.trackIds, hasLength(9999));
    },
  );

  test(
    'indexed snapshots stay immutable and invalidate with track metadata',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-index-');
      final library = LibraryRepository(root);
      addTearDown(() async {
        await library.flush();
        library.dispose();
        await root.delete(recursive: true);
      });
      const track = Track(
        id: 'a',
        title: 'Old title',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.local,
      );
      await library.upsert([track]);
      final first = library.tracks;
      expect(library.tracks, same(first));
      expect(() => first.clear(), throwsUnsupportedError);
      await library.toggleLike('a');
      await library.setSetting('volume', 0.5);
      expect(library.tracks, same(first));
      expect(library.isTrackLiked('a'), isTrue);
      final updated = track.copyWith(title: 'New title');
      await library.upsert([updated]);
      expect(library.tracks, isNot(same(first)));
      expect(library.byId('a'), same(updated));
      expect(filterCollectionTracks(library.tracks, 'old'), isEmpty);
      expect(filterCollectionTracks(library.tracks, 'new'), [updated]);
      await library.toggleLike('a');
      await library.removeTracks(['a']);
      expect(library.byId('a'), isNull);
      expect(library.tracks, isEmpty);
      expect(first, [track]);
    },
  );

  test('large library search and ID lookup benchmark', () async {
    final root = await Directory.systemTemp.createTemp('mumpa-search-perf-');
    final library = LibraryRepository(root);
    addTearDown(() async {
      library.dispose();
      await root.delete(recursive: true);
    });
    List<Track> tracks;
    const real = bool.fromEnvironment('REAL_LIBRARY_BENCHMARK');
    if (real) {
      final saved =
          jsonDecode(
                await File(
                  '${Platform.environment['APPDATA']}/app.mumpa/mumpa/Mumpa/library.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      tracks = (saved['tracks'] as List)
          .map(
            (value) => Track.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList();
    } else {
      tracks = List.generate(
        10000,
        (i) => Track(
          id: '$i',
          title: 'Песня $i',
          artist: 'Исполнитель ${i % 50}',
          album: 'Альбом ${i ~/ 20}',
          source: TrackSource.local,
        ),
      );
    }
    await library.upsert(tracks);
    final times = <int>[];
    for (final query in ['Е', 'Еж', 'Еже', 'Ежем', 'Ежемесячные']) {
      final watch = Stopwatch()..start();
      for (var repeat = 0; repeat < 3; repeat++) {
        filterCollectionTracks(library.tracks, query);
      }
      times.add(watch.elapsedMicroseconds);
    }
    final lookups = Stopwatch()..start();
    for (var i = 0; i < 10000; i++) {
      expect(library.byId(tracks.last.id), same(tracks.last));
    }
    // Report only timing/counts, never profile fields or credentials.
    // ignore: avoid_print
    print(
      'SEARCH_PERF tracks=${tracks.length} three_pass_us=$times '
      '10000_lookup_us=${lookups.elapsedMicroseconds}',
    );
  });
}
