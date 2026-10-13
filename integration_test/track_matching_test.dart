// Opt-in native decoder/UI proof using an isolated profile and generated silent
// WAVs. An optional production audit reads track metadata only, never settings,
// source links or credentials, and verifies that the profile is unchanged.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/track_matching.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/theme.dart';

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root, MockClient client)
    : super(
        cache: DiskMediaCache(Directory('${root.path}/metadata')),
        client: client,
      );
  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

Uint8List _silence(int seconds) {
  const rate = 8000;
  final bytes = Uint8List(44 + rate * 2 * seconds);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('TRACK_MATCHING_NATIVE');
  if (enabled && Platform.isWindows) MediaKit.ensureInitialized();
  testWidgets(
    'another playlist reuses offline audio with no torrent requests',
    (tester) async {
      if (!enabled || !Platform.isWindows) return;
      final root = await Directory(
        'D:/Projects/mumpa/.local',
      ).createTemp('offline-native-');
      final library = LibraryRepository(root);
      await library.load();
      await library.setSetting('volume', 0.0);
      var networkCalls = 0;
      final client = MockClient((_) async {
        networkCalls++;
        throw StateError('No HTTP expected');
      });
      final torrents = TorrentService(
        client: client,
        endpoint: () async {
          networkCalls++;
          throw StateError('No engine expected');
        },
      );
      await library.downloads.create(recursive: true);
      final bytes = _silence(20);
      final file = await File(
        '${library.downloads.path}/saved.wav',
      ).writeAsBytes(bytes);
      final tracks = [
        Track(
          id: 'stream',
          title: 'Same song',
          artist: 'Band',
          album: 'Online collection',
          source: TrackSource.torrent,
          torrentHash: 'stream-source',
          torrentPath: 'Song.wav',
          durationMs: 20000,
          bytes: bytes.length,
          albumSource: TrackAlbumSource.directory,
        ),
        Track(
          id: 'saved',
          title: 'Same song',
          artist: 'Band',
          album: 'Downloaded collection',
          source: TrackSource.torrent,
          torrentHash: 'saved-source',
          torrentPath: 'Song.wav',
          cachedPath: file.path,
          durationMs: 20000,
          bytes: bytes.length,
          albumSource: TrackAlbumSource.directory,
        ),
      ];
      await library.upsert(tracks);
      final online = await library.createPlaylist('Online');
      final offline = await library.createPlaylist('Offline');
      await library.addToPlaylist(online.id, ['stream']);
      await library.addToPlaylist(offline.id, ['saved']);
      await library.toggleLike('saved');
      await library.preferTrackVariant('stream');
      final playback = PlaybackController(
        library: library,
        torrents: torrents,
        backend: NativeAudioBackend(),
      );
      await playback.initialize(platformAudio: false);
      final downloads = DownloadRepository(library, torrents);
      final app = AppController(
        library: library,
        playback: playback,
        downloads: downloads,
        torrents: torrents,
        engine: TorrentEngine(root),
        metadata: _Metadata(root, client),
        indexer: IndexerService(client: client),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        library.dispose();
        await root.delete(recursive: true);
      });
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Offline playback'))),
      );
      for (final playlist in [online, offline]) {
        final currentPlaylist = library.playlists.singleWhere(
          (item) => item.id == playlist.id,
        );
        await app.playCollection(
          currentPlaylist.trackIds
              .map(library.byId)
              .whereType<Track>()
              .toList(),
          playlistId: playlist.id,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (playback.position <= const Duration(milliseconds: 250) &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(playback.current!.id, 'saved');
        expect(playback.playing, isTrue);
        expect(
          playback.position,
          greaterThan(const Duration(milliseconds: 250)),
        );
        expect(playback.error, isNull);
        expect(downloads.jobs, isEmpty);
        await playback.pause();
      }
      await library.removeTracks(['saved']);
      await downloads.removeOffline(tracks.last);
      await library.setSetting('cacheLimitMb', 0);
      expect(library.byId('saved')!.cachedPath, file.path);
      expect(await file.readAsBytes(), bytes);
      expect(library.playlists.map((item) => item.trackIds), [
        ['stream'],
        ['saved'],
      ]);
      expect(networkCalls, 0);
      await File(
        'D:/Projects/mumpa/test-output/offline-native.json',
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'nativeDecoder': 'Windows/libmpv',
          'playedPlaylists': 2,
          'selectedTrack': 'saved',
          'networkCalls': networkCalls,
          'downloadJobs': downloads.jobs.length,
          'protectedFileBytes': bytes.length,
          'playlistMembershipPreserved': true,
          'likesPreserved': library.liked.contains('saved'),
        }),
      );
    },
  );
  testWidgets('known versions render and play through native decoder', (
    tester,
  ) async {
    if (!enabled || !Platform.isWindows) return;
    final output = Directory('D:/Projects/mumpa/test-output')
      ..createSync(recursive: true);
    final root = await Directory(
      'D:/Projects/mumpa/.local',
    ).createTemp('matching-native-');
    final library = LibraryRepository(root);
    await library.load();
    await library.setSetting('autoCache', false);
    await library.setSetting('volume', 0.0);
    var networkCalls = 0;
    final client = MockClient((_) async {
      networkCalls++;
      throw StateError('No HTTP expected');
    });
    final torrents = TorrentService(
      client: client,
      endpoint: () async {
        networkCalls++;
        throw StateError('No engine expected');
      },
    );
    final tracks = <Track>[];
    for (final (id, title, album, seconds) in [
      ('clean', 'Один и тот же трек (Clean)', 'Первый альбом', 20),
      ('explicit', 'Один и тот же трек [Explicit]', 'Сборник лучших песен', 21),
      ('next', 'Следующая песня', 'Первый альбом', 20),
      ('live', 'Один и тот же трек (Live)', 'Концертная запись', 21),
    ]) {
      final file = await File(
        '${root.path}/$id.wav',
      ).writeAsBytes(_silence(seconds));
      tracks.add(
        Track(
          id: id,
          title: title,
          artist: 'Тестовая группа',
          album: album,
          source: TrackSource.local,
          localPath: file.path,
          durationMs: seconds * 1000,
          bytes: await file.length(),
        ),
      );
    }
    await library.upsert(tracks);
    final playlist = await library.createPlaylist('Известная коллекция');
    await library.addToPlaylist(playlist.id, ['clean', 'next']);
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: NativeAudioBackend(),
    );
    await playback.initialize(platformAudio: false);
    final app = AppController(
      library: library,
      playback: playback,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
      indexer: IndexerService(client: client),
      metadata: _Metadata(root, client),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await app.shutdown();
      library.dispose();
      await root.delete(recursive: true);
    });
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: mumpaTheme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Известные версии треков',
                          style: mumpaTheme().textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 12),
                        Text(library.trackCountLabel(tracks)),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                  TrackList(app: app, tracks: tracks, playlistId: playlist.id),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    Future<void> snapshot(String name) async {
      await tester.pump(const Duration(milliseconds: 200));
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${output.path}/$name.png',
      ).writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    }

    await snapshot('track-matching-rows');
    await tester.tap(find.byKey(const ValueKey('track-versions-clean')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.byKey(const ValueKey('known-version-explicit')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('known-version-live')), findsNothing);
    await snapshot('track-matching-picker');
    await tester.tap(find.byKey(const ValueKey('play-known-version-explicit')));
    Future<void> waitForAudio(String id) async {
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 10)) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        if (playback.current?.id == id &&
            playback.playing &&
            playback.position.inMilliseconds > 100) {
          return;
        }
      }
      fail('Native $id did not start: ${playback.error}');
    }

    await waitForAudio('explicit');
    expect(playback.queue.map((track) => track.id), [
      'explicit',
      'next',
      'live',
    ]);
    expect(library.playlists.single.trackIds, ['clean', 'next']);
    final explicitDuration = playback.duration.inMilliseconds;
    expect(explicitDuration, inInclusiveRange(20900, 21100));
    await tester.tap(find.byKey(const ValueKey('track-cover-play-clean')));
    await waitForAudio('clean');
    final cleanDuration = playback.duration.inMilliseconds;
    expect(cleanDuration, inInclusiveRange(19900, 20100));
    expect(networkCalls, 0);
    expect(tester.takeException(), isNull);

    final report = <String, dynamic>{
      'nativeDecoder': 'libmpv',
      'chosenVariant': 'explicit',
      'explicitDurationMs': explicitDuration,
      'coverPlayVariant': 'clean',
      'cleanDurationMs': cleanDuration,
      'queueGroups': playback.queue.length,
      'originalPlaylistIds': library.playlists.single.trackIds,
      'networkCalls': networkCalls,
    };
    if (const bool.fromEnvironment('REAL_TRACK_MATCH_AUDIT')) {
      final profile = File(
        '${Platform.environment['APPDATA']}/app.mumpa/mumpa/Mumpa/library.json',
      );
      final before = await profile.readAsString();
      final saved = jsonDecode(before) as Map<String, dynamic>;
      final known = (saved['tracks'] as List)
          .map(
            (value) => Track.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList();
      final watch = Stopwatch()..start();
      await prepareTrackMatching(known);
      final index = TrackMatchIndex(
        known,
        sourceDescriptions: {
          for (final value in (saved['playlists'] as List))
            if ((value as Map)['sourceHash'] != null)
              value['sourceHash'] as String: value['name'] as String,
        },
      );
      final rows = index.rowsFor(known);
      report['readOnlyAudit'] = {
        'files': known.length,
        'groups': rows.length,
        'multipleGroups': rows.where((row) => row.group.multiple).length,
        'prepareAndGroupMs': watch.elapsedMilliseconds,
        'durationKnownFiles': known
            .where((track) => track.durationMs > 0)
            .length,
        'examples': rows
            .where((row) => row.group.multiple)
            .take(20)
            .map(
              (row) => {
                'artist': row.anchor.artist,
                'title': row.anchor.title,
                'variants': row.group.variants
                    .map(
                      (track) => {
                        'format': track.format,
                        'album': track.album,
                        'durationMs': track.durationMs,
                      },
                    )
                    .toList(),
              },
            )
            .toList(),
      };
      expect(
        await profile.readAsString(),
        before,
        reason: 'The production profile is read-only',
      );
    }
    await File(
      '${output.path}/track-matching-native.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  });
}
