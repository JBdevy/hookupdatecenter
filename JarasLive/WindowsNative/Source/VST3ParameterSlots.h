#pragma once
#include <algorithm>
#include <cstdint>
#include <utility>
#include <vector>

namespace catlive::native::vst3 {
// Prepared before processing starts. Controller/automation lookups read only
// immutable IDs and parameter indices; queue generations belong to audio.
// One queue per ID per block, with no allocation or linear search on audio.
class ParameterSlots final {
public:
    void prepare(std::vector<std::pair<std::uint32_t, int>> identifiers) {
        std::sort(identifiers.begin(), identifiers.end(), [](const auto& a, const auto& b) {
            return a.first < b.first || (a.first == b.first &&
                static_cast<unsigned>(a.second) < static_cast<unsigned>(b.second));
        });
        entries.clear(); entries.reserve(identifiers.size());
        for (const auto& identifier : identifiers)
            if (entries.empty() || entries.back().id != identifier.first)
                entries.push_back({identifier.first, identifier.second, -1, 0});
        generation = 1; used = 0;
    }
    int parameterIndex(std::uint32_t id) const noexcept {
        const auto found = std::lower_bound(entries.begin(), entries.end(), id,
            [](const Entry& entry, std::uint32_t key) { return entry.id < key; });
        return found == entries.end() || found->id != id ? -1 : found->parameter;
    }
    void beginBlock() noexcept {
        used = 0;
        if (++generation == 0) {
            // Only reachable after 2^64 blocks; retain correctness on wrap.
            for (auto& entry : entries) entry.generation = 0;
            generation = 1;
        }
    }
    bool queue(std::uint32_t id, int& index, bool& inserted) noexcept {
        const auto found = std::lower_bound(entries.begin(), entries.end(), id,
            [](const Entry& entry, std::uint32_t key) { return entry.id < key; });
        index = -1; inserted = false;
        if (found == entries.end() || found->id != id) return false;
        if (found->generation != generation) {
            found->generation = generation;
            found->queue = used++;
            inserted = true;
        }
        index = found->queue;
        return true;
    }
    int capacity() const noexcept { return static_cast<int>(entries.size()); }
    int count() const noexcept { return used; }
private:
    struct Entry { std::uint32_t id; int parameter, queue; std::uint64_t generation; };
    std::vector<Entry> entries;
    std::uint64_t generation = 1;
    int used = 0;
};
}
