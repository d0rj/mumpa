import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/pages.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

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
  @override
  Future<String?> coverForGroup(String id) async => null;
  @override
  Future<String?> coverForReleaseTitle(String title) async => null;
}

Future<AppController> _app() async {
  final root = await Directory.systemTemp.createTemp('mumpa-offline-order-ui-');
  final library = LibraryRepository(root);
  await library.load();
  await library.setSetting('autoCache', false);
  final path = (await File('${root.path}/fixture.wav').writeAsBytes([0])).path;
  await library.upsert([
    for (final (id, day) in [('old', 10), ('new', 13), ('middle', 12)])
      Track(
        id: id,
        title: 'Saved $id',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.torrent,
        cachedPath: path,
        downloadedAt: DateTime.utc(2026, 10, day),
      ),
  ]);
  MockClient offlineClient() => MockClient((_) async {
    throw StateError('Sorting and filtering must stay offline');
  });
  final torrents = TorrentService(
    client: offlineClient(),
    endpoint: () async => throw StateError('No torrent engine needed'),
  );
  final playback = PlaybackController(
    library: library,
    torrents: torrents,
    backend: FakeAudioBackend(),
  );
  await playback.initialize(platformAudio: false);
  return AppController(
    library: library,
    playback: playback,
    downloads: DownloadRepository(library, torrents),
    torrents: torrents,
    engine: TorrentEngine(root),
    indexer: IndexerService(client: offlineClient()),
    metadata: _Metadata(root, offlineClient()),
  )..navigate(AppPage.downloads);
}

void main() {
  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'latest downloads stay above older downloads and search at $width px',
      (tester) async {
        final app = (await tester.runAsync(_app))!;
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await app.shutdown();
            app.library.dispose();
            await app.library.root.delete(recursive: true);
          });
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: mumpaTheme(),
            home: Scaffold(
              body: ListenableBuilder(
                listenable: app,
                builder: (_, _) => ContentPage(app: app),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        void expectOrder() {
          expect(app.offlineSearchTracks.map((track) => track.id), [
            'new',
            'middle',
            'old',
          ]);
          final positions = [
            for (final id in ['new', 'middle', 'old'])
              tester.getTopLeft(find.byKey(ValueKey('track-row-$id'))).dy,
          ];
          expect(positions[0], lessThan(positions[1]));
          expect(positions[1], lessThan(positions[2]));
        }

        expectOrder();
        await tester.enterText(
          find.byKey(const ValueKey('local-search-downloads')),
          'saved',
        );
        await tester.pumpAndSettle();
        expectOrder();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
