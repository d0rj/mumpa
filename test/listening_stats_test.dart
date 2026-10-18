import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/domain/models.dart';

Track _track(String id, {String? title}) => Track(
  id: id,
  title: title ?? 'Song $id',
  artist: 'Band',
  album: 'Album',
  source: TrackSource.local,
  localPath: 'unused/$id.wav',
  durationMs: 180000,
);

void main() {
  late Directory root;
  late LibraryRepository library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-listening-stats-');
    library = LibraryRepository(root);
    await library.load();
  });
  tearDown(() async {
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  });

  test(
    'legacy history does not invent counts; track and playlist counts persist',
    () async {
      await library.upsert([_track('a'), _track('b')]);
      await library.markPlayed('a');
      expect(library.topTracksPlaylist.trackIds, isEmpty);
      final first = await library.createPlaylist('First');
      final second = await library.createPlaylist('Second');
      await library.addToPlaylist(first.id, ['a']);
      await library.addToPlaylist(second.id, ['a', 'b']);
      await library.recordListen('a', playlistId: first.id);
      await library.recordListen('a', playlistId: second.id);
      await library.recordListen('b', playlistId: second.id);
      await library.recordListen('a');
      expect(library.trackPlayCount('a'), 3);
      expect(library.frequentPlaylists.map((p) => p.id), [second.id, first.id]);
      await library.load();
      expect(library.trackPlayCount('a'), 3);
      expect(library.playlistPlayCount(second.id), 2);
      expect(library.topTracksPlaylist.trackIds, ['a', 'b']);
      await library.recordListen('b', playlistId: MusicPlaylist.deviceTop50Id);
      expect(library.playlistPlayCount(MusicPlaylist.deviceTop50Id), 0);
      await library.removeTracks(['a']);
      expect(library.topTracksPlaylist.trackIds, ['b']);
      await library.deletePlaylist(second.id);
      expect(library.frequentPlaylists.map((p) => p.id), [first.id]);
    },
  );

  test(
    'top 50 groups variants, sorts counts and outlives recent history',
    () async {
      final tracks = [
        for (var i = 0; i < 120; i++) _track('$i'),
        _track('alias', title: 'Song 0'),
      ];
      await File('${root.path}/library.json').writeAsString(
        jsonEncode({
          'tracks': tracks.map((t) => t.toJson()).toList(),
          'playlists': [],
          'trackPlayCounts': {
            for (var i = 0; i < 120; i++) '$i': i + 1,
            'alias': 200,
          },
          'recent': [for (var i = 20; i < 120; i++) '$i'],
        }),
      );
      await library.load();
      final top = library.topTracksPlaylist;
      expect(top.isSystem, isTrue);
      expect(top.trackIds.length, 50);
      expect(top.trackIds.first, '0');
      expect(top.trackIds.skip(1).first, '119');
      expect(top.trackIds.last, '71');
      expect(top.trackIds.contains('alias'), isFalse);
      expect(
        library.playlists,
        isEmpty,
        reason: 'Generated playlists are not editable saved data',
      );
      await library.renamePlaylist(top.id, 'changed');
      await library.addToPlaylist(top.id, ['20']);
      await library.deletePlaylist(top.id);
      expect(library.playlistById(top.id)!.trackIds, top.trackIds);
      expect(library.topTracksPlaylist.name, 'Топ-50 на этом устройстве');
    },
  );
}
