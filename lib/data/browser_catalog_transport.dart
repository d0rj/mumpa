import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'rutracker_service.dart';

// Pages use the platform browser, including its normal site verification and
// cookie store. Login is performed on the site's own page; Mumpa never reads
// the password or exports browser cookies to library.json.
class BrowserCatalogTransport implements CatalogTransport {
  BrowserCatalogTransport(this.directory);
  final Directory directory;
  WebViewEnvironment? _environment;
  HeadlessInAppWebView? _headless;
  Future<void>? _initializing;
  Future<void> _tail = Future.value();
  Completer<String>? _pending;
  Uri? _lastUri;
  _AccountBrowser? _browser;
  bool _disposed = false;
  Future<void>? _disposing;

  void _checkOpen() {
    if (_disposed) throw const CatalogException('Каталог закрыт.');
  }

  Future<void> _initialize() {
    _checkOpen();
    return _initializing ??= _create().catchError((
      Object error,
      StackTrace stack,
    ) async {
      await _releaseWebView();
      _initializing = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _create() async {
    if (Platform.isWindows) {
      final version = await WebViewEnvironment.getAvailableVersion();
      _checkOpen();
      if (version == null) {
        throw const CatalogException(
          'Для каталога нужен Microsoft Edge WebView2 Runtime. Установи его и перезапусти Mumpa.',
        );
      }
      await directory.create(recursive: true);
      _checkOpen();
      _environment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: p.join(directory.path, 'browser'),
        ),
      );
      _checkOpen();
    }
    final created = Completer<void>();
    _headless = HeadlessInAppWebView(
      webViewEnvironment: _environment,
      initialUrlRequest: URLRequest(url: WebUri('about:blank')),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        saveFormData: false,
      ),
      onWebViewCreated: (_) {
        if (!created.isCompleted) created.complete();
      },
      onLoadStop: (controller, url) async {
        final pending = _pending;
        if (pending == null || pending.isCompleted || url?.scheme != 'https') {
          return;
        }
        try {
          final text = await controller.getHtml() ?? '';
          if (!pending.isCompleted) pending.complete(text);
        } catch (e) {
          if (!pending.isCompleted) {
            pending.completeError(
              const CatalogException(
                'Не удалось прочитать страницу RuTracker. Попробуй ещё раз.',
              ),
            );
          }
        }
      },
      onReceivedError: (_, request, error) {
        if (error.type == WebResourceErrorType.CANCELLED ||
            request.url.scheme == 'about') {
          return;
        }
        final pending = _pending;
        if (request.isForMainFrame == true &&
            pending != null &&
            !pending.isCompleted) {
          pending.completeError(
            CatalogException(
              'Не удалось открыть RuTracker: ${error.description}',
            ),
          );
        }
      },
    );
    await _headless!.run();
    await created.future.timeout(const Duration(seconds: 20));
    _checkOpen();
  }

  @override
  Future<String> load(Uri uri) {
    final result = _tail.then((_) async {
      if (_disposed) throw const CatalogException('Каталог закрыт.');
      try {
        await _initialize();
        _checkOpen();
        _lastUri = uri;
        final pending = Completer<String>();
        // Native callbacks can finish while loadUrl is still awaiting its ack.
        unawaited(
          pending.future.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        );
        _pending = pending;
        await _headless!.webViewController!.loadUrl(
          urlRequest: URLRequest(url: WebUri.uri(uri)),
        );
        try {
          return await pending.future.timeout(const Duration(seconds: 30));
        } finally {
          if (identical(_pending, pending)) _pending = null;
        }
      } on TimeoutException {
        throw const CatalogException(
          'RuTracker не ответил за 30 секунд. Проверь соединение или выбери зеркало в настройках.',
        );
      } on CatalogException {
        rethrow;
      } catch (_) {
        await _releaseWebView();
        _initializing = null;
        throw const CatalogException(
          'Не удалось запустить браузер каталога. Перезапусти Mumpa и проверь WebView2 на Windows.',
        );
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<void> connect(Uri uri) async {
    await _tail;
    await _initialize();
    _checkOpen();
    final browser = _AccountBrowser(webViewEnvironment: _environment);
    _browser = browser;
    final target = uri.path.endsWith('login.php') ? uri : _lastUri ?? uri;
    try {
      await browser.openUrlRequest(
        urlRequest: URLRequest(url: WebUri.uri(target)),
        settings: InAppBrowserClassSettings(
          browserSettings: InAppBrowserSettings(
            hideUrlBar: false,
            toolbarTopFixedTitle: 'RuTracker · после входа закрой это окно',
          ),
          webViewSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            saveFormData: false,
          ),
        ),
      );
      await browser.closed.future;
    } finally {
      if (identical(_browser, browser)) _browser = null;
    }
  }

  @override
  Future<void> logout(Uri origin) async {
    await _tail;
    await _initialize();
    _checkOpen();
    await CookieManager.instance(
      webViewEnvironment: _environment,
    ).deleteCookies(url: WebUri.uri(origin));
    await CookieManager.instance(
      webViewEnvironment: _environment,
    ).deleteCookies(url: WebUri.uri(origin.resolve('forum/')));
  }

  @override
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const CatalogException('Каталог закрыт.'));
    }
    try {
      await _initializing;
    } catch (_) {
      // Failed/late creation still owns resources until it has settled.
    }
    final browser = _browser;
    _browser = null;
    try {
      await browser?.close();
    } finally {
      if (browser != null && !browser.closed.isCompleted) {
        browser.closed.complete();
      }
      await _releaseWebView();
    }
  }

  Future<void> _releaseWebView() async {
    final headless = _headless;
    _headless = null;
    final environment = _environment;
    _environment = null;
    try {
      await headless?.dispose();
    } finally {
      if (environment != null) {
        // flutter_inappwebview_windows 0.6.0 attaches the dispose channel to the
        // static factory id instead of the created environment id.
        await MethodChannel(
          'com.pichillilorenzo/flutter_webview_environment_${environment.id}',
        ).invokeMethod<void>('dispose');
      }
    }
  }
}

class _AccountBrowser extends InAppBrowser {
  _AccountBrowser({super.webViewEnvironment});
  final closed = Completer<void>();
  @override
  void onExit() {
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> onLoadStop(WebUri? url) async {
    if (url == null ||
        !RuTrackerService.mirrors.any(
          (base) => Uri.parse(base).host == url.host,
        )) {
      return;
    }
    final username = await webViewController?.evaluateJavascript(
      source:
          'document.getElementById("logged-in-username")?.textContent || ""',
    );
    if (username is String && username.trim().isNotEmpty) await close();
  }
}
