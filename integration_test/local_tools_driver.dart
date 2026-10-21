import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    await Directory('test-output').create(recursive: true);
    await File(
      'test-output/local-features-native-${data?['platform'] ?? 'unknown'}.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  },
);
