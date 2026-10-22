import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final name = Platform.environment['MUMPA_AUDIT_TEST'] ?? 'integration';
    if (!RegExp(r'^[a-z_]+$').hasMatch(name)) {
      throw FormatException('Invalid test name');
    }
    final directory = Directory('test-output/android-audit/$name');
    await directory.create(recursive: true);
    final report = Map<String, dynamic>.from(data ?? {});
    final artifacts = report.remove('artifacts');
    if (artifacts is Map) {
      for (final entry in artifacts.entries) {
        if (entry.key is! String ||
            !RegExp(r'^[a-z0-9_-]+\.png$').hasMatch(entry.key as String)) {
          throw FormatException('Invalid test artifact');
        }
        await File(
          '${directory.path}/${entry.key}',
        ).writeAsBytes(base64Decode(entry.value as String));
      }
    }
    await File(
      '${directory.path}/report.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  },
);
