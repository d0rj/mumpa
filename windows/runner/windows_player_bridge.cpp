#include "windows_player_bridge.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>
#include <systemmediatransportcontrolsinterop.h>
#include <windowsx.h>

#include <algorithm>
#include <cstdint>
#include <utility>

#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 71;
constexpr UINT kMediaMessage = WM_APP + 72;
constexpr UINT kQuitReadyMessage = WM_APP + 73;
constexpr UINT kPrevious = 0xA101, kToggle = 0xA102, kNext = 0xA103;
constexpr UINT kShow = 0xA104, kQuit = 0xA105;
constexpr UINT kPlay = 0xA106, kPause = 0xA107, kStop = 0xA108;
constexpr UINT kSMTCOrigin = 1, kAppCommandOrigin = 2;
constexpr UINT kTrayId = 1;

bool ReadBool(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return false;
  const auto* value = std::get_if<bool>(&it->second);
  return value != nullptr && *value;
}

std::wstring ReadString(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return {};
  const auto* value = std::get_if<std::string>(&it->second);
  if (!value) return {};
  return std::wstring(winrt::to_hstring(*value));
}

bool IsPlayCommand(UINT action) {
  return action == kPlay || action == kPause || action == kToggle;
}

// Small transparent icons avoid external resources or font dependencies.
HICON CreateTransportIcon(UINT action) {
  constexpr int size = 32;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = size;
  info.bmiHeader.biHeight = -size;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HBITMAP color = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (!color || !pixels) return nullptr;
  auto* data = static_cast<uint32_t*>(pixels);
  std::fill(data, data + size * size, 0u);
  for (int y = 6; y < 26; ++y) {
    for (int x = 5; x < 27; ++x) {
      bool fill = false;
      if (action == kPause) {
        fill = (x >= 9 && x <= 13) || (x >= 19 && x <= 23);
      } else {
        const bool reverse = action == kPrevious;
        const int triangle_x = reverse ? 31 - x : x;
        const int distance = std::abs(y - 16);
        fill = triangle_x >= 10 && triangle_x <= 24 - distance;
        if (action == kNext) fill = fill || (x >= 25 && x <= 27);
        if (action == kPrevious) fill = fill || (x >= 5 && x <= 7);
      }
      if (fill) data[y * size + x] = 0xFFFFFFFFu;
    }
  }
  HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
  ICONINFO icon_info{};
  icon_info.fIcon = TRUE;
  icon_info.hbmColor = color;
  icon_info.hbmMask = mask;
  HICON icon = mask ? CreateIconIndirect(&icon_info) : nullptr;
  if (mask) DeleteObject(mask);
  DeleteObject(color);
  return icon;
}
}  // namespace

WindowsPlayerBridge::WindowsPlayerBridge(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window),
      taskbar_created_message_(RegisterWindowMessage(L"TaskbarCreated")),
      taskbar_button_message_(RegisterWindowMessage(L"TaskbarButtonCreated")) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "app.mumpa/windows_player", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethod(call, std::move(result));
  });
}

WindowsPlayerBridge::~WindowsPlayerBridge() {
  channel_->SetMethodCallHandler(nullptr);
  ReleaseShellResources();
}

void WindowsPlayerBridge::ReleaseShellResources() {
  initialized_ = false;
  if (media_controls_) {
    try {
      media_controls_.IsEnabled(false);
      if (media_button_registered_) media_controls_.ButtonPressed(media_button_token_);
    } catch (const winrt::hresult_error&) {
      // Explorer or the media service may have exited during shutdown.
    }
    media_controls_ = nullptr;
    media_button_registered_ = false;
  }
  if (tray_added_) {
    NOTIFYICONDATA data{};
    data.cbSize = sizeof(data);
    data.hWnd = window_;
    data.uID = kTrayId;
    Shell_NotifyIcon(NIM_DELETE, &data);
    tray_added_ = false;
  }
  taskbar_.Reset();
  thumbnail_added_ = false;
  for (auto icon : {&previous_icon_, &play_icon_, &pause_icon_, &next_icon_}) {
    if (*icon) DestroyIcon(*icon);
    *icon = nullptr;
  }
}

