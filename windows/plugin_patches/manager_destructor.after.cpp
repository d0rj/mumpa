  InAppWebViewManager::~InAppWebViewManager()
  {
    debugLog("dealloc InAppWebViewManager");
    UnregisterMethodCallHandler();
    valid_ = false;
    webViews.clear();
    keepAliveWebViews.clear();
    windowWebViews.clear();
    UnregisterClass(windowClass_.lpszClassName, nullptr);
    plugin = nullptr;

    // These are inline static members upstream. Leaving them until DLL static
    // destruction releases a live queue after the application's COM teardown.
    // All browser/headless owners have been destroyed by the plugin first.
    if (compositor_) {
      auto closable = compositor_.try_as<ABI::Windows::Foundation::IClosable>();
      if (closable) closable->Close();
    }
    compositor_ = nullptr;
    graphics_context_ = nullptr;

    bool quit_seen = false;
    int quit_code = 0;
    if (dispatcher_queue_controller_) {
      try {
        winrt::Windows::System::DispatcherQueueController controller{ nullptr };
        winrt::copy_from_abi(controller, dispatcher_queue_controller_.get());
        auto shutdown = controller.ShutdownQueueAsync();
        // A current-thread DispatcherQueue can finish only while USER32 keeps
        // dispatching its work. Blocking IAsyncAction::get() would deadlock.
        while (shutdown.Status() == winrt::Windows::Foundation::AsyncStatus::Started) {
          MsgWaitForMultipleObjectsEx(0, nullptr, 25, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
          MSG message{};
          while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) {
              quit_seen = true;
              quit_code = static_cast<int>(message.wParam);
            }
            else {
              TranslateMessage(&message);
              DispatchMessage(&message);
            }
          }
        }
        shutdown.GetResults();
      }
      catch (const winrt::hresult_error&) {
        // Never relay third-party errors or private navigation state.
        OutputDebugStringW(L"Mumpa: WebView dispatcher shutdown failed.\n");
      }
    }
    dispatcher_queue_controller_ = nullptr;
    // Balance the plugin's RoInitialize on its owning UI thread, while the
    // application's RoInitialize still keeps that apartment alive.
    rohelper_ = nullptr;
    if (quit_seen) PostQuitMessage(quit_code);
  }
