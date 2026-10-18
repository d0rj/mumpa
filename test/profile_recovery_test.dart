import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  const track = Track(
    id: 'saved',
    title: 'Saved',
    artist: 'Artist',
    album: 'Album',
    source: TrackSource.torrent,
  );
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-recovery-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<void> seed() async {
    final library = LibraryRepository(root);
    await library.load();
    await library.upsert([track]);
    await library.toggleLike(track.id);
    await library.setSetting('volume', 0.37);
    await library.flush();
    library.dispose();
  }

  test(
    'recovery preserves favorites and backup after another save and crash',
    () async {
      await seed();
      final primary = File('${root.path}/library.json');
      final backup = File('${primary.path}.bak');
      final good = await primary.readAsString();
      await backup.writeAsString(good);
      await primary.writeAsString('{broken');
      final library = LibraryRepository(root);
      await library.load();
      expect(library.favoriteTracks.single.id, track.id);
      expect(library.settings['volume'], 0.37);
      await library.setSetting('volume', 0.42);
      expect(await backup.readAsString(), good);
      expect(
        (await root.list().where((e) => e.path.contains('unreadable')).toList())
            .length,
        1,
      );
      library.dispose();
      await primary.writeAsString('{broken again');
      final restarted = LibraryRepository(root);
      await restarted.load();
      expect(restarted.favoriteTracks.single.id, track.id);
      expect(restarted.settings['volume'], 0.37);
      restarted.dispose();
    },
  );

  test(
    'invalid settings cannot publish a partial library or overwrite evidence',
    () async {
      await seed();
      final primary = File('${root.path}/library.json');
      final broken =
          jsonDecode(await primary.readAsString()) as Map<String, dynamic>;
      broken['settings'] = ['wrong type'];
      await primary.writeAsString(jsonEncode(broken));
      await File('${primary.path}.bak').writeAsString('{broken');
      await Directory('${root.path}/backups').delete(recursive: true);
      final library = LibraryRepository(root);
      await library.load();
      expect(library.tracks, isEmpty);
      expect(library.loadWarning, contains('заблокирована'));
      final before = await primary.readAsString();
      await expectLater(
        library.setSetting('volume', 0.5),
        throwsA(isA<FileSystemException>()),
      );
      expect(await primary.readAsString(), before);
      library.dispose();
    },
  );

  test(
    'missing primary and backup recover from independent daily generation',
    () async {
      await seed();
      // Daily backup is taken before the first overwrite of a day.
      final primary = File('${root.path}/library.json');
      final day = DateTime.now().toIso8601String().substring(0, 10);
      await primary.copy('${root.path}/backups/library-$day.json');
      await primary.delete();
      await File('${primary.path}.bak').delete();
      final recovered = LibraryRepository(root);
      await recovered.load();
      expect(recovered.favoriteTracks.single.id, track.id);
      expect(recovered.settings['volume'], 0.37);
      recovered.dispose();
    },
  );

  test(
    'real Windows profile loads without losing favorites or settings',
    () async {
      final path = Platform.environment['MUMPA_PROFILE_AUDIT'];
      if (path == null) return;
      final original = await File(path).readAsBytes();
      final json = jsonDecode(utf8.decode(original)) as Map;
      await File('${root.path}/library.json').writeAsBytes(original);
      final library = LibraryRepository(root);
      await library.load();
      expect(library.loadWarning, isNull);
      expect(library.tracks.length, (json['tracks'] as List).length);
      expect(library.liked, (json['liked'] as List).toSet());
      expect(library.favoriteTracks.length, (json['liked'] as List).length);
      expect(
        library.settings,
        containsPair('volume', (json['settings'] as Map)['volume']),
      );
      await library.setSetting('auditSetting', true);
      final restarted = LibraryRepository(root);
      await restarted.load();
      expect(restarted.liked, library.liked);
      expect(restarted.settings['auditSetting'], isTrue);
      expect(await File(path).readAsBytes(), original);
      library.dispose();
      restarted.dispose();
    },
    skip: Platform.environment['MUMPA_PROFILE_AUDIT'] == null,
  );
}
