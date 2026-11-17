import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/catalog_repository.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/catalog_matching.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/catalog_match_dialog.dart';
import 'package:mumpa/ui/theme.dart';

import 'catalog_matching_test.dart' show song, recording;
import 'support.dart';

class _Catalog extends CatalogRepository {
  _Catalog(MusicMetadataRepository metadata) : super(musicBrainz: metadata);
  @override
  Future<CatalogMatchResult> match(
    Track track, {
    SourceOperation? operation,
  }) async => CatalogMatchResult(rankCatalogMatches(track, [recording]), [
    'MusicBrainz',
  ]);
  @override
  Future<MusicRecording> details(
    MusicRecording recording, {
    SourceOperation? operation,
  }) async => recording;
}

void main() {
  for (final size in [const Size(320, 640), const Size(1200, 800)]) {
    testWidgets('catalog selection persists and can be removed at $size', (
      tester,
    ) async {
      final app = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('mumpa-catalog-ui-');
        final library = LibraryRepository(root);
        await library.load();
        await library.upsert([song]);
        final torrents = TorrentService(
          endpoint: () async => 'http://localhost',
        );
        final playback = PlaybackController(
          library: library,
          torrents: torrents,
          backend: FakeAudioBackend(),
        );
        await playback.initialize(platformAudio: false);
        final metadata = MusicMetadataRepository(
          cache: DiskMediaCache(Directory('${root.path}/metadata')),
        );
        return AppController(
          library: library,
          playback: playback,
          downloads: DownloadRepository(library, torrents),
          torrents: torrents,
          engine: TorrentEngine(root),
          metadata: metadata,
          musicCatalog: _Catalog(metadata),
        );
      }))!;
      final library = app.library;
      final root = library.root;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await app.shutdown();
          library.dispose();
          await root.delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: mumpaTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCatalogMatchDialog(
                  context,
                  app,
                  library.byId(song.id)!,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Часть каталогов недоступна'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final saved = Completer<void>();
        void onSave() {
          if (!saved.isCompleted) saved.complete();
        }

        library.addListener(onSave);
        try {
          await tester.tap(find.byTooltip('Связать с этой записью'));
          await saved.future.timeout(const Duration(seconds: 5));
        } finally {
          library.removeListener(onSave);
        }
      });
      await tester.pumpAndSettle();
      expect(library.byId(song.id)!.catalogLink!.recording.key, recording.key);
      expect(library.byId(song.id)!.catalogLink!.manual, isTrue);
      await tester.runAsync(() async {
        final reloaded = LibraryRepository(root);
        await reloaded.load();
        expect(
          reloaded.byId(song.id)!.catalogLink!.recording.key,
          recording.key,
        );
        reloaded.dispose();
      });
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Выбрано вручную'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final saved = Completer<void>();
        void onSave() {
          if (!saved.isCompleted) saved.complete();
        }

        library.addListener(onSave);
        try {
          await tester.tap(find.text('Удалить привязку'));
          await saved.future.timeout(const Duration(seconds: 5));
        } finally {
          library.removeListener(onSave);
        }
      });
      await tester.pumpAndSettle();
      expect(library.byId(song.id)!.catalogLink, isNull);
      expect(library.byId(song.id)!.catalogMatchingDisabled, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
