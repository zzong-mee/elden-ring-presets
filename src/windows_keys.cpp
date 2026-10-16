// Optional Windows adapter. A game integration must call this on its game-thread tick.
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "hotkeys.hpp"
#include "presets.hpp"
namespace erp {
Result poll_windows_keys(Controller& controller, Hotkeys& keys, HWND game_window, bool input_allowed) {
    const int codes[] = {VK_F1, VK_F2, VK_F3, VK_F4, '1', '2', '3', '4'};
    std::array<bool, 8> down{};
    for (unsigned i = 0; i < 8; ++i) down[i] = (GetAsyncKeyState(codes[i]) & 0x8000) != 0;
    const auto action = keys.update(down, input_allowed && game_window && GetForegroundWindow() == game_window);
    if (!action) return {true, "", {}};
    return action->save ? controller.save(action->preset) : controller.recall(action->preset);
}
}
#endif
