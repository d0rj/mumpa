Mumpa applies two small shutdown overlays to `flutter_inappwebview_windows`
0.6.0 during Windows CMake configuration. It leaves the pub cache unchanged.
The helper checks the SHA256 of the original raw files, including CRLF, and
checks each exact constructor/destructor replacement and hook anchor. A dependency change fails closed
until the source and patch are reviewed.

The original `InAppWebViewManager` creates its current-thread DispatcherQueue,
Compositor and graphics context at plugin registration. Those resources are
inline static, and the upstream destructor leaves them until DLL teardown
without calling `ShutdownQueueAsync`. The overlay releases all views and
graphics resources, pumps USER32 until queue shutdown completes, then releases
the queue and the plugin's RoHelper before the runner uninitializes COM.
Any WM_QUIT removed by the nested pump is reposted with its original exit code.

The second overlay registers the live plugin instance and exports
`MumpaPrepareWebViewShutdown`. The runner calls this hook from `OnDestroy`
before destroying its FlutterViewController, while the engine and messenger
can safely receive callbacks dispatched by the queue shutdown pump. The hook
releases browser/headless owners before the shared manager and keeps the
WebView environment manager alive until all views are gone. Clearing the
registered instance before cleanup and guarding reentrant runner teardown
prevents a nested close from destroying the engine while the outer pump runs.
The later plugin destructor only resets already empty pointers; it retains
an idempotent fallback for failed registration or an absent runner hook.
This covers exiting with an account or Jackett browser window still open.

Source files retain their upstream contents except the checked constructor,
destructors, exported shutdown hook, the manager's required WinRT headers and
adjusted quoted include paths. The plugin links the `runtimeobject` import
library for C++/WinRT async and error helpers.
Generated files are written below the build directory's `mumpa_plugin_patches`.
No plugin version, Dart channel, registry setting or network behavior changes.

Pinned raw SHA256:

- `in_app_webview/in_app_webview_manager.cpp`: `eefc7b984c208696b3a3a34f99b0ddc11779fb7470009ebbabcfd274421d77ab`
- `flutter_inappwebview_windows_plugin.cpp`: `635531a17e4ac0dd103002cec0288b98016cd2be2db06e56944c216c3862389a`

References:

- [Upstream plugin](https://github.com/pichillilorenzo/flutter_inappwebview/tree/master/flutter_inappwebview_windows/windows)
- [Microsoft ShutdownQueueAsync](https://learn.microsoft.com/en-us/uwp/api/windows.system.dispatcherqueuecontroller.shutdownqueueasync)
- [Microsoft current-thread DispatcherQueue rules](https://learn.microsoft.com/en-us/windows/win32/api/dispatcherqueue/nf-dispatcherqueue-createdispatcherqueuecontroller)

Validation must include the release process exit code after creating a WebView
and while a browser window is open. A Flutter test PASS printed before native
process destruction does not prove the static teardown completed successfully.
