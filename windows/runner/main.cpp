#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <roapi.h>
#include <shobjidl.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT apartment = ::RoInitialize(RO_INIT_SINGLETHREADED);
  ::SetCurrentProcessExplicitAppUserModelID(L"app.mumpa.Mumpa");
  // The bundled torrent child must not survive closing the desktop app.
  HANDLE child_job = ::CreateJobObject(nullptr, nullptr);
  if (child_job) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    ::SetInformationJobObject(child_job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
    ::AssignProcessToJobObject(child_job, ::GetCurrentProcess());
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

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
