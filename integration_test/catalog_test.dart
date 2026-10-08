import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mumpa/data/browser_catalog_transport.dart';
import 'package:mumpa/data/rutracker_service.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native browser loads real RuTracker catalog or exposes site verification',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Проверка каталога RuTracker')),
          ),
        ),
      );
      final root = await Directory(
        '${(await getTemporaryDirectory()).path}/mumpa-catalog-probe-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final service = RuTrackerService(
        transport: BrowserCatalogTransport(root),
      );
      final evidence = <String, Object>{'platform': Platform.operatingSystem};
      try {
        final sections = await service.refresh();
        expect(sections.length, 6);
        evidence['liveGenres'] = sections.map((s) => s.title).toList();
        evidence['forums'] = sections.fold<int>(
          0,
          (n, s) => n + s.children.length,
        );
        try {
          final music = await service.browse('index.php?c=8');
          expect(music.sections, isNotEmpty);
          evidence['liveMusicSections'] = music.sections.length;
          final listing = await service.browse(music.sections.first.path);
          evidence['liveSubforums'] = listing.sections.length;
          evidence['liveReleases'] = listing.releases.length;
        } on CatalogException catch (e) {
          expect(e.connect, isTrue, reason: e.message);
          evidence['siteVerificationRequired'] = true;
        }
      } catch (e) {
        evidence['error'] = e.toString();
        rethrow;
      } finally {
        binding.reportData = evidence;
        debugPrint('MUMPA_CATALOG_PROBE $evidence');
        await service.dispose();
      }
    },
  );
}
