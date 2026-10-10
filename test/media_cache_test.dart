import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/media_cache.dart';

void main() {
  late Directory root;
  late DateTime now;
  late DiskMediaCache cache;
  Uint8List payload(int value, [int length = 4]) =>
      Uint8List.fromList(List.filled(length, value));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-media-cache-');
    now = DateTime.utc(2026, 10, 10);
    cache = DiskMediaCache(root, maxBytes: 12, clock: () => now);
    await cache.initialize();
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'metadata and images share persistent FIFO quota; reads do not promote',
    () async {
      final albumPath = await cache.put('album', payload(1), extension: 'json');
      await cache.put('cover', payload(2), extension: 'jpg');
      expect(await cache.read('album'), payload(1));
      expect(await cache.pathFor('album'), albumPath);
      await cache.put('artist', payload(3, 6), extension: 'json');
      expect(await cache.read('album'), isNull);
      expect(await cache.read('cover'), payload(2));

      final restarted = DiskMediaCache(root, maxBytes: 12, clock: () => now);
      await restarted.initialize();
      final statistics = await restarted.stats();
      expect(statistics.bytes, 10);
      expect(statistics.count, 2);
      expect(statistics.maxBytes, 12);
      await restarted.put('next-cover', payload(4), extension: 'jpg');
      expect(await restarted.read('cover'), isNull);
      expect(await restarted.read('artist'), payload(3, 6));
      expect(await restarted.read('next-cover'), payload(4));
    },
  );

  test(
    'replacing an item gives it a new insertion date and removes the old file',
    () async {
      await cache.setMaxBytes(8);
      final previous = await cache.put('album', payload(1));
      now = now.add(const Duration(seconds: 1));
      await cache.put('cover', payload(2));
      now = now.add(const Duration(seconds: 1));
      final replacement = await cache.put(
        'album',
        payload(3),
        extension: 'json',
      );
      expect(replacement, isNot(previous));
      expect(await File(previous!).exists(), isFalse);
      now = now.add(const Duration(seconds: 1));
      await cache.put('artist', payload(4));
      expect(await cache.read('cover'), isNull);
      expect(await cache.read('album'), payload(3));
      expect((await cache.stats()).bytes, 8);
    },
  );

  test(
    'lowering the quota evicts oldest entries and zero disables writes',
    () async {
      await cache.put('first', payload(1));
      await cache.put('second', payload(2));
      await cache.put('third', payload(3));
      await cache.setMaxBytes(5);
      expect(await cache.read('first'), isNull);
      expect(await cache.read('second'), isNull);
      expect(await cache.read('third'), payload(3));
      await cache.setMaxBytes(0);
      expect(await cache.put('fourth', payload(4)), isNull);
      expect((await cache.stats()).count, 0);
      expect((await cache.stats()).bytes, 0);
    },
  );

  test(
    'oversized and immediately expired replacements remove old data',
    () async {
      await cache.put('album', payload(1));
      expect(await cache.put('album', payload(2, 13)), isNull);
      expect(await cache.pathFor('album'), isNull);
      await cache.put('album', payload(3));
      expect(await cache.put('album', payload(4), ttl: Duration.zero), isNull);
      expect((await cache.stats()).bytes, 0);
    },
  );

  test('TTL expires at its boundary and reads do not extend it', () async {
    final cachedPath = await cache.put(
      'album',
      payload(1),
      ttl: const Duration(seconds: 5),
    );
    now = now.add(const Duration(seconds: 4));
    expect(await cache.read('album'), payload(1));
    now = now.add(const Duration(seconds: 1));
    expect(await cache.read('album'), isNull);
    expect(await File(cachedPath!).exists(), isFalse);
    expect((await cache.stats()).count, 0);
    final restarted = DiskMediaCache(root, maxBytes: 12, clock: () => now);
    expect(await restarted.read('album'), isNull);
  });

  test(
    'restart prunes expired entries even if they have not been read',
    () async {
      final cachedPath = await cache.put(
        'album',
        payload(1),
        ttl: const Duration(seconds: 5),
      );
      now = now.add(const Duration(seconds: 5));
      final restarted = DiskMediaCache(root, maxBytes: 12, clock: () => now);
      await restarted.initialize();
      expect(await restarted.pathFor('album'), isNull);
      expect(await File(cachedPath!).exists(), isFalse);
      expect((await restarted.stats()).bytes, 0);
    },
  );

  test(
    'clear invalidates pending and late pre-clear fetches without blocking new ones',
    () async {
      await cache.put('existing', payload(1));
      final captured = cache.generation;
      final pending = cache.put(
        'pending',
        payload(2),
        expectedGeneration: captured,
      );
      final clearing = cache.clear();
      expect(cache.generation, captured + 1);
      expect(await pending, isNull);
      await clearing;
      expect(
        await cache.put('late', payload(3), expectedGeneration: captured),
        isNull,
      );
      expect((await cache.stats()).count, 0);
      expect(
        await cache.put(
          'new',
          payload(4),
          expectedGeneration: cache.generation,
        ),
        isNotNull,
      );
      expect(await cache.read('new'), payload(4));
    },
  );

  test(
    'parallel writes serialize and snapshot mutable input buffers',
    () async {
      final input = payload(1);
      final firstWrite = cache.put('first', input);
      input.fillRange(0, input.length, 9);
      await Future.wait([
        firstWrite,
        cache.put('second', payload(2)),
        cache.put('third', payload(3)),
        cache.put('fourth', payload(4)),
      ]);
      expect(await cache.read('first'), isNull);
      expect(await cache.read('second'), payload(2));
      expect(await cache.read('third'), payload(3));
      expect(await cache.read('fourth'), payload(4));
      // Snapshotting is observable before another FIFO eviction can remove it.
      final stableInput = payload(5);
      final snapshotWrite = cache.put('snapshot', stableInput);
      stableInput[0] = 8;
      await snapshotWrite;
      expect(await cache.read('snapshot'), payload(5));
      expect((await cache.stats()).bytes, 12);
    },
  );

  test(
    'corrupt index and partial file recover without touching unrelated files',
    () async {
      final cachedPath = await cache.put('album', payload(1));
      final unrelated = File('${root.path}/files/keep-me.txt');
      await unrelated.writeAsString('keep');
      await File('${root.path}/index.json').writeAsString('{broken');
      final restarted = DiskMediaCache(root, maxBytes: 12, clock: () => now);
      await restarted.initialize();
      expect((await restarted.stats()).count, 0);
      expect(await File(cachedPath!).exists(), isFalse);
      expect(await unrelated.readAsString(), 'keep');
      await restarted.put('album', payload(2));
      final partialPath = await restarted.pathFor('album');
      await File(partialPath!).writeAsBytes([1]);
      final recovered = DiskMediaCache(root, maxBytes: 12, clock: () => now);
      expect(await recovered.read('album'), isNull);
      expect((await recovered.stats()).bytes, 0);
      await recovered.clear();
      expect(await unrelated.readAsString(), 'keep');
    },
  );

  test(
    'invalid indexed paths cannot read or delete files outside the cache',
    () async {
      final outside = File(
        '${root.parent.path}/${root.uri.pathSegments.where((s) => s.isNotEmpty).last}-outside.txt',
      );
      await outside.writeAsString('preserve');
      addTearDown(() async {
        if (await outside.exists()) await outside.delete();
      });
      final hash = sha256.convert(utf8.encode('unsafe')).toString();
      await File('${root.path}/index.json').writeAsString(
        jsonEncode({
          'version': 1,
          'entries': [
            {
              'hash': hash,
              'filename': '../../${outside.uri.pathSegments.last}',
              'bytes': 8,
              'createdAt': now.toIso8601String(),
              'sequence': 0,
            },
          ],
        }),
      );
      final restarted = DiskMediaCache(root, clock: () => now);
      expect(await restarted.read('unsafe'), isNull);
      await restarted.clear();
      expect(await outside.readAsString(), 'preserve');
      expect(
        () => restarted.put('bad', payload(1), extension: '../outside'),
        throwsArgumentError,
      );
      expect(() => restarted.setMaxBytes(-1), throwsArgumentError);
      final index = await File('${root.path}/index.json').readAsString();
      expect(index, isNot(contains('unsafe')));
      expect(index, isNot(contains(outside.path)));
    },
  );
}
