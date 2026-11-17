#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <roapi.h>
#include <shobjidl.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
BOOL CALLBACK FindMumpaWindow(HWND window, LPARAM value) {
  if (::GetProp(window, L"Mumpa.MusicLinks")) {
    *reinterpret_cast<HWND*>(value) = window;
    return FALSE;
  }
  return TRUE;
}

bool ForwardMusicLink(const std::vector<std::string>& arguments, bool wait_for_window) {
  for (const auto& link : arguments) {
    if (_strnicmp(link.c_str(), "mumpa:", 6) != 0 || link.size() > 16000) continue;
    HWND existing = nullptr;
    // A second activation can precede the first runner's plugin registration.
    // Wait for that window instead of opening a competing profile writer.
    for (int attempt = 0; attempt < (wait_for_window ? 100 : 1); ++attempt) {
      ::EnumWindows(FindMumpaWindow, reinterpret_cast<LPARAM>(&existing));
      if (existing) break;
      if (wait_for_window) ::Sleep(50);
    }
    if (!existing) return false;
    COPYDATASTRUCT data = {};
    data.dwData = 0x4D554D50;
    data.cbData = static_cast<DWORD>(link.size() + 1);
    data.lpData = const_cast<char*>(link.c_str());
    DWORD_PTR result = 0;
    ::SetForegroundWindow(existing);
    return ::SendMessageTimeout(existing, WM_COPYDATA, 0,
        reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG | SMTO_BLOCK,
        5000, &result) && result == TRUE;
  }
  return false;
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  auto command_line_arguments = GetCommandLineArguments();
  auto* marker = ::CreateMutex(nullptr, FALSE, L"Local\\Mumpa.MusicLinks.Instance");
  const bool already_running = marker && ::GetLastError() == ERROR_ALREADY_EXISTS;
  std::unique_ptr<void, decltype(&::CloseHandle)> instance_marker(marker, &::CloseHandle);
  if (ForwardMusicLink(command_line_arguments, already_running)) return EXIT_SUCCESS;
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT apartment = ::RoInitialize(RO_INIT_SINGLETHREADED);
  ::SetCurrentProcessExplicitAppUserModelID(L"app.mumpa.Mumpa");
  // Service children die with the app. Only the updater explicitly requests
  // CREATE_BREAKAWAY_FROM_JOB so it can replace files after this process exits.
  HANDLE child_job = ::CreateJobObject(nullptr, nullptr);
  if (child_job) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
    ::SetInformationJobObject(child_job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
    ::AssignProcessToJobObject(child_job, ::GetCurrentProcess());
  }

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1380, 860);
  if (!window.Create(L"Mumpa", origin, size)) {
    window.Destroy();
    if (SUCCEEDED(apartment)) ::RoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Release SMTC/taskbar COM objects while the apartment is still initialized.
  window.Destroy();
  if (SUCCEEDED(apartment)) ::RoUninitialize();
  return EXIT_SUCCESS;
}
