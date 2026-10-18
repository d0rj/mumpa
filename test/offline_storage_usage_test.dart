import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  test(
    'usage counts actual completed app files once, excluding imported music',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mumpa-storage-usage-',
      );
      final library = LibraryRepository(root);
      final torrents = TorrentService(
        endpoint: () async => throw StateError('No network'),
      );
      final downloads = DownloadRepository(library, torrents);
      try {
        await library.load();
        await downloads.restore();
        Future<File> file(String path, int size) =>
            File('${root.path}/$path').writeAsBytes(List.filled(size, 0));
        final complete = await file('downloads/complete.wav', 4096);
        final imported = await file('imported.wav', 8192);
        final part = await file('downloads/partial.wav.part', 2048);
        final placedInDownloads = await file('downloads/imported.wav', 16384);
        Track track(String id, String path, {bool local = false}) => Track(
          id: id,
          title: id,
          artist: 'Artist',
          album: 'Album',
          source: local ? TrackSource.local : TrackSource.torrent,
          localPath: local ? path : null,
          cachedPath: local ? null : path,
          bytes: 999999,
        );
        await library.upsert([
          track('a', complete.path),
          track('alias', complete.path),
          track('external-cache', imported.path),
          track('local', imported.path, local: true),
          track('local-in-downloads', placedInDownloads.path, local: true),
          track('part', part.path),
          track('missing', '${root.path}/downloads/missing.wav'),
        ]);
        final usage = await downloads.storageUsage();
        expect(usage.bytes, 4096);
        expect(usage.files, 1);
        await library.setSetting('cacheLimitMb', 64);
        expect(downloads.limitBytes, 64 * 1024 * 1024);
        await complete.delete();
        expect((await downloads.storageUsage()).bytes, 0);
      } finally {
        await downloads.close();
        torrents.dispose();
        await library.flush();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
