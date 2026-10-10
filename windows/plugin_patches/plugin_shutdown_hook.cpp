namespace {
  using MumpaWebViewPlugin = flutter_inappwebview_plugin::FlutterInappwebviewWindowsPlugin;
  MumpaWebViewPlugin* mumpa_registered_webview_plugin = nullptr;

  void MumpaDisposeWebViewResources(MumpaWebViewPlugin* plugin)
  {
    // Owners may hold composition resources and WebView environments. Keep the
    // environment alive until every view and the shared dispatcher are gone.
    plugin->cookieManager = nullptr;
    plugin->inAppBrowserManager = nullptr;
    plugin->headlessInAppWebViewManager = nullptr;
    plugin->inAppWebViewManager = nullptr;
    plugin->webViewEnvironmentManager = nullptr;
  }
}

extern "C" __declspec(dllexport) void MumpaPrepareWebViewShutdown()
{
  // Called on the runner's owning UI thread BEFORE destroying the Flutter
  // engine. Queue shutdown pumps USER32 and may dispatch Flutter callbacks.
  auto* plugin = mumpa_registered_webview_plugin;
  mumpa_registered_webview_plugin = nullptr;
  if (plugin) MumpaDisposeWebViewResources(plugin);
}
