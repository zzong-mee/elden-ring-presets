#pragma once
#include <array>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace erp {
// Exact weapon variant IDs must include upgrade/affinity data supplied by the bridge.
using ItemId = std::uint32_t;
constexpr std::size_t slot_count = 14; // R1..3, L1..3, head, chest, arms, legs, talisman1..4
using Loadout = std::array<std::optional<ItemId>, slot_count>;
struct InventoryItem { ItemId id; std::uint64_t handle; };
struct Change { std::size_t slot; std::optional<std::uint64_t> handle; };
struct Plan { std::vector<Change> changes; std::vector<std::size_t> missing; };
Plan plan(const Loadout&, const std::vector<InventoryItem>&);
class Store {
public:
    explicit Store(std::filesystem::path directory);
    void save(unsigned preset, const Loadout&);
    std::optional<Loadout> load(unsigned preset) const;
private:
    std::filesystem::path directory_;
    std::filesystem::path path(unsigned preset) const;
};
// The game bridge owns thread scheduling, inventory snapshots and safe equip calls.
class Game {
public:
    virtual ~Game() = default;
    virtual bool ready() = 0; // offline, correct build, player loaded, safe to equip
    virtual std::string character() = 0; // stable, filesystem-safe character identity
    virtual Loadout equipped() = 0;
    virtual std::vector<InventoryItem> inventory() = 0;
    virtual bool apply(const std::vector<Change>&) = 0;
};
struct Result { bool ok; std::string message; std::vector<std::size_t> missing; };
class Controller {
public:
    Controller(Game& game, std::filesystem::path root);
    Result save(unsigned preset);
    Result recall(unsigned preset);
private:
    Game& game_;
    std::filesystem::path root_;
    Store store();
};
}
