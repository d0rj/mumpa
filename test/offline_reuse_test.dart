import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:path/path.dart' as p;

import 'support.dart';

class _NoNetwork extends TorrentService {
  _NoNetwork() : super(endpoint: () async => throw StateError('No engine'));
  int calls = 0;
  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) async {
    calls++;
    throw StateError('No torrent network');
  }
}

Track _track(String id, {String hash = 'source', String path = 'Song.wav'}) =>
    Track(
      id: id,
      title: 'Song',
      artist: 'Band',
      album: 'Album $id',
      source: TrackSource.torrent,
      torrentHash: hash,
      torrentPath: path,
      torrentIndex: 1,
      bytes: 4,
      albumSource: TrackAlbumSource.directory,
      durationMs: 180000,
    );

void main() {
  late Directory root;
  late LibraryRepository library;
  late _NoNetwork torrents;
  late DownloadRepository downloads;
  late FakeAudioBackend audio;
  late PlaybackController player;
  late AppController app;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-offline-reuse-');
    library = LibraryRepository(root);
    await library.load();
    torrents = _NoNetwork();
    downloads = DownloadRepository(library, torrents);
    await downloads.restore();
    audio = FakeAudioBackend();
    player = PlaybackController(
      library: library,
      torrents: torrents,
      backend: audio,
    );
    await player.initialize(platformAudio: false);
    final metadata = MusicMetadataRepository(
      cache: DiskMediaCache(Directory('${root.path}/metadata')),
      client: MockClient((_) async => throw StateError('No HTTP')),
    );
    app = AppController(
      library: library,
      playback: player,
      downloads: downloads,
      torrents: torrents,
      engine: TorrentEngine(root),
      metadata: metadata,
    );
  });

  tearDown(() async {
    await app.shutdown();
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<File> cache(Track track) async {
    final file = await File(
      '${library.downloads.path}/${track.id}.wav',
    ).writeAsBytes([1, 2, 3, 4]);
    await library.upsert([track.copyWith(cachedPath: file.path)]);
    return file;
  }

  test(
    'stale records in two playlists use the latest downloaded file',
    () async {
      final stale = _track('song');
      await library.upsert([stale]);
      final first = await library.createPlaylist('First');
      final second = await library.createPlaylist('Second');
      await library.addToPlaylist(first.id, [stale.id]);
      await library.addToPlaylist(second.id, [stale.id]);
      final file = await cache(stale);
      expect(await player.resolve(stale), Uri.file(file.path).toString());
      await app.playCollection([stale], playlistId: second.id);
      expect(player.playing, isTrue);
      expect(audio.opened, Uri.file(file.path).toString());
      expect(downloads.jobs, isEmpty);
      expect(torrents.calls, 0);
      expect(library.playlists.map((item) => item.trackIds), [
        ['song'],
        ['song'],
      ]);
    },
  );

  test('identical torrent file aliases reuse a global local copy', () async {
    final original = _track('original', path: 'folder/Song.wav');
    final alias = _track('alias', hash: 'SOURCE', path: r'folder\Song.wav');
    final differentSource = _track('other', hash: 'another');
    await library.upsert([original, alias, differentSource]);
    final file = await cache(original);
    expect(await player.resolve(alias), Uri.file(file.path).toString());
    await player.playTracks([alias]);
    expect(player.current!.id, alias.id);
    expect(audio.opened, Uri.file(file.path).toString());
    expect(downloads.jobs, isEmpty);
    downloads.enqueue([alias]);
    expect(downloads.jobs, isEmpty);
    expect(torrents.calls, 0);
    await expectLater(player.resolve(differentSource), throwsStateError);
    expect(torrents.calls, 1);
  });

  test(
    'default uses another collection offline version, picker stays exact',
    () async {
      final remote = _track('remote');
      final offline = _track('offline', hash: 'other-release');
      await library.upsert([remote, offline]);
      final file = await cache(offline);
      final source = await library.createPlaylist('Remote collection');
      final saved = await library.createPlaylist('Downloaded collection');
      await library.addToPlaylist(source.id, [remote.id]);
      await library.addToPlaylist(saved.id, [offline.id]);
      await library.preferTrackVariant(remote.id);
      expect(library.matchedTracks([remote]).single.preferred.id, offline.id);
      await app.playCollection([remote], playlistId: source.id);
      expect(player.current!.id, offline.id);
      expect(audio.opened, Uri.file(file.path).toString());
      expect(downloads.jobs, isEmpty);
      expect(torrents.calls, 0);
      expect(library.playlists.first.trackIds, [remote.id]);
      await app.playCollection([remote], selectedVariant: remote);
      expect(player.current!.id, remote.id);
      expect(player.error, isNotNull);
      expect(torrents.calls, 1);
      expect(library.isPreferredVariant(remote.id), isTrue);
    },
  );

  test(
    'missing cached candidate falls back to an existing offline version',
    () async {
      final missing = _track('missing');
      final available = _track('available', hash: 'another');
      final remote = _track('remote', hash: 'remote');
      await library.upsert([missing, available, remote]);
      final missingFile = await cache(missing);
      final file = await cache(available);
      await missingFile.delete();
      await library.preferTrackVariant(missing.id);
      await app.playCollection([remote]);
      expect(player.current!.id, available.id);
      expect(audio.opened, Uri.file(file.path).toString());
      expect(torrents.calls, 0);
      expect(downloads.jobs, isEmpty);
    },
  );

  test(
    'startup recovers only known-size final files, never partials',
    () async {
      final recovered = _track('recovered');
      final short = _track('short');
      final partial = _track('partial');
      final unknown = Track.fromJson({
        ..._track('unknown').toJson(),
        'bytes': 0,
      });
      await library.upsert([recovered, short, partial, unknown]);
      final good = await File(
        '${library.downloads.path}/recovered.wav',
      ).writeAsBytes([1, 2, 3, 4]);
      await File('${library.downloads.path}/short.wav').writeAsBytes([1, 2]);
      await File(
        '${library.downloads.path}/partial.wav.part',
      ).writeAsBytes([1, 2, 3, 4]);
      await File(
        '${library.downloads.path}/unknown.wav',
      ).writeAsBytes([1, 2, 3, 4]);
      await downloads.restore();
      expect(
        p.equals(library.byId(recovered.id)!.cachedPath!, good.path),
        isTrue,
      );
      expect(library.byId(short.id)!.offline, isFalse);
      expect(library.byId(partial.id)!.offline, isFalse);
      expect(library.byId(unknown.id)!.offline, isFalse);
      expect(downloads.jobs.single.track.id, partial.id);
      expect(downloads.jobs.single.state, DownloadState.paused);
      final fresh = LibraryRepository(root);
      await fresh.load();
      expect(
        p.equals(fresh.byId(recovered.id)!.cachedPath!, good.path),
        isTrue,
      );
      fresh.dispose();
      expect(await player.resolve(recovered), Uri.file(good.path).toString());
      expect(torrents.calls, 0);
    },
  );

  test(
    'favorites and downloads survive album removal, quotas and restart',
    () async {
      final liked = _track('liked');
      final downloaded = _track('downloaded');
      final albumLiked = _track('album-liked');
      final playlistLiked = _track('playlist-liked');
      final removable = _track('removable');
      await library.upsert([
        liked,
        downloaded,
        albumLiked,
        playlistLiked,
        removable,
      ]);
      final file = await cache(downloaded);
      await library.toggleLike(liked.id);
      await library.toggleAlbumLike(library.albumById(albumLiked.albumKey)!);
      final playlist = await library.createPlaylist('Favorites');
      await library.addToPlaylist(playlist.id, [
        playlistLiked.id,
        removable.id,
      ]);
      await library.togglePlaylistLike(playlist.id);
      // Membership in a favorite playlist is protected, even without a track heart.
      await library.removeTracks(library.tracks.map((track) => track.id));
      expect(library.tracks, hasLength(5));
      await library.togglePlaylistLike(playlist.id);
      await library.removeTracks([removable.id]);
      expect(library.byId(removable.id), isNull);
      await library.setSetting('cacheLimitMb', 0);
      await app.metadata.cache.clear();
      await downloads.removeOffline(downloaded);
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
      expect(library.byId(downloaded.id)!.cachedPath, file.path);
      final fresh = LibraryRepository(root);
      await fresh.load();
      expect(fresh.liked, {liked.id});
      expect(fresh.byId(downloaded.id)!.cachedPath, file.path);
      expect(fresh.favoriteAlbums.single.tracks.single.id, albumLiked.id);
      fresh.dispose();
    },
  );

  test(
    'manual removal retains any other reference to the same offline file',
    () async {
      final first = _track('first');
      final second = _track('second');
      await library.upsert([first, second]);
      final file = await cache(first);
      await library.upsert([second.copyWith(cachedPath: file.path)]);
      await downloads.removeOffline(first, userRequested: true);
      expect(library.byId(first.id)!.cachedPath, isNull);
      expect(await file.exists(), isTrue);
      expect(await player.resolve(second), Uri.file(file.path).toString());
      await downloads.removeOffline(second, userRequested: true);
      expect(await file.exists(), isFalse);
      expect(library.byId(second.id)!.cachedPath, isNull);
    },
  );
}
