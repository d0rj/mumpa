"""Send a Back side-button click only to the supplied test process's Flutter view."""
import ctypes
import json
import sys
from ctypes import wintypes

target_pid = int(sys.argv[1])
user32 = ctypes.WinDLL('user32', use_last_error=True)
callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
user32.EnumChildWindows.argtypes = [wintypes.HWND, callback_type, wintypes.LPARAM]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
views = []

@callback_type
def inspect(hwnd, _):
    owner = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
    if owner.value != target_pid:
        return True
    name = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, name, len(name))
    if name.value == 'FLUTTERVIEW':
        views.append(hwnd)
    return True

@callback_type
def roots(hwnd, _):
    owner = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
    if owner.value == target_pid:
        inspect(hwnd, 0)
        user32.EnumChildWindows(hwnd, inspect, 0)
    return True

user32.EnumWindows(roots, 0)
views = list(dict.fromkeys(views))
assert len(views) == 1, f'Expected exactly one owned Flutter view, found {len(views)}'
point = (300 << 16) | 400
assert user32.PostMessageW(views[0], 0x0200, 0, point)
assert user32.PostMessageW(views[0], 0x020B, (1 << 16) | 0x0020, point)
assert user32.PostMessageW(views[0], 0x020C, 1 << 16, point)
print(json.dumps({'ownedPid': target_pid, 'sideButton': 'XBUTTON1', 'posted': True}))
