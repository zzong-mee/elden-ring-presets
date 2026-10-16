#pragma once
#ifdef _WIN32
#include <windows.h>
#include "presets.hpp"
#include "hotkeys.hpp"
namespace erp {
Result poll_windows_keys(Controller&, Hotkeys&, HWND game_window, bool input_allowed);
}
#endif
