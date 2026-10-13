// Opt-in network check of the real release downloader and Windows credentials.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mumpa/data/app_update_service.dart';
import 'package:mumpa/ui/app_update_panel.dart';
import 'package:mumpa/ui/theme.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('APP_UPDATE_TEST');
  const fullDownload = bool.fromEnvironment('APP_UPDATE_DOWNLOAD_TEST');
  testWidgets(
    'real private GitHub release downloads with size and SHA-256 verification',
    (tester) async {
      final root = Directory('test-output/native-updates');
      final updates = AppUpdateService(
        root,
        installedVersion: () async => '1.0.0+1',
        target: () async => 'windows-x64.zip',
      );
      addTearDown(updates.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: mumpaTheme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: AppUpdatePanel(
                updates: updates,
                quit: () async {},
                autoCheck: true,
                onAutoCheck: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final info = await PackageInfo.fromPlatform();
      expect(info.version, '1.2.14');
      expect(info.buildNumber, '22');
      await updates.check();
      expect(updates.error, isNull, reason: updates.error);
      expect(updates.available, isNotNull);
      if (fullDownload) {
        await updates.download();
        expect(updates.error, isNull, reason: updates.error);
        expect(updates.downloaded, isNotNull);
        expect(await updates.downloaded!.length(), updates.available!.bytes);
      }
      await tester.pump();
      expect(
        find.byKey(
          ValueKey(fullDownload ? 'install-app-update' : 'download-app-update'),
        ),
        findsOneWidget,
      );
      await root.create(recursive: true);
      await File('test-output/native-app-update-1.2.14.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'installedVersion': '${info.version}+${info.buildNumber}',
          'releaseVersion': updates.available!.version,
          'downloadedFile': updates.downloaded?.absolute.path,
          'bytes': updates.available!.bytes,
          'sha256': updates.available!.sha256,
          'privateCredentialFallback':
              updates.available!.privateAssetPath != null,
          'packageVerified': fullDownload,
        }),
      );
    },
    skip: !enabled || !Platform.isWindows,
  );
}
