  FlutterInappwebviewWindowsPlugin::~FlutterInappwebviewWindowsPlugin()
  {
    if (mumpa_registered_webview_plugin == this) {
      mumpa_registered_webview_plugin = nullptr;
    }
    // The runner normally cleared these before engine teardown. Keep a
    // fallback for registration failure, with idempotent empty-pointer resets.
    MumpaDisposeWebViewResources(this);
  }
