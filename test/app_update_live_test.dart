// Explicit opt-in: uses the host's GitHub CLI to read the actual private release.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/app_update_service.dart';

void main() {
  const enabled = bool.fromEnvironment('APP_UPDATE_LIVE_TEST');
  test(
    'real GitHub credentials read release BUILD and SHA256 assets',
    () async {
      final root = Directory('test-output/live-release-check');
      final updates = AppUpdateService(
        root,
        installedVersion: () async => '1.0.0+1',
        target: () async => 'windows-x64.zip',
        clientFactory: () =>
            MockClient((_) async => http.Response('private', 404)),
        allowPrivateFallback: true,
      );
      addTearDown(updates.dispose);
      await updates.check();
      expect(updates.error, isNull, reason: updates.error);
      expect(updates.available, isNotNull);
      expect(updates.available!.privateAssetPath, isNotNull);
      await root.create(recursive: true);
      await File('${root.path}/result.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'version': updates.available!.version,
          'bytes': updates.available!.bytes,
          'sha256': updates.available!.sha256,
          'file': updates.available!.fileName,
          'privateReleaseMetadataVerified': true,
          'packageDownloaded': false,
        }),
      );
    },
    skip: !enabled || !Platform.isWindows,
  );
}
