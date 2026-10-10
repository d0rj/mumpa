"""Check native exit with isolated, still-open WebView owners.

Build --target integration_test/fixtures/windows_browser_lifecycle.dart first.
This tool starts exactly that caller-specified executable once, closes only its
own PID's Flutter main window and checks the real process exit code. No user
profile, services, network settings or OS configuration are accessed.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


TEMP_PREFIX = "mumpa-browser-lifecycle-"
WINDOW_CLASS = "FLUTTER_RUNNER_WIN32_WINDOW"


def find_main_window(pid: int) -> int | None:
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
    user32.EnumWindows.restype = wintypes.BOOL
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    user32.GetClassNameW.restype = ctypes.c_int
    found: list[int] = []

    @callback_type
    def visit(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid:
            name = ctypes.create_unicode_buffer(256)
            user32.GetClassNameW(hwnd, name, len(name))
            if name.value == WINDOW_CLASS:
                found.append(int(hwnd))
                return False
        return True

    user32.EnumWindows(visit, 0)
    return found[0] if found else None


def close_own_window(pid: int, hwnd: int) -> bool:
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
    user32.PostMessageW.restype = wintypes.BOOL
    owner = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
    if owner.value != pid:
        return False
    return bool(user32.PostMessageW(hwnd, 0x0010, 0, 0))  # WM_CLOSE


def remove_reported_temporary(data: dict) -> bool:
    """Delete only the exact reported fixture child of the system temp base."""
    reported = data.get("temporaryDirectory")
    if not isinstance(reported, str):
        return False
    path = Path(reported)
    temp_base = Path(tempfile.gettempdir()).resolve(strict=True)
    if not path.is_absolute() or path.is_symlink():
        return False
    resolved = path.resolve(strict=False)
    if resolved.parent != temp_base or not resolved.name.startswith(TEMP_PREFIX):
        return False
    if resolved == temp_base or len(resolved.name) <= len(TEMP_PREFIX):
        return False
    # WebView2 descendants may take a moment to release cache files after exit.
    for _ in range(40):
        try:
            if resolved.exists():
                shutil.rmtree(resolved)
            return True
        except OSError:
            time.sleep(0.125)
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--application", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This check requires Windows.")
    if not args.application.is_absolute() or not args.evidence.is_absolute():
        parser.error("Application and evidence paths must be absolute.")
    application = args.application.resolve(strict=True)
    evidence = args.evidence.resolve(strict=False)
    if not application.is_file() or application == evidence:
        parser.error("Expected a fixture executable and a separate evidence file.")
    evidence.parent.mkdir(parents=True, exist_ok=True)
    evidence.unlink(missing_ok=True)
    result_path = evidence.with_suffix(".result.json")
    result = {
        "ready": False,
        "environmentReady": False,
        "headlessReady": False,
        "browserReady": False,
        "mainWindowFound": False,
        "closedViaWMClose": False,
        "forcedTermination": False,
        "timedOut": False,
        "temporaryDirectoryRemoved": False,
        "exitCode": None,
    }
    readiness: dict = {}
    process = None
    try:
        process = subprocess.Popen(
            [str(application), f"--evidence={evidence}"],
            cwd=str(application.parent),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        deadline = time.monotonic() + 90
        while process.poll() is None and time.monotonic() < deadline:
            if evidence.exists():
                try:
                    candidate = json.loads(evidence.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    candidate = {}
                if candidate.get("isBrowserLifecycleFixture") is True:
                    readiness = candidate
                    for flag in ("ready", "environmentReady", "headlessReady", "browserReady"):
                        result[flag] = candidate.get(flag) is True
                    break
            time.sleep(0.1)
        if not readiness and process.poll() is None:
            result["timedOut"] = True
        if process.poll() is None:
            hwnd = find_main_window(process.pid)
            result["mainWindowFound"] = hwnd is not None
            if hwnd is not None:
                result["closedViaWMClose"] = close_own_window(process.pid, hwnd)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                result["timedOut"] = True
        result["exitCode"] = process.poll()
    except Exception as error:
        # Exception messages could include paths or third-party diagnostics.
        result["errorType"] = type(error).__name__
    finally:
        if process is not None and process.poll() is None:
            result["forcedTermination"] = True
            process.kill()  # Only the Popen process created by this invocation.
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
        if process is not None:
            result["exitCode"] = process.poll()
        if readiness:
            result["temporaryDirectoryRemoved"] = remove_reported_temporary(readiness)
        if isinstance(result["exitCode"], int):
            result["exitCodeHex"] = f"0x{result['exitCode'] & 0xffffffff:08x}"
        result["passed"] = (
            result["ready"] and result["environmentReady"]
            and result["headlessReady"] and result["browserReady"]
            and result["mainWindowFound"] and result["closedViaWMClose"]
            and result["exitCode"] == 0 and not result["forcedTermination"]
            and not result["timedOut"] and result["temporaryDirectoryRemoved"]
        )
        result_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(json.dumps(result, sort_keys=True))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
