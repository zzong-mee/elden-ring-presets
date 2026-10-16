#include "presets.hpp"
#include <fstream>
#include <limits>
#include <stdexcept>
#include <system_error>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif
namespace erp {
Plan plan(const Loadout& target, const std::vector<InventoryItem>& inventory) {
    Plan result;
    std::vector<bool> used(inventory.size(), false);
    for (std::size_t slot = 0; slot < target.size(); ++slot) {
        if (!target[slot]) { result.changes.push_back({slot, std::nullopt}); continue; }
        bool found = false;
        for (std::size_t i = 0; i < inventory.size(); ++i) {
            if (!used[i] && inventory[i].id == *target[slot]) {
                used[i] = true;
                result.changes.push_back({slot, inventory[i].handle});
                found = true;
                break;
            }
        }
        if (!found) result.missing.push_back(slot);
    }
    return result;
}
Store::Store(std::filesystem::path directory): directory_(std::move(directory)) {}
std::filesystem::path Store::path(unsigned preset) const {
    if (preset < 1 || preset > 4) throw std::invalid_argument("Preset must be 1..4");
    return directory_ / ("preset-" + std::to_string(preset) + ".txt");
}
void Store::save(unsigned preset, const Loadout& loadout) {
    const auto destination = path(preset);
    std::filesystem::create_directories(directory_);
    auto temporary = destination; temporary += ".tmp";
    {
        std::ofstream out(temporary, std::ios::trunc);
        out.exceptions(std::ios::badbit | std::ios::failbit);
        out << "ERP1\n";
        for (auto item : loadout) {
            if (item) out << *item << '\n'; else out << "empty\n";
        }
        out.flush();
        out.close();
    }
#ifdef _WIN32
    if (!MoveFileExW(temporary.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        throw std::system_error(static_cast<int>(GetLastError()), std::system_category(), "Preset replacement failed");
#else
    std::filesystem::rename(temporary, destination);
#endif
}
std::optional<Loadout> Store::load(unsigned preset) const {
    auto file = path(preset);
    if (!std::filesystem::exists(file)) return std::nullopt;
    std::ifstream in(file);
    if (!in) throw std::runtime_error("Cannot read preset");
    std::string token;
    if (!(in >> token) || token != "ERP1") throw std::runtime_error("Unsupported preset format");
    Loadout loadout{};
    for (auto& item : loadout) {
        if (!(in >> token)) throw std::runtime_error("Truncated preset");
        if (token == "empty") continue;
        if (token.empty() || token.find_first_not_of("0123456789") != std::string::npos)
            throw std::runtime_error("Invalid item ID");
        auto id = std::stoull(token);
        if (id > std::numeric_limits<ItemId>::max()) throw std::runtime_error("Item ID out of range");
        item = static_cast<ItemId>(id);
    }
    if (in >> token) throw std::runtime_error("Unexpected preset data");
    return loadout;
}
Controller::Controller(Game& game, std::filesystem::path root): game_(game), root_(std::move(root)) {}
Store Controller::store() {
    const auto id = game_.character();
    if (id.empty() || id == "." || id == ".." || id.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") != std::string::npos)
        throw std::runtime_error("Invalid character identity");
    return Store(root_ / id);
}
Result Controller::save(unsigned preset) {
    try {
        if (!game_.ready()) return {false, "Game is not ready for equipment operations", {}};
        auto storage = store();
        storage.save(preset, game_.equipped());
        return {true, "Preset saved", {}};
    } catch (const std::exception& e) { return {false, e.what(), {}}; }
}
Result Controller::recall(unsigned preset) {
    try {
        if (!game_.ready()) return {false, "Game is not ready for equipment operations", {}};
        const auto saved = store().load(preset);
        if (!saved) return {false, "Preset has not been saved", {}};
        const auto changes = plan(*saved, game_.inventory());
        if (!game_.apply(changes.changes)) return {false, "Equipment operation failed; inspect current equipment", changes.missing};
        return {true, changes.missing.empty() ? "Preset equipped" : "Preset equipped; missing items left unchanged", changes.missing};
    } catch (const std::exception& e) { return {false, e.what(), {}}; }
}
}
