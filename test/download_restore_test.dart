import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:path/path.dart' as p;

class _ListedPartial implements File {
  _ListedPartial(this.path, this.bytes, {this.readable = true});
  @override
  final String path;
  final int bytes;
  final bool readable;
  int lengthCalls = 0;

  @override
  Future<int> length() async {
    lengthCalls++;
    if (!readable) throw StateError('Unrelated file must not be inspected.');
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected per-file I/O: ${invocation.memberName}');
}

class _DownloadDirectory implements Directory {
  _DownloadDirectory(this.path);
  @override
  final String path;
  final List<FileSystemEntity> entries = [];
  int createCalls = 0, listCalls = 0;

  @override
  Future<Directory> create({bool recursive = false}) async {
    expect(recursive, isTrue);
    createCalls++;
    return this;
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) {
    expect(recursive, isFalse);
    expect(followLinks, isFalse);
    listCalls++;
    return Stream.fromIterable(entries);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected directory I/O: ${invocation.memberName}');
}

class _RestoreLibrary extends LibraryRepository {
  _RestoreLibrary(this.directory, this.items) : super(Directory('unused'));
  final Directory directory;
  final List<Track> items;
  @override
  Directory get downloads => directory;
  @override
  List<Track> get tracks => items;
}

Track _track(
  String id, {
  TrackSource source = TrackSource.torrent,
  String? cachedPath,
}) => Track(
  id: id,
  title: id,
  artist: 'Fixture artist',
  album: 'Fixture album',
  source: source,
  torrentPath: '$id.MP3',
  bytes: 4096,
  cachedPath: cachedPath,
);

void main() {
  test(
    'large library restores only listed partials with one directory scan',
    () async {
      final directory = _DownloadDirectory(p.absolute('restore-downloads'));
      final tracks = List.generate(10000, (index) => _track('track-$index'));
      tracks.addAll([
        _track('cached', cachedPath: 'complete.mp3'),
        _track('local', source: TrackSource.local),
        _track('demo', source: TrackSource.demo),
      ]);
      final early = _ListedPartial(
        p.join(directory.path, 'track-5.mp3.part'),
        512,
      );
      final late = _ListedPartial(
        p.join(directory.path, 'track-9999.mp3.part'),
        0,
      );
      final unrelated = [
        _ListedPartial(
          p.join(directory.path, 'orphan.mp3.part'),
          200,
          readable: false,
        ),
        _ListedPartial(
          p.join(directory.path, 'cached.mp3.part'),
          200,
          readable: false,
        ),
        _ListedPartial(
          p.join(directory.path, 'local.mp3.part'),
          200,
          readable: false,
        ),
        _ListedPartial(
          p.join(directory.path, 'demo.mp3.part'),
          200,
          readable: false,
        ),
        _ListedPartial(
          p.join(directory.path, 'track-4.flac.part'),
          200,
          readable: false,
        ),
        _ListedPartial(
          p.join(directory.path, 'track-3.flac'),
          4096,
          readable: false,
        ),
      ];
      directory.entries.addAll([
        late,
        ...unrelated,
        Directory(p.join(directory.path, 'track-2.mp3.part')),
        Link(p.join(directory.path, 'track-1.mp3.part')),
        early,
      ]);
      final library = _RestoreLibrary(directory, tracks);
      var endpointCalls = 0;
      final torrents = TorrentService(
        endpoint: () async {
          endpointCalls++;
          throw StateError('Restore must not start the torrent engine.');
        },
      );
      final downloads = DownloadRepository(library, torrents);
      addTearDown(() {
        downloads.dispose();
        torrents.dispose();
        library.dispose();
      });

      await downloads.restore();

      expect(directory.createCalls, 1);
      expect(directory.listCalls, 1);
      expect(downloads.jobs.map((job) => job.track.id), [
        'track-5',
        'track-9999',
      ]);
      expect(downloads.jobs.map((job) => job.received), [512, 0]);
      expect(downloads.jobs.every((job) => job.total == 4096), isTrue);
      expect(
        downloads.jobs.every((job) => job.state == DownloadState.paused),
        isTrue,
      );
      expect(
        downloads.jobs.every((job) => !downloads.active(job.track.id)),
        isTrue,
      );
      expect(early.lengthCalls, 1);
      expect(late.lengthCalls, 1);
      expect(unrelated.every((file) => file.lengthCalls == 0), isTrue);
      expect(endpointCalls, 0);
    },
  );

  test(
    'Windows partial matching retains case-insensitive filesystem behavior',
    () async {
      final directory = _DownloadDirectory(p.absolute('restore-case'));
      final partial = _ListedPartial(
        p.join(directory.path, 'SONG.MP3.PART'),
        1024,
      );
      directory.entries.add(partial);
      final library = _RestoreLibrary(directory, [_track('song')]);
      final torrents = TorrentService(
        endpoint: () async => throw StateError('No network'),
      );
      final downloads = DownloadRepository(library, torrents);
      addTearDown(() {
        downloads.dispose();
        torrents.dispose();
        library.dispose();
      });

      await downloads.restore();

      if (Platform.isWindows) {
        expect(downloads.jobs.single.track.id, 'song');
        expect(downloads.jobs.single.received, 1024);
      } else {
        expect(downloads.jobs, isEmpty);
      }
    },
  );
}
