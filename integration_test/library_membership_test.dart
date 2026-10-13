// Native playback and legacy-profile audit are opt-in and keep user data intact.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/components.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Uint8List _wav() {
  final bytes = Uint8List(44 + 8000 * 2 * 10);
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
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}

class _LocalSource extends TorrentService {
  _LocalSource(this.path)
    : super(endpoint: () async => throw StateError('No network'));
  final String path;
  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) async {
    operation?.check();
    return Uri.file(path);
  }
}

class _OfflineMetadata extends MusicMetadataRepository {
  _OfflineMetadata(Directory root)
    : super(cache: DiskMediaCache(Directory(p.join(root.path, 'metadata'))));
  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('played source album enters personal library on native Windows', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('NATIVE_LIBRARY_MEMBERSHIP_TEST')) return;
    final root = await Directory.systemTemp.createTemp(
      'mumpa-native-membership-',
    );
    final library = LibraryRepository(root);
    await library.load();
    await library.setSetting('autoCache', false);
    await library.setSetting('prefetchTracks', 0);
    await library.setSetting('volume', 0.0);
    final audio = await File(
      p.join(root.path, 'original.wav'),
    ).writeAsBytes(_wav());
    Track track(String id, String album, {String hash = 'found'}) => Track(
      id: id,
      title: id,
      artist: 'Fixture Band',
      album: album,
      source: TrackSource.torrent,
      torrentHash: hash,
      torrentIndex: 1,
      torrentPath: '$album/$id.wav',
      torrentAlbumPath: album,
      albumSource: TrackAlbumSource.directory,
    );
    final tracks = [
      track('First song', 'Selected album'),
      track('Second song', 'Selected album'),
      track('Candidate song', 'Candidate album'),
    ];
    final source = await library.openSourceCollection(
      hash: 'found',
      name: 'Inspected discography',
      tracks: tracks,
    );
    await library.openSourceCollection(
      hash: 'mirror',
      name: 'Inspected mirror',
      tracks: [track('Mirror song', 'Selected album', hash: 'mirror')],
    );
    final torrents = _LocalSource(audio.path);
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: NativeAudioBackend(),
    );
    await playback.initialize(platformAudio: false);
    final app = AppController(
      library: library,
      playback: playback,
      torrents: torrents,
      downloads: DownloadRepository(library, torrents),
      engine: TorrentEngine(root),
      metadata: _OfflineMetadata(root),
    );
    final key = GlobalKey();
    try {
      app.navigate(AppPage.library);
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MumpaApp(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlbumCard), findsNothing);
      expect(find.text('Inspected discography'), findsNothing);
      await tester.runAsync(() async {
        await app.playCollection(tracks, playlistId: source.id);
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (playback.position.inMilliseconds < 300 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      });
      expect(playback.error, isNull);
      expect(app.downloads.jobs, isEmpty);
      expect(playback.playing, isTrue);
      expect(playback.position.inMilliseconds, greaterThan(300));
      expect(app.albums.single.tracks.map((t) => t.id), [
        'First song',
        'Second song',
      ]);
      expect(library.mediaPlaylists.single.id, source.id);
      final position = playback.position.inMilliseconds;
      await playback.pause();
      await tester.pumpAndSettle();
      expect(find.byType(AlbumCard), findsOneWidget);
      expect(find.text('Candidate album'), findsNothing);
      expect(find.text('Inspected mirror'), findsNothing);
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        'test-output/library-membership-native.png',
      ).writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
      final restarted = LibraryRepository(root);
      await restarted.load();
      expect(restarted.mediaTracks.map((t) => t.id), [
        'First song',
        'Second song',
      ]);
      expect(restarted.tracks, hasLength(4));
      restarted.dispose();
      await File('test-output/library-membership-native.json').writeAsString(
        jsonEncode({
          'platform': Platform.operatingSystem,
          'nativePositionMs': position,
          'knownTracks': library.tracks.length,
          'visibleAlbums': app.albums.length,
          'visibleTracks': library.mediaTracks.length,
          'restartPassed': true,
        }),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await app.shutdown();
      library.dispose();
      await root.delete(recursive: true);
    }
  });

  testWidgets(
    'existing profile migration changes only personal library views',
    (tester) async {
      if (!const bool.fromEnvironment('LIVE_LIBRARY_MEMBERSHIP_AUDIT') ||
          !Platform.isWindows) {
        return;
      }
      final support = await getApplicationSupportDirectory();
      final source = File(p.join(support.path, 'Mumpa', 'library.json'));
      final bytes = await source.readAsBytes();
      final profile = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final root = await Directory.systemTemp.createTemp(
        'mumpa-membership-audit-',
      );
      final library = LibraryRepository(root);
      try {
        await File(p.join(root.path, 'library.json')).writeAsBytes(bytes);
        await library.load();
        final knownIds = library.tracks.map((t) => t.id).toSet();
        final mediaIds = library.mediaTracks.map((t) => t.id).toSet();
        expect(
          knownIds,
          (profile['tracks'] as List).map((t) => (t as Map)['id']).toSet(),
        );
        expect(library.playlists.length, (profile['playlists'] as List).length);
        expect(
          mediaIds.containsAll(library.favoriteTracks.map((t) => t.id)),
          isTrue,
        );
        expect(
          mediaIds.containsAll(
            library.favoriteAlbums.expand((a) => a.tracks).map((t) => t.id),
          ),
          isTrue,
        );
        expect(
          mediaIds.containsAll(library.offlineTracks.map((t) => t.id)),
          isTrue,
        );
        expect(
          mediaIds.containsAll(library.recent.where(knownIds.contains)),
          isTrue,
        );
        await library.setSetting('membershipAudit', true);
        final restarted = LibraryRepository(root);
        await restarted.load();
        expect(restarted.mediaTracks.map((t) => t.id).toSet(), mediaIds);
        restarted.dispose();
        final unchanged =
            sha256.convert(await source.readAsBytes()) == sha256.convert(bytes);
        // Another running Mumpa may save playback while this read-only audit
        // runs. Its hash is diagnostic; only the temporary copy is opened.
        expect(library.root.path, isNot(source.parent.path));
        await File(
          'test-output/library-membership-profile-audit.json',
        ).writeAsString(
          jsonEncode({
            'knownTracks': library.tracks.length,
            'visibleTracks': library.mediaTracks.length,
            'knownAlbums': library.albums.length,
            'visibleAlbums': library.mediaAlbums.length,
            'knownPlaylists': library.playlists.length,
            'visiblePlaylists': library.mediaPlaylists.length,
            'favoriteTracks': library.favoriteTracks.length,
            'favoriteAlbums': library.favoriteAlbums.length,
            'offlineTracks': library.offlineTracks.length,
            'productionHashUnchangedDuringAudit': unchanged,
            'productionRepositoryOpened': false,
            'restartPassed': true,
          }),
        );
      } finally {
        await library.flush();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
