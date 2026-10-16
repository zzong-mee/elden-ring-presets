#pragma once
#include <array>
#include <optional>
namespace erp {
struct Action { bool save; unsigned preset; };
class Hotkeys {
    std::array<bool, 8> previous_{};
public:
    // Call on the game thread. Every frame, including while inactive, to consume held keys.
    std::optional<Action> update(const std::array<bool, 8>& down, bool active) {
        std::optional<Action> action;
        for (unsigned i = 0; i < 8; ++i)
            if (active && down[i] && !previous_[i] && !action) action = Action{i < 4, i % 4 + 1};
        previous_ = down;
        return action;
    }
};
}
