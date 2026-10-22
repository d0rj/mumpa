import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/browser_catalog_transport.dart';
import 'package:mumpa/data/rutracker_service.dart';

class _Platform extends InAppWebViewPlatform {
  late final environment = _Environment(this);
  Completer<String?> version = Completer();
  Completer<PlatformWebViewEnvironment> creation = Completer();
  Completer<void> requested = Completer();
  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      environment;
}

class _Environment extends PlatformWebViewEnvironment {
  _Environment(this.owner)
    : super.implementation(const PlatformWebViewEnvironmentCreationParams());
  final _Platform owner;
  @override
  String get id => 'audit';
  @override
  Future<String?> getAvailableVersion({String? browserExecutableFolder}) =>
      owner.version.future;
  @override
  Future<PlatformWebViewEnvironment> create({
    WebViewEnvironmentSettings? settings,
  }) {
    owner.requested.complete();
    return owner.creation.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'close waits for late environment creation and disposes it once',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-browser-race-');
      final original = InAppWebViewPlatform.instance;
      final platform = _Platform();
      InAppWebViewPlatform.instance = platform;
      var disposals = 0;
      const channel = MethodChannel(
        'com.pichillilorenzo/flutter_webview_environment_audit',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            disposals++;
            return null;
          });
      final transport = BrowserCatalogTransport(root);
      try {
        platform.version.complete('1');
        final loading = expectLater(
          transport.load(Uri.https('rutracker.org', '/')),
          throwsA(isA<CatalogException>()),
        );
        await platform.requested.future;
        final closing = transport.dispose();
        platform.creation.complete(platform.environment);
        await closing;
        await loading;
        await transport.dispose();
        expect(disposals, 1);
        await expectLater(
          transport.connect(Uri.https('rutracker.org', '/')),
          throwsA(isA<CatalogException>()),
        );
        await expectLater(
          transport.logout(Uri.https('rutracker.org', '/')),
          throwsA(isA<CatalogException>()),
        );
      } finally {
        await transport.dispose();
        if (original != null) InAppWebViewPlatform.instance = original;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