void WindowsPlayerBridge::InitializeMediaControls() {
  using namespace winrt::Windows::Media;
  try {
    auto factory = winrt::get_activation_factory<SystemMediaTransportControls,
                                                  ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(factory->GetForWindow(
        window_, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(media_controls_)));
    media_controls_.IsEnabled(false);
    media_controls_.IsPlayEnabled(true);
    media_controls_.IsPauseEnabled(true);
    media_controls_.IsStopEnabled(true);
    const HWND window = window_;
    media_button_token_ = media_controls_.ButtonPressed(
        [window](const SystemMediaTransportControls&,
                 const SystemMediaTransportControlsButtonPressedEventArgs& args) {
          UINT action = 0;
          switch (args.Button()) {
            case SystemMediaTransportControlsButton::Play: action = kPlay; break;
            case SystemMediaTransportControlsButton::Pause: action = kPause; break;
            case SystemMediaTransportControlsButton::Stop: action = kStop; break;
            case SystemMediaTransportControlsButton::Next: action = kNext; break;
            case SystemMediaTransportControlsButton::Previous: action = kPrevious; break;
            default: break;
          }
          if (action) PostMessage(window, kMediaMessage, action, kSMTCOrigin);
        });
    media_button_registered_ = true;
  } catch (const winrt::hresult_error&) {
    media_controls_ = nullptr;
  }
}

void WindowsPlayerBridge::AddTrayIcon() {
  NOTIFYICONDATA data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kTrayId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(data.szTip, L"Mumpa");
  tray_added_ = Shell_NotifyIcon(NIM_ADD, &data) != FALSE;
  if (tray_added_) {
    data.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIcon(NIM_SETVERSION, &data);
    UpdateTrayIcon();
  }
}

void WindowsPlayerBridge::UpdateTrayIcon() {
  if (!tray_added_) return;
  NOTIFYICONDATA data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kTrayId;
  data.uFlags = NIF_TIP;
  const auto tip = has_track_ ? title_ + L" — " + artist_ : L"Mumpa";
  wcsncpy_s(data.szTip, tip.c_str(), _TRUNCATE);
  Shell_NotifyIcon(NIM_MODIFY, &data);
}

void WindowsPlayerBridge::ShowWindow() {
  ::ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window_);
}

void WindowsPlayerBridge::ShowTrayMenu(POINT point) {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenu(menu, MF_STRING, kShow, L"Открыть Mumpa");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  const UINT enabled = has_track_ && !quit_requested_ ? MF_ENABLED : MF_GRAYED;
  AppendMenu(menu, MF_STRING | enabled, kToggle, playing_ ? L"Пауза" : L"Воспроизвести");
  AppendMenu(menu, MF_STRING | (can_previous_ && !quit_requested_ ? MF_ENABLED : MF_GRAYED),
             kPrevious, L"Предыдущий трек");
  AppendMenu(menu, MF_STRING | (can_next_ && !quit_requested_ ? MF_ENABLED : MF_GRAYED),
             kNext, L"Следующий трек");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING | (quit_requested_ ? MF_GRAYED : MF_ENABLED), kQuit, L"Выход");
  SetForegroundWindow(window_);
  const UINT action = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                                    point.x, point.y, 0, window_, nullptr);
  DestroyMenu(menu);
  PostMessage(window_, WM_NULL, 0, 0);
  if (action) SendAction(action);
}

void WindowsPlayerBridge::SendAction(UINT action, UINT media_origin) {
  if (action == kShow) { ShowWindow(); return; }
  if (quit_requested_) return;
  if (media_origin) {
    const DWORD now = GetTickCount();
    // Some devices route the same press through both SMTC and WM_APPCOMMAND.
    // Suppress only duplicate cross-path delivery, not rapid presses on one path.
    if (last_media_origin_ && media_origin != last_media_origin_ &&
        now - last_media_tick_ < 180 &&
        ((IsPlayCommand(action) && IsPlayCommand(last_media_action_)) ||
         action == last_media_action_)) return;
    last_media_origin_ = media_origin;
    last_media_action_ = action;
    last_media_tick_ = now;
  }
  if (action == kQuit) {
    quit_requested_ = true;
    if (!initialized_) {
      // There is no Dart controller to dispose if bootstrap has not attached.
      PostMessage(window_, kQuitReadyMessage, 0, 0);
      return;
    }
  } else if (!initialized_ || !has_track_) {
    return;
  }
  const char* command = nullptr;
  switch (action) {
    case kPlay: command = "play"; break;
    case kPause: command = "pause"; break;
    case kStop: command = "stop"; break;
    case kToggle: command = "toggle"; break;
    case kNext: command = "next"; break;
    case kPrevious: command = "previous"; break;
    case kQuit: command = "quit"; break;
    default: return;
  }
  UpdateThumbnailButtons();
  channel_->InvokeMethod("command", std::make_unique<flutter::EncodableValue>(command));
}

