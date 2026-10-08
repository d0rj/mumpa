import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mumpa/data/jackett_service.dart';
import 'package:path_provider/path_provider.dart';

class DashboardProbe extends InAppBrowser {
  final loaded = Completer<String>();
  final closed = Completer<void>();

  @override
  Future<void> onLoadStop(WebUri? url) async {
    if (url?.path != '/UI/Dashboard' || loaded.isCompleted) return;
    final html = await webViewController!.evaluateJavascript(
      source: 'document.documentElement.outerHTML',
    );
    loaded.complete(html as String);
  }

  @override
  void onExit() {
    if (!closed.isCompleted) closed.complete();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'private Jackett dashboard opens and closes in the native browser',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Проверка Jackett'))),
      );
      final support = await getApplicationSupportDirectory();
      final root = await Directory(
        '${(await getTemporaryDirectory()).path}/mumpa-jackett-ui-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final service = JackettService(
        root,
        binaryDirectory: Directory('${support.path}/Mumpa/runtime'),
      );
      final browser = DashboardProbe();
      try {
        final connection = await service.start();
        await browser.openUrlRequest(
          urlRequest: URLRequest(url: WebUri(connection.dashboardUrl)),
          settings: InAppBrowserClassSettings(
            webViewSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              saveFormData: false,
            ),
          ),
        );
        final html = await browser.loaded.future.timeout(
          const Duration(seconds: 30),
        );
        expect(html, contains('Jackett'));
        expect(html, contains('Add indexer'));
        expect(await service.isRuTrackerConfigured(connection), isFalse);
        await browser.close();
        await browser.closed.future.timeout(const Duration(seconds: 10));
        binding.reportData = {'nativeJackettDashboard': true};
        debugPrint('MUMPA_JACKETT_UI native dashboard opened and closed');
      } finally {
        if (!browser.closed.isCompleted) await browser.close();
        await service.stop();
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
