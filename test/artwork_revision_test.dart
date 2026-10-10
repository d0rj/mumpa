import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/ui/components.dart';

Future<Uint8List> _png(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(2, 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
}

Future<List<int>> _displayedPixel(WidgetTester tester) async {
  // File stat and native image decoding need real async time. Inspect the
  // decoded RawImage pixels, without evicting ImageCache between assertions.
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    final finder = find.byType(RawImage);
    if (finder.evaluate().isEmpty) continue;
    final image = tester.widget<RawImage>(finder).image;
    if (image == null) continue;
    final bytes = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    if (bytes != null) {
      return bytes.buffer
          .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes)
          .take(4)
          .toList();
    }
  }
  fail('The artwork did not finish decoding.');
}

void main() {
  testWidgets('cache clear reloads changed pixels at the same filename', (
    tester,
  ) async {
    late Directory root;
    late DiskMediaCache cache;
    late Uint8List red, blue;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('mumpa-art-generation-');
      cache = DiskMediaCache(root);
      red = await _png(const Color(0xFFFF0000));
      blue = await _png(const Color(0xFF0000FF));
      await cache.put('album-cover', red, extension: 'png');
    });
    var loads = 0;
    Widget artwork() => MaterialApp(
      home: Center(
        child: AsyncCoverArt(
          requestKey: '${cache.generation}:album-cover',
          seed: 'Album',
          load: () {
            loads++;
            return cache.pathFor('album-cover');
          },
        ),
      ),
    );
    try {
      final original = await tester.runAsync(
        () => cache.pathFor('album-cover'),
      );
      await tester.pumpWidget(artwork());
      expect(await _displayedPixel(tester), [255, 0, 0, 255]);
      await tester.pumpWidget(artwork());
      expect(loads, 1);
      await tester.runAsync(() async {
        await cache.clear();
        expect(
          await cache.put('album-cover', blue, extension: 'png'),
          original,
        );
      });
      await tester.pumpWidget(artwork());
      expect(await _displayedPixel(tester), [0, 0, 255, 255]);
      expect(loads, 2);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });

  testWidgets('TTL refresh at the same generation displays new file pixels', (
    tester,
  ) async {
    late Directory root;
    late DiskMediaCache cache;
    late Uint8List red, green;
    var now = DateTime.utc(2026, 10, 10);
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('mumpa-art-revision-');
      cache = DiskMediaCache(root, clock: () => now);
      red = await _png(const Color(0xFFFF0000));
      green = await _png(const Color(0xFF00FF00));
      final path = await cache.put(
        'album-cover',
        red,
        extension: 'png',
        ttl: const Duration(seconds: 1),
      );
      await File(path!).setLastModified(now);
    });
    Widget artwork() => MaterialApp(
      home: Center(
        child: AsyncCoverArt(
          requestKey: '${cache.generation}:album-cover',
          seed: 'Album',
          load: () => cache.pathFor('album-cover'),
        ),
      ),
    );
    try {
      final original = await tester.runAsync(
        () => cache.pathFor('album-cover'),
      );
      final generation = cache.generation;
      await tester.pumpWidget(artwork());
      expect(await _displayedPixel(tester), [255, 0, 0, 255]);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        now = now.add(const Duration(seconds: 2));
        expect(await cache.pathFor('album-cover'), isNull);
        final refreshed = await cache.put(
          'album-cover',
          green,
          extension: 'png',
        );
        expect(refreshed, original);
        await File(refreshed!).setLastModified(now);
      });
      expect(cache.generation, generation);
      // Reopening a visible row resolves a fresh artifact. The previous
      // decoded image intentionally remains in Flutter's memory cache.
      await tester.pumpWidget(artwork());
      expect(await _displayedPixel(tester), [0, 255, 0, 255]);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
}
