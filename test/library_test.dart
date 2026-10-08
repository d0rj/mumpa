import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  late Directory root;
  late LibraryRepository library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-library-');
    library = LibraryRepository(root);
    await library.load();
  });
  tearDown(() async {
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  });
  const first = Track(
    id: 'a',
    title: 'First',
    artist: 'Guest',
    albumArtist: 'Band',
    album: 'Album',
    source: TrackSource.local,
    number: 2,
    disc: 1,
  );
  const second = Track(
    id: 'b',
    title: 'Second',
    artist: 'Band',
    albumArtist: 'Band',
    album: 'Album',
    source: TrackSource.local,
    number: 1,
    disc: 1,
  );
  const third = Track(
    id: 'c',
    title: 'Third',
    artist: 'Band',
    albumArtist: 'Band',
    album: 'Album',
    source: TrackSource.local,
    number: 1,
    disc: 2,
  );
  test('metadata round trip and compilation grouping with disc ordering', () {
    expect(Track.fromJson(first.toJson()).albumArtist, 'Band');
    final albums = groupAlbums([third, first, second]);
    expect(albums.length, 1);
    expect(albums.single.tracks.map((t) => t.id), ['b', 'a', 'c']);
  });
  test('library, likes, playlists and playback survive restart', () async {
    await library.upsert([first, second, third]);
    await library.toggleLike(first.id);
    final playlist = await library.createPlaylist('Road');
    await library.addToPlaylist(playlist.id, [first.id, first.id, third.id]);
    await library.setSetting('playback', {
      'ids': ['a', 'b'],
      'index': 1,
      'position': 4000,
    });
    final fresh = LibraryRepository(root);
    await fresh.load();
    expect(fresh.tracks.length, 3);
    expect(fresh.liked, {'a'});
    expect(fresh.playlists.single.trackIds, ['a', 'c']);
    expect((fresh.settings['playback'] as Map)['position'], 4000);
    fresh.dispose();
    await library.removeTracks(['a']);
    expect(library.playlists.single.trackIds, ['c']);
    expect(library.liked, isEmpty);
  });
  test('corrupt primary recovers from the preserved backup', () async {
    await library.upsert([first]);
    await library.toggleLike('a');
    await File('${root.path}/library.json').writeAsString('{broken');
    final fresh = LibraryRepository(root);
    await fresh.load();
    expect(fresh.tracks.single.id, 'a');
    expect(fresh.loadWarning, contains('восстановлена'));
    fresh.dispose();
  });
  test(
    'loading defaults does not overwrite an unrecoverable library',
    () async {
      final file = File('${root.path}/library.json');
      await file.writeAsString('{broken');
      final fresh = LibraryRepository(root);
      await fresh.load();
      expect(fresh.settings['autoCache'], isTrue);
      expect(fresh.loadWarning, isNotNull);
      expect(await file.readAsString(), '{broken');
      fresh.dispose();
    },
  );
  test(
    'auto-save defaults on and respects an explicit opt-out across restart',
    () async {
      expect(library.settings['autoCache'], isTrue);
      await library.setSetting('autoCache', false);
      final fresh = LibraryRepository(root);
      await fresh.load();
      expect(fresh.settings['autoCache'], isFalse);
      fresh.dispose();
    },
  );
  test(
    'source collection survives edits and restart without duplicates or lost cached tags',
    () async {
      final collection = await library.openSourceCollection(
        hash: 'source',
        name: 'Collection',
        tracks: [first, second],
      );
      await library.renamePlaylist(collection.id, 'Renamed');
      await library.removeFromPlaylist(collection.id, first.id);
      await library.addToPlaylist(collection.id, [third.id]);
      await library.upsert([
        first.copyWith(
          title: 'Read from tags',
          cachedPath: '${root.path}/cached.wav',
        ),
      ]);
      await File('${root.path}/cached.wav').writeAsBytes([1]);
      await library.openSourceCollection(
        hash: 'source',
        name: 'Original',
        tracks: [first, second],
      );
      expect(library.playlists.length, 1);
      expect(library.playlists.single.name, 'Renamed');
      expect(library.playlists.single.sourceHash, 'source');
      expect(library.playlists.single.trackIds, ['b', 'c']);
      expect(library.byId('a')!.title, 'Read from tags');
      final fresh = LibraryRepository(root);
      await fresh.load();
      expect(fresh.playlists.single.sourceHash, 'source');
      expect(fresh.byId('a')!.cachedPath, isNotNull);
      fresh.dispose();
      await library.removeTracks(['b']);
      expect(library.playlists.single.sourceHash, 'source');
    },
  );
  test(
    'untagged audio is imported and deduplicated without modifying the source',
    () async {
      final file = File('${root.path}/01 - Untagged.wav');
      await file.writeAsBytes(List.filled(100, 0));
      await library.importPaths([file.path]);
      await library.importPaths([file.path]);
      expect(library.tracks.length, 1);
      expect(library.tracks.single.title, 'Untagged');
      expect(library.tracks.single.number, 1);
      expect(await file.exists(), isTrue);
      await library.removeTracks([library.tracks.single.id]);
      expect(await file.exists(), isTrue);
    },
  );
}
