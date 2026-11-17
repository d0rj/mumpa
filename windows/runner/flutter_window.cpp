#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

// Exported by the pinned WebView plugin overlay. It must drain its current-
// thread dispatcher while the Flutter engine and messenger are still alive.
extern "C" __declspec(dllimport) void MumpaPrepareWebViewShutdown();

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  windows_player_ = std::make_unique<WindowsPlayerBridge>(
      GetHandle(), flutter_controller_->engine()->messenger());
  links_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "app.mumpa/links",
      &flutter::StandardMethodCodec::GetInstance());
  links_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "takeLinks") {
      result->NotImplemented();
      return;
    }
    flutter::EncodableList values;
    for (const auto& link : pending_links_) values.emplace_back(link);
    pending_links_.clear();
    links_ready_ = true;
    result->Success(flutter::EncodableValue(values));
  });
  ::SetProp(GetHandle(), L"Mumpa.MusicLinks", reinterpret_cast<HANDLE>(1));

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // The WebView shutdown pump can reenter the runner through queued messages.
  // A nested close must not destroy the engine underneath that outer pump.
  static bool teardown_in_progress = false;
  if (teardown_in_progress) return;
  teardown_in_progress = true;
  ::RemoveProp(GetHandle(), L"Mumpa.MusicLinks");
  links_ = nullptr;
  windows_player_ = nullptr;
  if (flutter_controller_) {
    MumpaPrepareWebViewShutdown();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
  teardown_in_progress = false;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_COPYDATA && links_) {
    const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (data && data->dwData == 0x4D554D50 && data->lpData &&
        data->cbData > 1 && data->cbData <= 16001) {
      const auto* bytes = static_cast<const char*>(data->lpData);
      if (bytes[data->cbData - 1] != '\0') return FALSE;
      std::string link(bytes, data->cbData - 1);
      if (_strnicmp(link.c_str(), "mumpa:", 6) != 0 || link.find('\0') != std::string::npos) return FALSE;
      if (links_ready_) {
        links_->InvokeMethod("open", std::make_unique<flutter::EncodableValue>(link));
      } else {
        if (pending_links_.size() >= 32) return FALSE;
        pending_links_.push_back(link);
      }
      ::ShowWindow(hwnd, SW_RESTORE);
      ::SetForegroundWindow(hwnd);
      return TRUE;
    }
    return FALSE;
  }
  // Handle close-to-tray and shell commands before plugins or DefWindowProc.
  if (windows_player_) {
    auto result = windows_player_->HandleMessage(message, wparam, lparam);
    if (result) return *result;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