void WindowsPlayerBridge::UpdateState(const flutter::EncodableMap& state) {
  using namespace winrt::Windows::Media;
  has_track_ = ReadBool(state, "hasTrack");
  playing_ = ReadBool(state, "playing");
  can_previous_ = ReadBool(state, "canPrevious");
  can_next_ = ReadBool(state, "canNext");
  title_ = ReadString(state, "title");
  artist_ = ReadString(state, "artist");
  album_ = ReadString(state, "album");
  UpdateTrayIcon();
  UpdateThumbnailButtons();
  if (media_controls_) {
    try {
      media_controls_.IsEnabled(has_track_ && !quit_requested_);
      media_controls_.IsNextEnabled(can_next_);
      media_controls_.IsPreviousEnabled(can_previous_);
      media_controls_.PlaybackStatus(!has_track_ ? MediaPlaybackStatus::Closed
          : playing_ ? MediaPlaybackStatus::Playing : MediaPlaybackStatus::Paused);
      auto updater = media_controls_.DisplayUpdater();
      updater.Type(MediaPlaybackType::Music);
      updater.MusicProperties().Title(title_);
      updater.MusicProperties().Artist(artist_);
      updater.MusicProperties().AlbumTitle(album_);
      updater.Update();
    } catch (const winrt::hresult_error&) {
      // Shell integration must not interrupt the audio decoder.
    }
  }
}

void WindowsPlayerBridge::UpdateThumbnailButtons() {
  if (!taskbar_) return;
  THUMBBUTTON buttons[3]{};
  const UINT ids[] = {kPrevious, kToggle, kNext};
  const HICON icons[] = {previous_icon_, playing_ ? pause_icon_ : play_icon_, next_icon_};
  const wchar_t* tips[] = {L"Предыдущий трек", playing_ ? L"Пауза" : L"Воспроизвести",
                           L"Следующий трек"};
  const bool enabled[] = {can_previous_, has_track_, can_next_};
  for (int i = 0; i < 3; ++i) {
    buttons[i].dwMask = static_cast<THUMBBUTTONMASK>(THB_ICON | THB_TOOLTIP | THB_FLAGS);
    buttons[i].iId = ids[i];
    buttons[i].hIcon = icons[i];
    buttons[i].dwFlags = enabled[i] && !quit_requested_ ? THBF_ENABLED : THBF_DISABLED;
    wcsncpy_s(buttons[i].szTip, tips[i], _TRUNCATE);
  }
  if (thumbnail_added_) {
    taskbar_->ThumbBarUpdateButtons(window_, 3, buttons);
  } else {
    thumbnail_added_ = SUCCEEDED(taskbar_->ThumbBarAddButtons(window_, 3, buttons));
  }
}

