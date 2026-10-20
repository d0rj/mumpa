import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/profile_transfer.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/playback_controller.dart';

import 'support.dart';

const _hash = '0123456789abcdef0123456789abcdef01234567';
const _remote = Track(
  id: 'remote',
  title: 'Песня',
  artist: 'Исполнитель',
  album: 'Альбом',
  source: TrackSource.torrent,
  torrentHash: _hash,
  torrentIndex: 1,
  torrentPath: 'Альбом/01 - Песня.flac',
  torrentAlbumPath: 'Альбом',
  albumSource: TrackAlbumSource.tags,
  torrentLink: 'https://private.example/download?passkey=secret',
  cachedPath: 'C:/old-device/downloads/song.flac',
  artPath: 'C:/old-device/artwork/cover.jpg',
  lyrics: 'Текст песни',
  bytes: 12345,
  durationMs: 180000,
);
const _local = Track(
  id: 'local',
  title: 'Мой файл',
  artist: 'Автор',
  album: 'Мой альбом',
  source: TrackSource.local,
  localPath: 'C:/old-device/music/song.mp3',
);

void main() {
  late Directory temporary;
  late LibraryRepository source, target;
  late MusicPlaylist playlist;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('mumpa-transfer-');
    source = LibraryRepository(Directory('${temporary.path}/source'));
    target = LibraryRepository(Directory('${temporary.path}/target'));
    await source.load();
    await target.load();
    await source.upsert([_remote, _local], addToLibrary: true);
    await source.toggleLike(_remote.id);
    await source.toggleLike(_local.id);
    await source.toggleAlbumLike(Album([_remote]));
    playlist = await source.createPlaylist('В дорогу');
    await source.addToPlaylist(playlist.id, [_local.id, _remote.id]);
    await source.togglePlaylistLike(playlist.id);
    await source.markPlayed(_remote.id);
    await source.recordListen(_remote.id, playlistId: playlist.id);
    await source.preferTrackVariant(_remote.id);
    await source.setTrackMatchExcluded(_local.id, true);
    await source.setSetting('volume', .37);
    await source.setSetting('cacheLimitMb', 64);
    await source.setSetting('indexerKey', 'secret-indexer-key');
    await source.setSetting('serverUrl', 'http://old-device:8090');
    await source.setSetting('torrentInterface', 'old-device-wifi');
    await source.setSetting('playback', {
      'originalIds': [_local.id, _remote.id, _local.id],
      'order': [1, 0, 2],
      'unshuffledOrder': [0, 1, 2],
      'index': 0,
      'position': 12345,
      'repeat': 'all',
      'shuffle': true,
      'contextPlaylistId': playlist.id,
      'radioEntries': [2],
    });
  });
  tearDown(() async {
    await source.flush().catchError((Object _) {});
    await target.flush().catchError((Object _) {});
    source.dispose();
    target.dispose();
    await temporary.delete(recursive: true);
  });
  Future<ProfileTransfer> transfer() async =>
      ProfileTransfer.decode(await source.exportProfile());

  test(
    'portable metadata roundtrip preserves personal state and strips device secrets',
    () async {
      final contents = await source.exportProfile();
      expect(contents, isNot(contains('old-device')));
      expect(contents, isNot(contains('secret')));
      expect(contents, isNot(contains('private.example')));
      final exported = ProfileTransfer.decode(contents);
      expect(exported.trackCount, 2);
      expect(exported.localTrackCount, 1);
      await target.importProfile(exported);
      final restarted = LibraryRepository(target.root);
      addTearDown(restarted.dispose);
      await restarted.load();
      expect(restarted.favoriteTracks.map((t) => t.id), ['local', 'remote']);
      expect(restarted.favoriteAlbums.single.tracks.single.id, 'remote');
      expect(restarted.favoritePlaylists.single.trackIds, ['local', 'remote']);
      expect(restarted.playlists.single.name, 'В дорогу');
      expect(
        restarted.byId('remote')!.torrentLink,
        'magnet:?xt=urn:btih:$_hash',
      );
      expect(restarted.byId('remote')!.torrentIndex, 1);
      expect(restarted.byId('remote')!.torrentPath, _remote.torrentPath);
      expect(restarted.byId('remote')!.lyrics, 'Текст песни');
      expect(restarted.byId('local')!.localPath, isNull);
      expect(restarted.byId('remote')!.artPath, isNull);
      expect(restarted.offlineTracks, isEmpty);
      expect(restarted.byId('remote')!.offline, isFalse);
      expect(restarted.mediaTracks.map((t) => t.id).toSet(), {
        'local',
        'remote',
      });
      expect(restarted.isPreferredVariant('remote'), isTrue);
      expect(restarted.isMatchExcluded('local'), isTrue);
      expect(restarted.recent, ['remote']);
      expect(restarted.trackPlayCount('remote'), 1);
      expect(restarted.playlistPlayCount(playlist.id), 1);
      expect(restarted.settings['volume'], .37);
      expect(restarted.settings['indexerKey'], isNull);
    },
  );

  test(
    'merge and repeated import preserve files, edits, order and statistics',
    () async {
      final audio = await File(
        '${temporary.path}/target/saved.flac',
      ).writeAsString('audio');
      await target.upsert([
        _remote.copyWith(cachedPath: audio.path, title: 'Моё название'),
      ]);
      await target.setSetting('serverUrl', 'http://new-device:8090');
      await target.setSetting('volume', .9);
      await target.recordListen('remote');
      await target.recordListen('remote');
      await target.importProfile(await transfer());
      await target.importProfile(await transfer());
      expect(target.tracks.length, 2);
      expect(target.playlists.length, 1);
      expect(target.playlists.single.trackIds, ['local', 'remote']);
      expect(target.favoriteAlbums.length, 1);
      expect(target.trackPlayCount('remote'), 2);
      expect(target.byId('remote')!.cachedPath, audio.path);
      expect(target.byId('remote')!.title, 'Моё название');
      expect(target.settings['serverUrl'], 'http://new-device:8090');
      expect(await audio.readAsString(), 'audio');
      final backups = await Directory(
        '${target.root.path}/backups/before-profile-import',
      ).list().toList();
      expect(backups.length, 2);
      final original =
          jsonDecode(await (backups.first as File).readAsString()) as Map;
      expect(original['settings']['serverUrl'], 'http://new-device:8090');
      expect(original['tracks'][0]['cachedPath'], audio.path);
    },
  );

  test(
    'playlist conflict keeps target order and name and appends missing tracks',
    () async {
      final snapshot = jsonDecode(await source.exportProfile()) as Map;
      final profile = snapshot['profile'] as Map;
      profile['playlists'][0]['trackIds'] = ['remote'];
      await target.importProfile(ProfileTransfer.decode(jsonEncode(snapshot)));
      await target.renamePlaylist(playlist.id, 'Моё имя');
      await target.importProfile(await transfer());
      expect(target.playlists.single.name, 'Моё имя');
      expect(target.playlists.single.trackIds, ['remote', 'local']);
    },
  );

  test('settings opt-out and existing queue survive import', () async {
    await target.setSetting('volume', .9);
    await target.setSetting('playback', {
      'originalIds': ['remote'],
      'index': 0,
    });
    await target.importProfile(await transfer(), includeSettings: false);
    expect(target.settings['volume'], .9);
    await target.importProfile(await transfer());
    expect(target.settings['volume'], .37);
    expect((target.settings['playback'] as Map)['originalIds'], ['remote']);
  });

  test(
    'transferred queue restores duplicates, selection and position without audio I/O',
    () async {
      await target.importProfile(await transfer());
      final audio = FakeAudioBackend();
      final player = PlaybackController(
        library: target,
        torrents: TorrentService(
          endpoint: () async => throw StateError('No network expected'),
        ),
        backend: audio,
      );
      await player.initialize(platformAudio: false);
      addTearDown(player.close);
      expect(player.queue.map((t) => t.id), ['remote', 'local', 'local']);
      expect(player.current!.id, 'remote');
      expect(player.position.inMilliseconds, 12345);
      expect(player.repeat, PlayerRepeatMode.all);
      expect(player.shuffle, isTrue);
      expect(audio.opened, isNull);
      expect(audio.playing, isFalse);
    },
  );

  test(
    'local files reattach to transferred IDs so favorites and playlists still work',
    () async {
      await Directory('${source.root.path}/Album').create();
      await Directory('${target.root.path}/Album').create();
      final original = await File(
        'assets/demo/01 - First light.wav.bin',
      ).copy('${source.root.path}/Album/song.wav');
      final added = (await source.importPaths([original.path])).single;
      await source.toggleLike(added.id);
      await source.addToPlaylist(playlist.id, [added.id]);
      await target.importProfile(await transfer());
      final moved = await original.copy('${target.root.path}/Album/song.wav');
      final attached = (await target.importPaths([moved.path])).single;
      expect(attached.id, added.id);
      expect(target.byId(added.id)!.localPath, moved.path);
      expect(target.isTrackLiked(attached.id), isTrue);
      expect(target.playlists.single.trackIds, contains(attached.id));
      expect(target.tracks.length, source.tracks.length);
    },
  );

  test('invalid transfers fail before changing the profile', () async {
    await target.setSetting('sentinel', 'keep');
    final primary = File('${target.root.path}/library.json');
    final before = await primary.readAsBytes();
    final original = await source.exportProfile();
    for (final mutation in <void Function(Map)>[
      (j) => j['version'] = 999,
      (j) => j['format'] = 'other-app',
      (j) => j['profile']['liked'] = ['missing'],
      (j) => j['profile']['tracks'].add(j['profile']['tracks'][0]),
      (j) => j['profile']['tracks'][0]['id'] = '../outside',
      (j) => j['profile']['settings']['volume'] = 'bad',
      (j) => j['profile']['trackPlayCounts']['remote'] = -1,
      (j) => j['profile']['settings']['playback']['order'] = [999],
      (j) => j['profile'].remove('liked'),
    ]) {
      final j = jsonDecode(original) as Map;
      mutation(j);
      expect(
        () => ProfileTransfer.decode(jsonEncode(j)),
        throwsFormatException,
      );
      expect(await primary.readAsBytes(), before);
      expect(target.tracks, isEmpty);
    }
    expect(() => ProfileTransfer.decode('{broken'), throwsFormatException);
  });

  test(
    'imported paths and connection settings are stripped even in edited files',
    () async {
      final j = jsonDecode(await source.exportProfile()) as Map;
      j['profile']['tracks'][0]['cachedPath'] = '/outside/file';
      j['profile']['tracks'][0]['localPath'] = '/outside/file';
      j['profile']['tracks'][0]['torrentLink'] = 'https://private?token=secret';
      j['profile']['settings']['indexerKey'] = 'secret';
      await target.importProfile(ProfileTransfer.decode(jsonEncode(j)));
      expect(target.byId('remote')!.cachedPath, isNull);
      expect(target.byId('remote')!.localPath, isNull);
      expect(target.byId('remote')!.torrentLink, startsWith('magnet:'));
      expect(target.settings['indexerKey'], isNull);
    },
  );

  test(
    'failed save rolls back in-memory import and keeps full backup',
    () async {
      await target.setSetting('sentinel', 'keep');
      final primary = File('${target.root.path}/library.json');
      final before = await primary.readAsBytes();
      await Directory('${primary.path}.tmp').create();
      await expectLater(
        target.importProfile(await transfer()),
        throwsA(isA<FileSystemException>()),
      );
      expect(target.tracks, isEmpty);
      expect(target.settings['sentinel'], 'keep');
      expect(await primary.readAsBytes(), before);
      expect(
        await Directory(
          '${target.root.path}/backups/before-profile-import',
        ).list().length,
        1,
      );
    },
  );

  test(
    'daily backup failure after primary commit keeps memory consistent with disk',
    () async {
      await target.setSetting('sentinel', 'keep');
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final daily = File('${target.root.path}/backups/library-$day.json');
      await daily.delete();
      await Directory(daily.path).create();
      await expectLater(
        target.importProfile(await transfer()),
        throwsA(isA<FileSystemException>()),
      );
      final persisted =
          jsonDecode(
                await File('${target.root.path}/library.json').readAsString(),
              )
              as Map;
      expect(target.liked.toList(), persisted['liked']);
      expect(target.favoriteTracks.length, 2);
      expect(target.settings['sentinel'], 'keep');
    },
  );

  test(
    'real profile metadata transfers without changing the source file',
    () async {
      final path = Platform.environment['MUMPA_PROFILE_AUDIT'];
      if (path == null) return;
      final original = await File(path).readAsBytes();
      final snapshot =
          jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
      final portable = ProfileTransfer.fromSnapshot(snapshot);
      await target.importProfile(ProfileTransfer.decode(portable.encode()));
      await target.importProfile(ProfileTransfer.decode(portable.encode()));
      expect(target.tracks.length, (snapshot['tracks'] as List).length);
      expect(target.liked.length, (snapshot['liked'] as List).length);
      expect(
        target.favoritePlaylists.length,
        (snapshot['likedPlaylists'] as List).length,
      );
      expect(target.playlists.length, (snapshot['playlists'] as List).length);
      expect(
        target.tracks.any((track) => track.offline || track.artPath != null),
        isFalse,
      );
      expect(await File(path).readAsBytes(), original);
    },
    skip: Platform.environment['MUMPA_PROFILE_AUDIT'] == null,
  );
}
