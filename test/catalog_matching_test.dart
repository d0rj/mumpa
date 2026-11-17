import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/profile_transfer.dart';
import 'package:mumpa/domain/catalog_identity.dart';
import 'package:mumpa/domain/catalog_matching.dart';
import 'package:mumpa/domain/collection_filter.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/track_matching.dart';

const song = Track(
  id: 'file',
  title: 'Роженица в метро',
  artist: 'Ежемесячные',
  album: 'Короли Абстракта VI',
  source: TrackSource.local,
  durationMs: 240457,
);
const recording = MusicRecording(
  id: '3230194751',
  provider: 'deezer',
  title: 'Роженица в метро',
  artist: 'Ежемесячные',
  artistId: '12411710',
  durationMs: 240000,
  albumTitles: ['Короли Абстракта VI'],
  isrcs: ['FR2X42545138'],
);

TrackCatalogLink link([MusicRecording r = recording]) => TrackCatalogLink(
  recording: r,
  matchedAt: DateTime.utc(2026, 11, 17),
  manual: true,
  evidence: const ['artist', 'title', 'album', 'duration'],
);
MusicRecording change(Map<String, dynamic> values) =>
    MusicRecording.fromJson({...recording.toJson(), ...values});

void main() {
  test('Russian metadata accepts only unique corroborated recording', () {
    final matches = rankCatalogMatches(song, [
      recording,
      change({
        'id': 'wrong',
        'artist': 'Другая группа',
        'primaryArtist': 'Другая группа',
        'artistId': '99',
        'artistCredits': [],
      }),
      change({
        'id': 'live',
        'title': 'Роженица в метро (Live)',
        'durationMs': 270000,
      }),
    ]);
    expect(automaticCatalogMatch(matches)?.recording.id, recording.id);
    expect(
      matches.first.evidence,
      containsAll(['artist', 'title', 'album', 'duration']),
    );
  });
  test(
    'case and yo are equivalent; transliteration requires a catalogue alias',
    () {
      const source = Track(
        id: 'yo',
        title: 'Ёлки!',
        artist: 'ЙОРШ',
        album: 'Альбом',
        source: TrackSource.local,
        durationMs: 180000,
      );
      const target = MusicRecording(
        id: 'one',
        title: 'Елки',
        artist: 'Йорш',
        albumTitles: ['Альбом'],
        durationMs: 180000,
        artistCredits: [
          CatalogArtist(id: 'band', name: 'Йорш', aliases: ['Yorsh']),
        ],
      );
      expect(evaluateCatalogMatch(source, target).automatic, isTrue);
      expect(
        evaluateCatalogMatch(
          source.copyWith(artist: 'Yorsh'),
          target,
        ).automatic,
        isTrue,
      );
      expect(
        evaluateCatalogMatch(
          source.copyWith(artist: 'Jorsch'),
          target,
        ).automatic,
        isFalse,
      );
    },
  );
  test('missing duration, album or independent artist evidence abstains', () {
    expect(
      evaluateCatalogMatch(song.copyWith(durationMs: 0), recording).automatic,
      isFalse,
    );
    expect(
      evaluateCatalogMatch(
        song.copyWith(album: 'Сборник'),
        recording,
      ).automatic,
      isFalse,
    );
    final inferred = Track.fromJson({
      ...song.toJson(),
      'source': 'torrent',
      'albumSource': 'release',
    });
    expect(evaluateCatalogMatch(inferred, recording).automatic, isFalse);
  });
  test(
    'radio edits, live album context, unknown artists and namesakes do not auto-link',
    () {
      for (final track in [
        song.copyWith(durationMs: 180000),
        song.copyWith(album: 'Live in Moscow'),
        song.copyWith(artist: 'Unknown artist'),
      ]) {
        expect(evaluateCatalogMatch(track, recording).automatic, isFalse);
      }
      final ambiguous = rankCatalogMatches(song, [
        recording,
        change({
          'id': 'another',
          'isrcs': [],
          'artistId': 'namesake',
          'artistCredits': [],
        }),
      ]);
      expect(automaticCatalogMatch(ambiguous), isNull);
    },
  );
  test('all supplied performers must appear in the actual credits', () {
    final duet = change({
      'artist': 'Ежемесячные feat. Гость',
      'primaryArtist': 'Ежемесячные',
      'artistCredits': [
        const CatalogArtist(id: 'a', name: 'Ежемесячные').toJson(),
        const CatalogArtist(id: 'b', name: 'Гость').toJson(),
      ],
    });
    expect(catalogArtistMatches('Ежемесячные & Гость', duet), isTrue);
    expect(catalogArtistMatches('Ежемесячные & Другой', duet), isFalse);
    expect(catalogArtistMatches('Ежемесячные & Гость', recording), isFalse);
  });
  test(
    'provider IDs and conflicting ISRC reuse never merge unrelated records',
    () {
      final other = change({'provider': 'musicbrainz', 'isrcs': []});
      expect(mergeCatalogRecordings([recording, other]), hasLength(2));
      expect(
        mergeCatalogRecordings([
          recording,
          change({'id': 'edit', 'durationMs': 180000}),
        ]),
        hasLength(2),
      );
      final mb = change({
        'provider': 'musicbrainz',
        'id': 'mb-recording',
        'artistCredits': [
          const CatalogArtist(id: 'mb-artist', name: 'Ежемесячные').toJson(),
        ],
      });
      final combined = mergeCatalogRecordings([recording, mb]).single;
      expect(combined.key, 'musicbrainz:mb-recording');
      expect(combined.keys, contains('deezer:3230194751'));
      expect(
        combined.artists.map((a) => a.key),
        containsAll(['deezer:12411710', 'musicbrainz:mb-artist']),
      );
    },
  );
  test(
    'saved identities separate namesakes and join confirmed aliases across providers',
    () {
      final first = song.copyWith(catalogLink: link());
      final different = Track.fromJson({
        ...song.toJson(),
        'id': 'different',
      }).copyWith(catalogLink: link(change({'id': 'another', 'isrcs': []})));
      final alias = Track.fromJson({
        ...song.toJson(),
        'id': 'alias',
        'artist': 'Ejemesyachnye',
      }).copyWith(catalogLink: link());
      final groups = TrackMatchIndex([
        first,
        different,
        alias,
      ]).rowsFor([first, different, alias]);
      expect(groups, hasLength(2));
      expect(groups.first.group.ids, {'file', 'alias'});
    },
  );

  group('durable identity', () {
    late Directory root;
    late LibraryRepository library;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('mumpa-catalog-');
      library = LibraryRepository(root);
      await library.load();
      await library.upsert([song]);
    });
    tearDown(() async {
      await library.flush();
      library.dispose();
      await root.delete(recursive: true);
    });
    test(
      'restart, cache clearing, reimport and portable export preserve identity and memberships',
      () async {
        await library.toggleLike(song.id);
        final playlist = await library.createPlaylist('Любимое');
        await library.addToPlaylist(playlist.id, [song.id]);
        expect(
          await library.setCatalogLink(
            song.id,
            link(),
            expectedEvidenceKey: song.catalogEvidenceKey,
          ),
          isTrue,
        );
        await library.upsert([
          song,
        ]); // Reimport the same file without optional catalogue fields.
        final cache = DiskMediaCache(Directory('${root.path}/metadata'));
        await cache.clear();
        final fresh = LibraryRepository(root);
        try {
          await fresh.load();
          expect(
            fresh.byId(song.id)?.catalogLink?.recording.key,
            recording.key,
          );
          expect(fresh.liked, {song.id});
          expect(fresh.playlists.single.trackIds, [song.id]);
          final exported = ProfileTransfer.decode(await fresh.exportProfile());
          final other = LibraryRepository(Directory('${root.path}/transfer'));
          try {
            await other.load();
            await other.importProfile(exported);
            expect(
              other.byId(song.id)?.catalogLink?.recording.key,
              recording.key,
            );
          } finally {
            await other.flush();
            other.dispose();
          }
        } finally {
          fresh.dispose();
        }
      },
    );
    test(
      'late response cannot revive deletion or overwrite manual opt-out',
      () async {
        await library.setCatalogLink(
          song.id,
          null,
          expectedEvidenceKey: song.catalogEvidenceKey,
        );
        expect(
          await library.setCatalogLink(
            song.id,
            link(),
            expectedEvidenceKey: song.catalogEvidenceKey,
            automatic: true,
          ),
          isFalse,
        );
        await library.removeTracks([song.id]);
        expect(
          await library.setCatalogLink(
            song.id,
            link(),
            expectedEvidenceKey: song.catalogEvidenceKey,
          ),
          isFalse,
        );
        expect(library.byId(song.id), isNull);
      },
    );
    test(
      'metadata edits invalidate identity, while artwork updates preserve it',
      () async {
        await library.setCatalogLink(
          song.id,
          link(),
          expectedEvidenceKey: song.catalogEvidenceKey,
        );
        final linked = library.byId(song.id)!;
        expect(linked.copyWith(artPath: 'cover.jpg').catalogLink, isNotNull);
        await library.editMetadata(linked, {'artist': 'Другой исполнитель'});
        expect(library.byId(song.id)!.catalogLink, isNull);
        expect(
          await library.setCatalogLink(
            song.id,
            link(),
            expectedEvidenceKey: song.catalogEvidenceKey,
          ),
          isFalse,
        );
      },
    );
    test(
      'canonical artist names participate in local search without rewriting file tags',
      () async {
        final target = change({
          'artistCredits': [
            const CatalogArtist(
              id: 'a',
              name: 'Ежемесячные',
              aliases: ['Ejemesyachnye'],
            ).toJson(),
          ],
        });
        await library.setCatalogLink(
          song.id,
          link(target),
          expectedEvidenceKey: song.catalogEvidenceKey,
        );
        expect(
          filterCollectionTracks(
            library.tracks,
            'Ejemesyachnye метро',
          ).single.id,
          song.id,
        );
        expect(library.byId(song.id)!.artist, 'Ежемесячные');
      },
    );
  });
}
