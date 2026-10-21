import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/profile_transfer.dart';
import 'package:mumpa/data/playlist_files.dart';
import 'package:mumpa/domain/local_features.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/playlist_rules.dart';
import 'package:path/path.dart' as p;

Track song(
  String id, {
  String artist = 'Band',
  int year = 2020,
  String? path,
}) => Track(
  id: id,
  title: 'Song $id',
  artist: artist,
  album: 'Album',
  source: TrackSource.local,
  localPath: path,
  year: year,
  bytes: 3,
);
void main() {
  late Directory root;
  late LibraryRepository library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-local-features-');
    library = LibraryRepository(root);
    await library.load();
  });
  tearDown(() async {
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  });
  test(
    'folder repair proposes unique moves and copies a relink into durable imports when requested',
    () async {
      final moved = Directory('${root.path}/moved');
      await moved.create();
      final file = File('${moved.path}/song.wav');
      await file.writeAsBytes([1, 2, 3]);
      final old = song('moved', path: '${root.path}/old/song.wav');
      await library.upsert([old]);
      await library.toggleLike(old.id);
      final candidates = await library.findRelinkCandidates(moved, [old]);
      expect(p.normalize(candidates[old.id]!), p.normalize(file.path));
      expect(library.byId(old.id)!.localPath, old.localPath);
      await library.relinkTrack(old.id, file.path, copy: true);
      expect(library.byId(old.id)!.localPath, isNot(file.path));
      expect(await File(library.byId(old.id)!.localPath!).readAsBytes(), [
        1,
        2,
        3,
      ]);
      expect(library.isTrackLiked(old.id), isTrue);
      final second = Directory('${moved.path}/ambiguous');
      await second.create();
      await File('${second.path}/song.wav').writeAsBytes([1, 2, 3]);
      expect(await library.findRelinkCandidates(moved, [old]), isEmpty);
    },
  );
  test(
    'smart rules refresh on favorites, playback and metadata without changing a saved queue',
    () async {
      await library.upsert([
        song('a'),
        song('b', artist: 'Other', year: 2001),
        song('c'),
      ], addToLibrary: true);
      final list = await library.saveSmartPlaylist('Unplayed Band', {
        'unplayed': true,
        'artist': 'band',
        'fromYear': 2010,
        'sort': 'rare',
      });
      expect(list.trackIds, ['a', 'c']);
      final queueSnapshot = List.of(list.trackIds);
      await library.recordListen('a');
      expect(library.playlistById(list.id)!.trackIds, ['c']);
      expect(queueSnapshot, ['a', 'c']);
      await library.editMetadata(library.byId('c')!, {'artist': 'Other'});
      expect(library.playlistById(list.id)!.trackIds, isEmpty);
      await library.load();
      expect(library.playlistById(list.id)!.isSmart, isTrue);
      expect(library.playlistById(list.id)!.trackIds, isEmpty);
    },
  );
  test(
    'incoming metadata overrides cannot replace existing names after a profile reimport and restart',
    () async {
      await library.upsert([song('a')]);
      final document =
          jsonDecode(await library.exportProfile()) as Map<String, dynamic>;
      document['profile']['tracks'][0]['title'] = 'Incoming title';
      document['profile']['localFeatures']['edits']['a'] = {
        'title': 'Incoming title',
      };
      await library.importProfile(ProfileTransfer.decode(jsonEncode(document)));
      expect(library.byId('a')!.title, 'Song a');
      await library.load();
      expect(library.byId('a')!.title, 'Song a');
    },
  );
  test(
    'smart favorite/offline filters intersect and legacy dates stay unknown',
    () async {
      await library.upsert([song('a', path: 'file.wav'), song('b')]);
      await library.toggleLike('a');
      await library.toggleLike('b');
      final list = await library.saveSmartPlaylist('Offline favorites', {
        'liked': true,
        'offline': true,
      });
      expect(list.trackIds, ['a']);
      library.features.added.clear();
      final added = await library.saveSmartPlaylist('Recent', {'addedDays': 7});
      expect(added.trackIds, isEmpty);
      expect(() => validatedSmartRule({'limit': -1}), throwsFormatException);
      expect(
        () => validatedSmartRule({'fromYear': 2024, 'toYear': 2000}),
        throwsFormatException,
      );
      expect(
        () => validatedSmartRule({'unplayed': 'yes'}),
        throwsFormatException,
      );
    },
  );
  test(
    'listening time uses dated buckets, persists and never invents old time',
    () async {
      await library.upsert([song('a')]);
      await library.recordListen('a');
      library.recordListeningTime('a', 20000, at: DateTime(2026, 10, 1, 12));
      library.recordListeningTime('a', 10000, at: DateTime(2026, 10, 2, 12));
      library.recordListeningTime('a', 600000, at: DateTime(2026, 10, 2));
      await library.saveFeatures();
      await library.load();
      final summary = library.listeningSummary(
        since: DateTime(2026, 10, 2),
        until: DateTime(2026, 10, 2),
      );
      expect(summary.milliseconds, 10000);
      expect(summary.artists['Band'], 10000);
      expect(summary.daily.length, 1);
      expect(library.features.lastPlayed['a'], isNotNull);
    },
  );
  test(
    'clock excludes pause, buffering, backward seek, track changes and long gaps',
    () {
      final clock = ListeningClock();
      expect(clock.sample('a', 0, true, 0), 0);
      expect(clock.sample('a', 1000, true, 1000), 1000);
      expect(clock.sample('a', 61000, true, 1100), 100);
      expect(clock.sample('a', 2000, true, 1200), 0);
      expect(clock.sample('a', 3000, false, 2200), 0);
      expect(clock.sample('a', 4000, true, 3200), 0);
      expect(clock.sample('b', 5000, true, 4200), 0);
      expect(clock.sample('b', 65000, true, 64200), 0);
    },
  );
  test(
    'smart shuffle retains every occurrence and separates balanced artists',
    () {
      final tracks = [
        song('a'),
        song('b'),
        song('c', artist: 'Other'),
        song('d', artist: 'Other'),
      ];
      final shuffled = smartShuffle(
        [0, 1, 2, 3],
        (i) => tracks[i],
        LocalFeatures(),
        Random(7),
      );
      expect(shuffled.toSet(), {0, 1, 2, 3});
      for (var i = 1; i < shuffled.length; i++) {
        expect(
          tracks[shuffled[i]].artist,
          isNot(tracks[shuffled[i - 1]].artist),
        );
      }
    },
  );
  test(
    'profile transfers rules and personal features without paths or ownership; reimport is idempotent',
    () async {
      await library.upsert([song('a')]);
      await library.saveSmartPlaylist('Band', {'artist': 'Band'});
      await library.recordListen('a');
      library.recordListeningTime('a', 1000);
      await library.editMetadata(library.byId('a')!, {
        'title': 'Edited',
        'artPath': 'C:/private/cover.jpg',
      });
      await library.setPinned(['a'], true);
      library.features.automatic.add('a');
      final contents = await library.exportProfile();
      expect(contents, isNot(contains('C:/private')));
      final features =
          (jsonDecode(contents)['profile']['localFeatures'] as Map);
      expect(features['automatic'], isEmpty);
      final transfer = ProfileTransfer.decode(contents);
      await library.importProfile(transfer);
      await library.importProfile(transfer);
      expect(
        library.features.listening.values.fold<int>(
          0,
          (sum, b) => sum + b.milliseconds,
        ),
        1000,
      );
      expect(library.features.pinned, contains('a'));
      expect(library.playlists.single.isSmart, isTrue);
    },
  );
  test(
    'metadata overrides survive refreshed tags; relink preserves ID and references',
    () async {
      final first = File('${root.path}/first.wav');
      await first.writeAsBytes([1, 2, 3]);
      final second = File('${root.path}/second.wav');
      await second.writeAsBytes([1, 2, 3]);
      await library.upsert([song('a', path: first.path)]);
      await library.toggleLike('a');
      final list = await library.createPlaylist('Saved');
      await library.addToPlaylist(list.id, ['a']);
      await library.editMetadata(library.byId('a')!, {'title': 'User title'});
      await library.upsert([song('a', path: first.path)]);
      expect(library.byId('a')!.title, 'User title');
      await library.relinkTrack('a', second.path);
      expect(library.byId('a')!.localPath, second.path);
      expect(library.isTrackLiked('a'), isTrue);
      expect(library.playlistById(list.id)!.trackIds, ['a']);
      await second.writeAsBytes([3, 2, 1]);
      await expectLater(
        library.relinkTrack('a', first.path),
        throwsFormatException,
      );
    },
  );
  test(
    'M3U8 roundtrip preserves local order and skips unsupported network sources',
    () async {
      final a = File('${root.path}/Песня а.wav');
      await a.writeAsBytes([1, 2, 3]);
      final b = File('${root.path}/Песня б.wav');
      await b.writeAsBytes([1, 2, 3]);
      final source = [song('b', path: b.path), song('a', path: a.path)];
      await library.upsert(source);
      final text = PlaylistFiles.encode(
        source,
        (t) => t.localPath,
        baseDirectory: root.path,
      );
      final list = await PlaylistFiles.import(
        library,
        text,
        'Imported',
        baseDirectory: root.path,
      );
      expect(list.trackIds, ['b', 'a']);
      expect(
        PlaylistFiles.parse(
          '#EXTM3U\nhttps://test/track.mp3\nmagnet:?xt=x\n#no\n',
        ),
        isEmpty,
      );
      expect(text, contains('Песня б.wav'));
    },
  );
  test(
    'radio feedback is local, applies to matched variants and can be undone',
    () async {
      await library.upsert([song('a'), song('b', artist: 'Other')]);
      await library.radioFeedback(library.byId('a')!, block: true);
      expect(library.acceptsRadio(library.byId('a')!), isFalse);
      expect(
        library.acceptsRadio(
          Track.fromJson({...library.byId('a')!.toJson(), 'id': 'new-source'}),
        ),
        isFalse,
      );
      expect(library.acceptsRadio(library.byId('b')!), isTrue);
      await library.radioFeedback(library.byId('a')!, block: true, undo: true);
      expect(library.acceptsRadio(library.byId('a')!), isTrue);
      await library.radioFeedback(library.byId('a')!, muteArtist: true);
      await library.load();
      expect(library.reducedRadioArtist('Band'), isTrue);
      expect(library.acceptsRadio(library.byId('a')!), isTrue);
    },
  );
}
