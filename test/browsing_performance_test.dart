import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';

import 'support.dart';

void main() {
  test('unchanged browsing views benchmark on 10k tracks', () async {
    final root = await Directory.systemTemp.createTemp('mumpa-browsing-');
    final tracks = List.generate(
      10000,
      (i) => Track(
        id: '$i',
        title: 'Song $i',
        artist: 'Band ${i % 50}',
        album: 'Album ${i ~/ 20}',
        source: TrackSource.local,
      ),
    );
    await File('${root.path}/library.json').writeAsString(
      jsonEncode({
        'tracks': tracks.map((track) => track.toJson()).toList(),
        'liked': ['1', '2'],
        'recent': ['0', '21'],
      }),
    );
    final library = LibraryRepository(root);
    await library.load();
    final torrents = TorrentService(endpoint: () async => 'http://localhost');
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    final app = AppController(
      library: library,
      playback: playback,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
    );
    addTearDown(() async {
      await app.shutdown();
      library.dispose();
      await root.delete(recursive: true);
    });
    app.selectedAlbum = tracks.first.albumKey;
    final counts = <int>[];
    for (final read in <int Function()>[
      () => app.album!.tracks.length,
      () => app.recentAlbums.length,
      () => app.librarySearchResults.tracks.length,
      () => app.likedSearchResults.tracks.length,
    ]) {
      read();
      final watch = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        read();
      }
      counts.add(watch.elapsedMicroseconds);
    }
    expect(app.librarySearchResults.tracks, hasLength(10000));
    expect(app.likedSearchResults.tracks.map((track) => track.id), ['2', '1']);
    // Timings are diagnostic; correctness never depends on machine speed.
    // ignore: avoid_print
    print('BROWSING_PERF 100_reads_us=$counts (album,recent,library,liked)');
    final originalAlbum = app.album!;
    app.setLocalQuery('library', '9999');
    expect(app.librarySearchResults.tracks.single.id, '9999');
    app.setLocalQuery('library', '');
    await library.toggleLike('3');
    expect(app.likedSearchResults.tracks.map((track) => track.id), [
      '3',
      '2',
      '1',
    ]);
    final playlist = await library.createPlaylist('Saved selection');
    await library.addToPlaylist(playlist.id, ['4']);
    await library.togglePlaylistLike(playlist.id);
    expect(app.likedSearchResults.tracks.map((track) => track.id), [
      '3',
      '2',
      '1',
      '4',
    ]);
    await library.removeFromPlaylist(playlist.id, '4');
    expect(app.likedSearchResults.tracks.map((track) => track.id), [
      '3',
      '2',
      '1',
    ]);
    await library.upsert([tracks.first.copyWith(title: 'Updated song')]);
    expect(
      app.album!.tracks,
      contains(predicate<Track>((track) => track.title == 'Updated song')),
    );
    expect(originalAlbum.tracks.first.title, 'Song 0');
    expect(
      app.recentAlbums.first.tracks,
      contains(predicate<Track>((track) => track.title == 'Updated song')),
    );
    await library.toggleLike('1');
    await library.removeTracks(['1']);
    expect(app.likedSearchResults.tracks.map((track) => track.id), ['3', '2']);
  });
}
