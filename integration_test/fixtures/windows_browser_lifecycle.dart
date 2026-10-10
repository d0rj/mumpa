import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Intentionally retained until native plugin destruction. This fixture must
// not call their Dart dispose methods: it tests exiting with live view owners.
WebViewEnvironment? _environment;
HeadlessInAppWebView? _headless;
_FixtureBrowser? _browser;

class _FixtureBrowser extends InAppBrowser {
  _FixtureBrowser({super.webViewEnvironment});
  final created = Completer<void>();
  @override
  void onBrowserCreated() {
    if (!created.isCompleted) created.complete();
  }
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final evidenceArguments = arguments.where(
    (argument) => argument.startsWith('--evidence='),
  );
  if (!Platform.isWindows || evidenceArguments.length != 1) {
    throw const FormatException('Windows fixture requires --evidence=<path>.');
  }
  final evidence = File(evidenceArguments.single.substring('--evidence='.length));
  final temporary = await Directory.systemTemp.createTemp(
    'mumpa-browser-lifecycle-',
  );
  var environmentReady = false, headlessReady = false, browserReady = false;

  Future<void> writeEvidence(bool ready) async {
    await evidence.parent.create(recursive: true);
    final pending = File('${evidence.path}.tmp');
    await pending.writeAsString(
      jsonEncode({
        'isBrowserLifecycleFixture': true,
        'ready': ready,
        'environmentReady': environmentReady,
        'headlessReady': headlessReady,
        'browserReady': browserReady,
        'temporaryDirectory': temporary.path,
      }),
      flush: true,
    );
    await pending.rename(evidence.path);
  }

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(child: Text('Isolated Windows browser lifecycle fixture')),
      ),
    ),
  );
  try {
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized.timeout(
      const Duration(seconds: 20),
    );
    _environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: temporary.path),
    ).timeout(const Duration(seconds: 20));
    environmentReady = true;
    final headlessCreated = Completer<void>();
    _headless = HeadlessInAppWebView(
      webViewEnvironment: _environment,
      initialUrlRequest: URLRequest(url: WebUri('about:blank')),
      initialSettings: InAppWebViewSettings(saveFormData: false),
      onWebViewCreated: (_) {
        if (!headlessCreated.isCompleted) headlessCreated.complete();
      },
    );
    await _headless!.run().timeout(const Duration(seconds: 20));
    await headlessCreated.future.timeout(const Duration(seconds: 20));
    headlessReady = true;
    _browser = _FixtureBrowser(webViewEnvironment: _environment);
    await _browser!
        .openUrlRequest(
          urlRequest: URLRequest(url: WebUri('about:blank')),
          settings: InAppBrowserClassSettings(
            browserSettings: InAppBrowserSettings(
              toolbarTopFixedTitle: 'Isolated lifecycle fixture',
              hideUrlBar: true,
            ),
            webViewSettings: InAppWebViewSettings(saveFormData: false),
          ),
        )
        .timeout(const Duration(seconds: 20));
    await _browser!.created.future.timeout(const Duration(seconds: 20));
    browserReady = true;
    await writeEvidence(true);
  } catch (_) {
    // Only public readiness flags are reported, never native error text.
    await writeEvidence(false);
  }
}
