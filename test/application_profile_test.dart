import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/application_profile.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/domain/models.dart';

/// Models a launch host spelling a directory through a short/virtualized alias,
/// while the filesystem resolves it to its canonical location.
class _ResolvedDirectory implements Directory {
  _ResolvedDirectory(this.path, this.actual);
  @override
  final String path;
  final Directory actual;
  @override
  Future<bool> exists() => actual.exists();
  @override
  Future<String> resolveSymbolicLinks() => actual.resolveSymbolicLinks();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temporary, home;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'mumpa-profile-unification-',
    );
    home = await Directory('${temporary.path}/user').create();
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  Future<Directory> legacy(
    String name,
    List<Track> tracks,
    List<String> liked, {
    String provider = 'automatic',
  }) async {
    final directory = await Directory(
      '${temporary.path}/$name',
    ).create(recursive: true);
    await File('${directory.path}/library.json').writeAsString(
      jsonEncode({
        'version': 1,
        'tracks': tracks.map((track) => track.toJson()).toList(),
        'playlists': [],
        'liked': liked,
        'settings': {'searchProvider': provider, 'volume': 0.37},
      }),
    );
    return directory;
  }

  test('different launch hosts share one profile and can reopen it', () async {
    final one = await ApplicationProfile.open(home: home.path, legacyRoots: []);
    expect(one.root.path, '${home.path}${Platform.pathSeparator}.mumpa');
    await one.close();
    final two = await ApplicationProfile.open(home: home.path, legacyRoots: []);
    expect(two.root.path, one.root.path);
    await two.close();
  });

  test(
    'Windows profile rejects concurrent writers within the same process',
    () async {
      final profile = await ApplicationProfile.open(
        home: home.path,
        legacyRoots: [],
      );
      try {
        await expectLater(
          ApplicationProfile.open(home: home.path, legacyRoots: []),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await profile.close();
      }
    },
    // Dart's Unix advisory locks are process-wide and permit this second handle.
    // ApplicationProfile is the Windows launch-host storage boundary.
    skip: !Platform.isWindows,
  );

  test(
    'one-time import unifies favorites, copies offline files and preserves originals',
    () async {
      final saved = await legacy('codex', [], []);
      final audio = await File('${saved.path}/downloads/track.mp3').parent
          .create(recursive: true)
          .then(
            (_) => File(
              '${saved.path}/downloads/track.mp3',
            ).writeAsBytes([1, 2, 3, 4]),
          );
      final track = Track(
        id: 'saved',
        title: 'Saved',
        artist: 'Artist',
        album: 'Album',
        source: TrackSource.torrent,
        cachedPath: audio.path,
      );
      await File('${saved.path}/library.json').writeAsString(
        jsonEncode({
          'tracks': [track.toJson()],
          'playlists': [],
          'liked': ['saved'],
          'settings': {'volume': 0.37, 'searchProvider': 'automatic'},
        }),
      );
      final other = await legacy(
        'terminal',
        [
          const Track(
            id: 'new',
            title: 'New',
            artist: 'Artist',
            album: 'Other',
            source: TrackSource.local,
          ),
        ],
        ['new'],
        provider: 'torznab',
      );
      final before = await File('${saved.path}/library.json').readAsBytes();
      final profile = await ApplicationProfile.open(
        home: home.path,
        legacyRoots: [other, saved],
      );
      try {
        final library = LibraryRepository(profile.root);
        await library.load();
        expect(library.liked, {'saved', 'new'});
        expect(library.settings['volume'], 0.37);
        final migrated = library.byId('saved')!;
        expect(migrated.cachedPath, startsWith(profile.root.path));
        expect(await File(migrated.cachedPath!).readAsBytes(), [1, 2, 3, 4]);
        expect(await audio.readAsBytes(), [1, 2, 3, 4]);
        expect(await File('${saved.path}/library.json').readAsBytes(), before);
        await library.toggleLike('saved');
        library.dispose();
      } finally {
        await profile.close();
      }
      final next = await ApplicationProfile.open(
        home: home.path,
        legacyRoots: [saved],
      );
      try {
        final library = LibraryRepository(next.root);
        await library.load();
        expect(library.liked, {
          'new',
        }, reason: 'Old likes must not be resurrected on each start');
        library.dispose();
      } finally {
        await next.close();
      }
    },
  );

  test(
    'virtualized serialized paths are rebased to the shared offline copy',
    () async {
      final actual = await Directory(
        '${home.path}/AppData/Local/Packages/Host/LocalCache/Roaming/app.mumpa/mumpa/Mumpa',
      ).create(recursive: true);
      final logical = '${home.path}/AppData/Roaming/app.mumpa/mumpa/Mumpa';
      final source = File('${actual.path}/downloads/song.mp3');
      await source.parent.create(recursive: true);
      await source.writeAsBytes([3, 2, 1]);
      final track = Track(
        id: 'song',
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        source: TrackSource.torrent,
        cachedPath: '$logical/downloads/song.mp3',
      );
      await File('${actual.path}/library.json').writeAsString(
        jsonEncode({
          'tracks': [track.toJson()],
          'liked': ['song'],
          'settings': {},
        }),
      );
      final profile = await ApplicationProfile.open(
        home: home.path,
        legacyRoots: [actual],
      );
      try {
        final library = LibraryRepository(profile.root);
        await library.load();
        expect(library.favoriteTracks.single.offline, isTrue);
        expect(
          await File(library.favoriteTracks.single.cachedPath!).readAsBytes(),
          [3, 2, 1],
        );
        library.dispose();
      } finally {
        await profile.close();
      }
    },
  );

  test(
    'unreadable legacy data cannot silently become a fresh empty library',
    () async {
      final source = await Directory('${temporary.path}/corrupt').create();
      await File('${source.path}/library.json').writeAsString('{broken');
      await expectLater(
        ApplicationProfile.open(home: home.path, legacyRoots: [source]),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File('${home.path}/.mumpa/library.json').exists(), isFalse);
      expect(
        await File('${source.path}/library.json').readAsString(),
        '{broken',
      );
    },
  );

  test(
    'virtualized logical aliases survive canonical and short path differences',
    () async {
      final actual = await Directory(
        '${temporary.path}/canonical-user/AppData/Local/Packages/Host/LocalCache/Roaming/app.mumpa/mumpa/Mumpa',
      ).create(recursive: true);
      final source = File('${actual.path}/downloads/song.mp3');
      await source.parent.create(recursive: true);
      await source.writeAsBytes([5, 4, 3]);
      final logicalUser = '${temporary.path}/SHORT~1';
      final logicalSource =
          '$logicalUser/appdata/LOCAL/packages/Host/LocalCache/Roaming/app.mumpa/mumpa/Mumpa';
      final serialized =
          '$logicalUser/AppData/Roaming/app.mumpa/mumpa/Mumpa/downloads/song.mp3';
      final track = Track(
        id: 'aliased',
        title: 'Aliased',
        artist: 'Artist',
        album: 'Album',
        source: TrackSource.torrent,
        cachedPath: serialized,
      );
      await File('${actual.path}/library.json').writeAsString(
        jsonEncode({
          'tracks': [track.toJson()],
          'liked': ['aliased'],
          'settings': {},
        }),
      );
      final profile = await ApplicationProfile.open(
        home: home.path,
        legacyRoots: [_ResolvedDirectory(logicalSource, actual)],
      );
      final library = LibraryRepository(profile.root);
      try {
        await library.load();
        final migrated = library.favoriteTracks.single;
        expect(migrated.offline, isTrue);
        expect(migrated.cachedPath, startsWith(profile.root.path));
        expect(await File(migrated.cachedPath!).readAsBytes(), [5, 4, 3]);
        expect(await source.readAsBytes(), [5, 4, 3]);
      } finally {
        library.dispose();
        await profile.close();
      }
    },
  );
}
