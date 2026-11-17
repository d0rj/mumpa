import 'dart:async';
import 'dart:io';

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
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';

import 'catalog_matching_test.dart' show song, recording;
import 'support.dart';

class _Audio extends FakeAudioBackend {
  @override
  Duration get duration => song.duration;
}

class _Catalog extends CatalogRepository {
  _Catalog(MusicMetadataRepository metadata) : super(musicBrainz: metadata);
  final called = Completer<void>();
  final response = Completer<CatalogMatchResult>();
  int calls = 0;
  bool closed = false;
  @override
  void dispose() {
    closed = true;
    super.dispose();
  }

  @override
  Future<CatalogMatchResult> match(Track track, {SourceOperation? operation}) {
    calls++;
    if (!called.isCompleted) called.complete();
    return response.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final outcome in ['accept', 'disable', 'shutdown']) {
    test('playing track enriches once; pending outcome=$outcome', () async {
      final root = await Directory.systemTemp.createTemp(
        'mumpa-catalog-playing-',
      );
      final library = LibraryRepository(root);
      await library.load();
      final media = await File('${root.path}/test.mp3').writeAsBytes([1, 2, 3]);
      final track = song.copyWith(localPath: media.path);
      await library.upsert([track]);
      final torrents = TorrentService(endpoint: () async => 'http://localhost');
      final audio = _Audio();
      final playback = PlaybackController(
        library: library,
        torrents: torrents,
        backend: audio,
      );
      await playback.initialize(platformAudio: false);
      final metadata = MusicMetadataRepository(
        cache: DiskMediaCache(Directory('${root.path}/metadata')),
      );
      final catalog = _Catalog(metadata);
      final app = AppController(
        library: library,
        playback: playback,
        downloads: DownloadRepository(library, torrents),
        torrents: torrents,
        engine: TorrentEngine(root),
        metadata: metadata,
        musicCatalog: catalog,
      );
      try {
        await playback.playTracks([track]);
        await audio.seek(const Duration(seconds: 12));
        expect(catalog.calls, 0);
        await audio.seek(const Duration(seconds: 16));
        await catalog.called.future.timeout(const Duration(seconds: 3));
        await audio.seek(const Duration(seconds: 18));
        expect(catalog.calls, 1);
        if (outcome == 'disable') {
          await library.setSetting('catalogAutoMatch', false);
        }
        Future<void>? shutdown;
        if (outcome == 'shutdown') {
          shutdown = app.shutdown();
          expect(
            catalog.closed,
            isTrue,
            reason: 'Cancel before the first shutdown await',
          );
        }
        catalog.response.complete(
          CatalogMatchResult(rankCatalogMatches(track, [recording]), []),
        );
        await shutdown;
        // Poll a bounded asynchronous operation, without any network or real audio.
        for (
          var i = 0;
          i < 50 && library.byId(track.id)!.catalogLink == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final saved = library.byId(track.id)!.catalogLink;
        if (outcome != 'accept') {
          expect(saved, isNull);
        } else {
          expect(saved!.recording.key, recording.key);
          expect(saved.manual, isFalse);
        }
      } finally {
        await app.shutdown();
        library.dispose();
        await root.delete(recursive: true);
      }
    });
  }
}
