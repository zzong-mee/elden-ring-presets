#include "presets.hpp"
#include "hotkeys.hpp"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <chrono>
using namespace erp;
void require(bool condition) { if (!condition) throw std::runtime_error("Check failed"); }
struct FakeGame : Game {
    bool available = true;
    bool apply_ok = true;
    unsigned calls = 0;
    std::string identity = "character-1";
    Loadout current{};
    std::vector<InventoryItem> items;
    std::vector<Change> applied;
    bool ready() override { return available; }
    std::string character() override { return identity; }
    Loadout equipped() override { return current; }
    std::vector<InventoryItem> inventory() override { return items; }
    bool apply(const std::vector<Change>& changes) override { ++calls; applied = changes; return apply_ok; }
};
int main() {
    auto root = std::filesystem::temp_directory_path() / ("erp-test-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    try {
        Store store(root);
        Loadout saved{}; saved[0] = 100; saved[1] = 100; saved[6] = 4000000000U;
        require(!store.load(1));
        store.save(1, saved);
        require(store.load(1) == saved);
        store.save(4, saved);
        require(store.load(4) == saved);
        saved[0] = 200;
        store.save(1, saved);
        require(store.load(1) == saved);
        bool rejected = false;
        try { store.save(0, saved); } catch (const std::invalid_argument&) { rejected = true; }
        require(rejected);
        rejected = false;
        try { store.save(5, saved); } catch (const std::invalid_argument&) { rejected = true; }
        require(rejected);
        auto p = plan(saved, {{200, 10}, {100, 20}});
        require(p.missing == std::vector<std::size_t>{6});
        require(p.changes[0].handle == 10 && p.changes[1].handle == 20);
        require(!p.changes[2].handle); // empty slot explicitly unequips
        saved[0] = 100;
        p = plan(saved, {{100, 20}});
        require(p.missing == (std::vector<std::size_t>{1,6})); // no duplicate handle reuse
        { std::ofstream out(root / "preset-2.txt"); out << "ERP1\n100\n"; }
        rejected = false;
        try { (void)store.load(2); } catch (const std::runtime_error&) { rejected = true; }
        require(rejected);
        { std::ofstream out(root / "preset-3.txt"); out << "ERP1\n-1\n"; }
        rejected = false;
        try { (void)store.load(3); } catch (const std::runtime_error&) { rejected = true; }
        require(rejected);
        FakeGame game; game.current = saved; game.items = {{100, 20}};
        Controller controller(game, root / "characters");
        require(!controller.recall(1).ok && game.calls == 0);
        require(controller.save(1).ok);
        auto result = controller.recall(1);
        require(result.ok && result.missing == (std::vector<std::size_t>{1,6}));
        game.available = false;
        require(!controller.save(1).ok && !controller.recall(1).ok && game.calls == 1);
        game.available = true;
        game.identity = "character-2";
        require(!controller.recall(1).ok && game.calls == 1);
        game.identity = "../escape";
        require(!controller.save(1).ok);
        game.identity = "character-1"; game.apply_ok = false;
        require(!controller.recall(1).ok);
        Hotkeys keys;
        std::array<bool, 8> down{}; down[0] = true;
        auto action = keys.update(down, true);
        require(action && action->save && action->preset == 1);
        require(!keys.update(down, true));
        down[0] = false; (void)keys.update(down, true);
        down[7] = true; require(!keys.update(down, false));
        require(!keys.update(down, true)); // refocus must not trigger held key
        down[7] = false; (void)keys.update(down, true);
        down[7] = true; action = keys.update(down, true);
        require(action && !action->save && action->preset == 4);
        down.fill(false); (void)keys.update(down, true);
        down[3] = true; action = keys.update(down, true);
        require(action && action->save && action->preset == 4);
        std::filesystem::remove_all(root);
        std::cout << "PASS: persistence, overwrite, invalid files, matching, missing items, duplicate copies, character isolation, readiness, apply failure, hotkey edges\n";
    } catch (...) { std::filesystem::remove_all(root); throw; }
}