void WindowsPlayerBridge::HandleMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "initialize") {
    if (!initialized_) {
      initialized_ = true;
      quit_requested_ = false;
      previous_icon_ = CreateTransportIcon(kPrevious);
      play_icon_ = CreateTransportIcon(kPlay);
      pause_icon_ = CreateTransportIcon(kPause);
      next_icon_ = CreateTransportIcon(kNext);
      if (SUCCEEDED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&taskbar_)))) {
        if (FAILED(taskbar_->HrInit())) taskbar_.Reset();
      }
      InitializeMediaControls();
      AddTrayIcon();
      UpdateThumbnailButtons();
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("smtc"), flutter::EncodableValue(media_controls_ != nullptr)},
        {flutter::EncodableValue("tray"), flutter::EncodableValue(tray_added_)},
        {flutter::EncodableValue("thumbnail"), flutter::EncodableValue(taskbar_ != nullptr)}}));
  } else if (call.method_name() == "diagnostics") {
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("initialized"), flutter::EncodableValue(initialized_)},
        {flutter::EncodableValue("windowVisible"), flutter::EncodableValue(IsWindowVisible(window_) != FALSE)},
        {flutter::EncodableValue("windowHandle"), flutter::EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(window_)))},
        {flutter::EncodableValue("trayReady"), flutter::EncodableValue(tray_added_)},
        {flutter::EncodableValue("taskbarButtonsAdded"), flutter::EncodableValue(thumbnail_added_)},
        {flutter::EncodableValue("smtc"), flutter::EncodableValue(media_controls_ != nullptr)},
        {flutter::EncodableValue("quitting"), flutter::EncodableValue(quit_requested_)}}));
  } else if (call.method_name() == "dispose") {
    ReleaseShellResources();
    result->Success();
  } else if (call.method_name() == "updateState") {
    const auto* state = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    if (!state) { result->Error("invalid-state", "Expected playback state map"); return; }
    UpdateState(*state);
    result->Success();
  } else if (call.method_name() == "show") {
    ShowWindow();
    result->Success();
  } else if (call.method_name() == "revealFile") {
    const auto* path = call.arguments()
        ? std::get_if<std::string>(call.arguments()) : nullptr;
    if (!path || path->empty() || path->find('\0') != std::string::npos) {
      result->Error("invalid-path", "Expected a file path");
      return;
    }
    const std::wstring wide_path(winrt::to_hstring(*path));
    const DWORD attributes = GetFileAttributesW(wide_path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
      result->Error("file-not-found", "Track file not found");
      return;
    }
    PIDLIST_ABSOLUTE item = nullptr;
    HRESULT status = SHParseDisplayName(wide_path.c_str(), nullptr, &item, 0, nullptr);
    if (SUCCEEDED(status)) {
      // With zero children the Shell opens the parent and selects this file.
      status = SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
    }
    CoTaskMemFree(item);
    if (FAILED(status)) {
      result->Error("reveal-failed", "Could not show track file in Explorer");
      return;
    }
    result->Success();
  } else if (call.method_name() == "quitReady") {
    result->Success();
    PostMessage(window_, kQuitReadyMessage, 0, 0);
  } else if (call.method_name() == "quitFailed") {
    quit_requested_ = false;
    UpdateThumbnailButtons();
    ShowWindow();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

std::optional<LRESULT> WindowsPlayerBridge::HandleMessage(
    UINT message, WPARAM wparam, LPARAM lparam) noexcept {
  if (message == taskbar_created_message_) {
    tray_added_ = false;
    thumbnail_added_ = false;
    if (initialized_) AddTrayIcon();
    return 0;
  }
  if (message == taskbar_button_message_) {
    thumbnail_added_ = false;
    UpdateThumbnailButtons();
    return 0;
  }
  switch (message) {
    case WM_CLOSE:
      // Test runners and a not-yet-ready bootstrap retain normal window close.
      if (!initialized_) return std::nullopt;
      if (tray_added_) ::ShowWindow(window_, SW_HIDE);
      else SendAction(kQuit);
      return 0;
    case kQuitReadyMessage:
      // Dart acknowledged only after saving and disposing application services.
      DestroyWindow(window_);
      return 0;
    case kMediaMessage:
      SendAction(static_cast<UINT>(wparam), static_cast<UINT>(lparam));
      return 0;
    case kTrayMessage: {
      const UINT event = LOWORD(lparam);
      if (event == NIN_SELECT || event == NIN_KEYSELECT || event == WM_LBUTTONDBLCLK) {
        ShowWindow();
      } else if (event == WM_CONTEXTMENU) {
        POINT point{GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)};
        if (point.x == -1 && point.y == -1) GetCursorPos(&point);
        ShowTrayMenu(point);
      }
      return 0;
    }
    case WM_COMMAND:
      if (HIWORD(wparam) == THBN_CLICKED) {
        const UINT action = LOWORD(wparam);
        if (action == kPrevious || action == kToggle || action == kNext) {
          SendAction(action);
          return 0;
        }
      }
      break;
    case WM_APPCOMMAND: {
      if (!initialized_) return std::nullopt;
      UINT action = 0;
      switch (GET_APPCOMMAND_LPARAM(lparam)) {
        case APPCOMMAND_MEDIA_PLAY_PAUSE: action = kToggle; break;
        case APPCOMMAND_MEDIA_PLAY: action = kPlay; break;
        case APPCOMMAND_MEDIA_PAUSE: action = kPause; break;
        case APPCOMMAND_MEDIA_STOP: action = kStop; break;
        case APPCOMMAND_MEDIA_NEXTTRACK: action = kNext; break;
        case APPCOMMAND_MEDIA_PREVIOUSTRACK: action = kPrevious; break;
        default: break;
      }
      if (action) { SendAction(action, kAppCommandOrigin); return TRUE; }
      break;
    }
  }
  return std::nullopt;
}
