import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/collection_filter.dart';
import 'package:mumpa/domain/models.dart';

Track _track(String id, {String? path, DateTime? downloadedAt}) => Track(
  id: id,
  title: 'Saved $id',
  artist: 'Band',
  album: 'Album',
  source: TrackSource.torrent,
  torrentPath: '$id.wav',
  bytes: 4,
  cachedPath: path,
  downloadedAt: downloadedAt,
);

void main() {
  late Directory root;
  late LibraryRepository library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-offline-order-');
    library = LibraryRepository(root);
    await library.load();
  });
  tearDown(() async {
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  });

  test('download dates round trip and disappear with the offline copy', () {
    final time = DateTime.parse('2026-10-13T15:30:00.123456+03:00');
    final track = _track('song', path: 'song.wav', downloadedAt: time);
    final restored = Track.fromJson(track.toJson());
    expect(restored.downloadedAt, time.toUtc());
    expect(restored.copyWith(title: 'New tags').downloadedAt, time);
    expect(restored.copyWith(clearCache: true).downloadedAt, isNull);
    expect(restored.copyWith(clearCache: true).cachedPath, isNull);
    final legacy = track.toJson()..remove('downloadedAt');
    expect(Track.fromJson(legacy).downloadedAt, isNull);
  });

  test(
    'offline order and search follow completion dates, not import order',
    () async {
      final older = DateTime.utc(2026, 10, 11);
      final newer = DateTime.utc(2026, 10, 13);
      await library.upsert([
        _track('old', path: 'old.wav', downloadedAt: older),
        _track('unknown', path: 'unknown.wav'),
        _track('new', path: 'new.wav', downloadedAt: newer),
        _track('same-time', path: 'tie.wav', downloadedAt: newer),
        _track('pending'),
      ]);
      final view = library.offlineTracks;
      expect(view.map((track) => track.id), [
        'new',
        'same-time',
        'old',
        'unknown',
      ]);
      expect(filterCollectionTracks(view, 'saved').map((track) => track.id), [
        'new',
        'same-time',
        'old',
        'unknown',
      ]);
      expect(library.tracks.first.id, 'old');
      expect(identical(view, library.offlineTracks), isTrue);
      expect(() => view.clear(), throwsUnsupportedError);
    },
  );

  test(
    'tag refreshes preserve dates, while a new download moves to the top',
    () async {
      final older = DateTime.utc(2026, 10, 11);
      final newer = DateTime.utc(2026, 10, 12);
      final path = (await File('${root.path}/old.wav').writeAsBytes([1])).path;
      final otherPath = (await File(
        '${root.path}/other.wav',
      ).writeAsBytes([1])).path;
      await library.upsert([
        _track('old', path: path, downloadedAt: older),
        _track('other', path: otherPath, downloadedAt: newer),
      ]);
      await library.upsert([_track('old').copyWith(title: 'Updated tags')]);
      expect(library.byId('old')!.cachedPath, path);
      expect(library.byId('old')!.downloadedAt, older);
      await library.upsert([_track('old', path: path)]);
      expect(library.byId('old')!.downloadedAt, older);
      expect(library.offlineTracks.map((track) => track.id), ['other', 'old']);

      await library.upsert([
        library.byId('old')!.copyWith(clearCache: true),
      ], preserveCache: false);
      expect(library.offlineTracks.single.id, 'other');
      final downloadedAgain = DateTime.utc(2026, 10, 13);
      await library.upsert([
        _track('old', path: path, downloadedAt: downloadedAgain),
      ]);
      final fresh = LibraryRepository(root);
      addTearDown(fresh.dispose);
      await fresh.load();
      expect(fresh.offlineTracks.map((track) => track.id), ['old', 'other']);
      expect(fresh.byId('old')!.downloadedAt, downloadedAgain);
    },
  );

  test(
    'legacy files migrate once and keep dates across later file changes',
    () async {
      final oldFile = await File('${root.path}/old.wav').writeAsBytes([1]);
      final newFile = await File('${root.path}/new.wav').writeAsBytes([1]);
      await oldFile.setLastModified(DateTime.utc(2026, 10, 10));
      await newFile.setLastModified(DateTime.utc(2026, 10, 12));
      final oldTime = (await oldFile.lastModified()).toUtc();
      final newTime = (await newFile.lastModified()).toUtc();
      await library.upsert([
        _track('old', path: oldFile.path),
        _track('new', path: newFile.path),
        _track(
          'missing',
          path: '${root.path}/missing.wav',
          downloadedAt: newTime,
        ),
      ]);
      final migrated = LibraryRepository(root);
      addTearDown(migrated.dispose);
      await migrated.load();
      expect(migrated.offlineTracks.map((track) => track.id), ['new', 'old']);
      expect(migrated.byId('old')!.downloadedAt, oldTime);
      expect(migrated.byId('missing')!.downloadedAt, isNull);
      final saved =
          jsonDecode(await File('${root.path}/library.json').readAsString())
              as Map<String, dynamic>;
      expect(
        (saved['tracks'] as List).first['downloadedAt'],
        oldTime.toIso8601String(),
      );

      await oldFile.setLastModified(DateTime.utc(2026, 10, 14));
      final fresh = LibraryRepository(root);
      addTearDown(fresh.dispose);
      await fresh.load();
      expect(fresh.offlineTracks.map((track) => track.id), ['new', 'old']);
      expect(fresh.byId('old')!.downloadedAt, oldTime);
      expect(fresh.byId('new')!.downloadedAt, newTime);
    },
  );

  test(
    'crash recovery uses final file time and excludes incomplete files',
    () async {
      await library.downloads.create(recursive: true);
      final file = await File(
        '${library.downloads.path}/recovered.wav',
      ).writeAsBytes([1, 2, 3, 4]);
      await file.setLastModified(DateTime.utc(2026, 10, 12));
      await File(
        '${library.downloads.path}/partial.wav.part',
      ).writeAsBytes([1, 2]);
      await library.upsert([_track('recovered'), _track('partial')]);
      final torrents = TorrentService(
        endpoint: () async => throw StateError('Recovery must stay offline'),
      );
      final downloads = DownloadRepository(library, torrents);
      addTearDown(() {
        downloads.dispose();
        torrents.dispose();
      });
      await downloads.restore();
      expect(library.offlineTracks.single.id, 'recovered');
      expect(
        library.byId('recovered')!.downloadedAt,
        (await file.lastModified()).toUtc(),
      );
      expect(library.byId('partial')!.downloadedAt, isNull);
    },
  );
}
