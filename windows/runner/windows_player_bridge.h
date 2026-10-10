#ifndef RUNNER_WINDOWS_PLAYER_BRIDGE_H_
#define RUNNER_WINDOWS_PLAYER_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <shobjidl.h>
#include <windows.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <wrl/client.h>

#include <memory>
#include <optional>
#include <string>

// Owns shell resources for the Flutter top-level window. All Flutter calls run
// on that window's thread; SMTC callbacks only post a window message.
class WindowsPlayerBridge {
 public:
  WindowsPlayerBridge(HWND window, flutter::BinaryMessenger* messenger);
  ~WindowsPlayerBridge();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam) noexcept;

 private:
  void InitializeMediaControls();
  void ReleaseShellResources();
  void AddTrayIcon();
  void UpdateTrayIcon();
  void ShowTrayMenu(POINT point);
  void ShowWindow();
  void SendAction(UINT action, UINT media_origin = 0);
  void UpdateState(const flutter::EncodableMap& state);
  void UpdateThumbnailButtons();
  void HandleMethod(const flutter::MethodCall<flutter::EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  Microsoft::WRL::ComPtr<ITaskbarList3> taskbar_;
  winrt::Windows::Media::SystemMediaTransportControls media_controls_{nullptr};
  winrt::event_token media_button_token_{};
  bool media_button_registered_ = false;
  UINT taskbar_created_message_, taskbar_button_message_;
  HICON previous_icon_ = nullptr, play_icon_ = nullptr;
  HICON pause_icon_ = nullptr, next_icon_ = nullptr;
  bool tray_added_ = false, thumbnail_added_ = false, initialized_ = false;
  bool quit_requested_ = false, has_track_ = false, playing_ = false;
  bool can_previous_ = false, can_next_ = false;
  std::wstring title_, artist_, album_;
  DWORD last_media_tick_ = 0;
  UINT last_media_action_ = 0, last_media_origin_ = 0;
};

#endif  // RUNNER_WINDOWS_PLAYER_BRIDGE_H_
