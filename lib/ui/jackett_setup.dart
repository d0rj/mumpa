import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../data/jackett_service.dart';
import '../logic/app_controller.dart';

Future<void> setupJackett(
  BuildContext context,
  AppController app, {
  bool embedded = false,
}) async {
  JackettConnection? connection;
  final external =
      !embedded &&
      app.indexerConnected &&
      app.library.settings['managedJackett'] != true;
  if (external) {
    final uri = Uri.parse(app.library.settings['indexerUrl'] as String);
    final api = uri.path.indexOf('/api/v2.0/');
    final base = uri.replace(
      path: api < 0 ? '' : uri.path.substring(0, api),
      query: '',
      fragment: '',
    );
    connection = JackettConnection(
      baseUrl: base.toString().replaceFirst(RegExp(r'/+$'), ''),
      apiKey: app.library.settings['indexerKey'] as String? ?? '',
    );
  } else if (!Platform.isWindows) {
    app.setSettingsSection('sources');
    app.reportMessage(
      'Укажи URL Torznab и API key Jackett на ПК или сервере. Для телефона нужен доступный сетевой адрес.',
    );
    return;
  } else {
    connection = await app.prepareJackett();
  }
  if (connection == null || !context.mounted) return;
  try {
    final browser = _JackettBrowser();
    await browser.openUrlRequest(
      urlRequest: URLRequest(url: WebUri(connection.dashboardUrl)),
      settings: InAppBrowserClassSettings(
        browserSettings: InAppBrowserSettings(
          hideUrlBar: false,
          toolbarTopFixedTitle:
              'Jackett · добавь RuTracker.org, затем закрой окно',
        ),
        webViewSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          saveFormData: false,
        ),
      ),
    );
    await browser.closed.future;
    if (external) {
      await app.refreshSourceFeed();
    } else {
      await app.finishJackettSetup();
    }
  } catch (_) {
    app.reportError(
      'Jackett запущен, но окно настройки не открылось. Адрес: ${connection.dashboardUrl}',
    );
  }
}

class _JackettBrowser extends InAppBrowser {
  final closed = Completer<void>();
  @override
  void onExit() {
    if (!closed.isCompleted) closed.complete();
  }
}
