import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/track_matching.dart';

Track song(
  String id, {
  String title = 'Песня',
  String artist = 'Группа',
  String album = 'Альбом',
  int duration = 180000,
  String? localPath,
  String? torrentPath,
}) => Track(
  id: id,
  title: title,
  artist: artist,
  album: album,
  source: torrentPath == null ? TrackSource.local : TrackSource.torrent,
  durationMs: duration,
  localPath: localPath,
  torrentPath: torrentPath,
);

List<List<String>> groups(List<Track> tracks) => TrackMatchIndex(tracks)
    .rowsFor(tracks)
    .map((row) => row.group.variants.map((track) => track.id).toList()..sort())
    .toList();

void main() {
  test(
    'formats, collections, normalized names and small length differences group',
    () {
      final tracks = [
        song(
          'mp3',
          title: 'Ёлки — зелёные!',
          duration: 180000,
          torrentPath: 'one/song.mp3',
        ),
        song(
          'flac',
          title: 'елки зеленые',
          artist: 'ГРУППА',
          album: 'Сборник',
          duration: 184000,
          localPath: 'song.flac',
        ),
      ];
      expect(groups(tracks), [
        ['flac', 'mp3'],
      ]);
    },
  );

  test(
    'clean, explicit and remaster annotations preserve versions in one group',
    () {
      final tracks = [
        song('clean', title: 'Песня (Clean)', duration: 178000),
        song('explicit', title: 'Песня [Explicit Version]', duration: 195000),
        song(
          'remaster',
          title: 'Группа - Песня (Remastered 2011)',
          duration: 180000,
        ),
        song('format', title: 'Песня [MP3 320kbps]', duration: 181000),
      ];
      expect(groups(tracks).single, [
        'clean',
        'explicit',
        'format',
        'remaster',
      ]);
      expect(tracks[0].title, 'Песня (Clean)');
    },
  );

  test(
    'large length differences remain separate and unknown length cannot bridge',
    () {
      final tracks = [
        song('short'),
        song('long', duration: 360000),
        song('unknown', duration: 0),
      ];
      expect(groups(tracks), [
        ['short'],
        ['long'],
        ['unknown'],
      ]);
      expect(groups([song('known'), song('unknown', duration: 0)]).single, [
        'known',
        'unknown',
      ]);
    },
  );

  test('nearby durations do not create a transitive bridge', () {
    final tracks = [
      song('a', duration: 200000),
      song('b', duration: 209000),
      song('c', duration: 218000),
    ];
    expect(groups(tracks), [
      ['a', 'b'],
      ['c'],
    ]);
    expect(
      groups(tracks.reversed.toList()).map((items) => items.join(',')).toSet(),
      {'a,b', 'c'},
    );
  });

  test(
    'live, remix, radio edit, acoustic, instrumental and rerecording remain distinct',
    () {
      final tracks = [
        song('studio'),
        for (final suffix in [
          'Live',
          'Club Remix',
          'Radio Edit',
          'Acoustic',
          'Instrumental',
          'Re-recorded',
        ])
          song(suffix, title: 'Песня ($suffix)'),
        song('concert-album', album: 'Live in Moscow 2005'),
        song('other-concert', album: 'Live in Moscow 2006'),
      ];
      expect(groups(tracks), hasLength(tracks.length));
    },
  );

  test(
    'missing/compilation artist, generic title and different guests never collapse',
    () {
      for (final artist in [
        'Неизвестный исполнитель',
        'Unknown Artist',
        'Various Artists',
        'VA',
        '',
      ]) {
        expect(
          groups([song('a', artist: artist), song('b', artist: artist)]),
          hasLength(2),
        );
      }
      expect(
        groups([song('a', title: 'Track 01'), song('b', title: 'Track 01')]),
        hasLength(2),
      );
      expect(
        groups([song('a'), song('b', artist: 'Группа feat. Guest')]),
        hasLength(2),
      );
      expect(
        groups([song('a', title: '99 Problems'), song('b', title: 'Problems')]),
        hasLength(2),
      );
      expect(
        groups([song('a', title: 'Clean'), song('b', title: 'Song')]),
        hasLength(2),
      );
    },
  );

  test('format labels distinguish codecs from ambiguous containers', () {
    expect(
      trackFormatDescription(song('a', localPath: 'a.flac')),
      'FLAC · lossless',
    );
    expect(
      trackFormatDescription(song('a', localPath: 'a.mp3')),
      'MP3 · lossy',
    );
    expect(
      trackFormatDescription(song('a', localPath: 'a.m4a')),
      'M4A · кодек не указан',
    );
    expect(trackFormatDescription(song('a')), 'Формат не указан');
  });

  test('intro/outro names require the same album and disc', () {
    expect(
      groups([
        song('a', title: 'Интро', album: 'First'),
        song('b', title: 'Интро', album: 'Second'),
      ]),
      hasLength(2),
    );
    expect(
      groups([song('a', title: 'Intro'), song('b', title: 'intro')]),
      hasLength(1),
    );
    expect(
      groups([
        song('a', title: 'Intro'),
        song('b', title: 'Intro').copyWith(disc: 2),
      ]),
      hasLength(2),
    );
  });

  test(
    'source descriptions allow explicitly labelled censor length differences',
    () {
      final tracks = [
        Track(
          id: 'a',
          title: 'Song',
          artist: 'Band',
          album: 'Album',
          source: TrackSource.torrent,
          torrentHash: 'a',
          durationMs: 180000,
        ),
        Track(
          id: 'b',
          title: 'Song',
          artist: 'Band',
          album: 'Album',
          source: TrackSource.torrent,
          torrentHash: 'b',
          durationMs: 197000,
        ),
      ];
      expect(groups(tracks), hasLength(2));
      expect(
        TrackMatchIndex(
          tracks,
          sourceDescriptions: {'b': 'Explicit release'},
        ).rowsFor(tracks),
        hasLength(1),
      );
    },
  );

  test('10k known copies avoid pairwise comparisons', () async {
    final tracks = List.generate(
      10000,
      (i) => song('$i', duration: 180000 + i % 500),
    );
    await prepareTrackMatching(tracks);
    final watch = Stopwatch()..start();
    final rows = TrackMatchIndex(tracks).rowsFor(tracks);
    expect(rows, hasLength(1));
    expect(rows.single.group.variants, hasLength(10000));
    expect(watch.elapsedMilliseconds, lessThan(2000));
  });

  group('repository matches', () {
    late Directory root;
    late LibraryRepository library;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('mumpa-matching-');
      library = LibraryRepository(root);
      await library.load();
    });
    tearDown(() async {
      await library.flush();
      library.dispose();
      await root.delete(recursive: true);
    });

    test(
      'one visible member exposes known variants without expanding membership',
      () async {
        final mp3 = song('mp3', torrentPath: 'one/song.mp3');
        final flac = song('flac', album: 'Other', localPath: 'song.flac');
        await library.upsert([mp3, flac]);
        final visible = [mp3];
        final row = library.matchedTracks(visible).single;
        expect(row.anchor.id, 'mp3');
        expect(row.members.map((track) => track.id), ['mp3']);
        expect(row.group.ids, {'mp3', 'flac'});
        expect(row.preferred.id, 'flac');
        expect(
          library.matchedTracks(visible),
          same(library.matchedTracks(visible)),
        );
        expect(library.trackCountLabel(library.tracks), '1 треков · 2 файлов');
      },
    );

    test(
      'defaults, separation, file membership and favorites survive reload',
      () async {
        final tracks = [song('a'), song('b'), song('c', title: 'Other')];
        final collection = await library.openSourceCollection(
          hash: 'source',
          name: 'Original',
          tracks: tracks,
        );
        await library.toggleLike('b');
        await library.preferTrackVariant('b');
        expect(library.matchedTracks(library.tracks).first.preferred.id, 'b');
        await library.setTrackMatchExcluded('a', true);
        final fresh = LibraryRepository(root);
        await fresh.load();
        expect(fresh.matchedTracks(fresh.tracks), hasLength(3));
        expect(fresh.isPreferredVariant('b'), isTrue);
        expect(fresh.isMatchExcluded('a'), isTrue);
        expect(fresh.playlists.single.trackIds, collection.trackIds);
        expect(fresh.liked, {'b'});
        await fresh.setTrackMatchExcluded('a', false);
        expect(fresh.matchedTracks(fresh.tracks), hasLength(2));
        expect(fresh.matchedTracks(fresh.tracks).first.preferred.id, 'b');
        await fresh.flush();
        fresh.dispose();
      },
    );

    test(
      'metadata enrichment/removal invalidates groups, likes do not',
      () async {
        final a = song('a'), b = song('b');
        await library.upsert([a, b]);
        final index = library.trackMatches;
        await library.toggleLike('a');
        await library.markPlayed('b');
        expect(library.trackMatches, same(index));
        await library.upsert([b.copyWith(title: 'Another song')]);
        expect(library.matchedTracks(library.tracks), hasLength(2));
        await library.preferTrackVariant('b');
        await library.setTrackMatchExcluded('b', true);
        await library.removeTracks(['b']);
        expect(library.matchedTracks(library.tracks).single.group.ids, {'a'});
        expect(library.isMatchExcluded('b'), isFalse);
        expect(library.isPreferredVariant('b'), isFalse);
      },
    );

    test(
      'group heart reflects an existing like after choosing another default',
      () async {
        await library.upsert([song('a'), song('b')]);
        await library.toggleLike('a');
        await library.preferTrackVariant('b');
        final row = library.matchedTracks(library.tracks).single;
        await library.toggleMatchedTrackLike(row.group, row.preferred.id);
        expect(library.liked, isEmpty);
        await library.toggleMatchedTrackLike(row.group, row.preferred.id);
        expect(library.liked, {'b'});
      },
    );
  });
}
