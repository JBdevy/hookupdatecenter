#pragma once
#include "Track.hpp"
#include <algorithm>
#include <unordered_map>
#include <unordered_set>

namespace jaras {
// Allocate display names only when creating items. Existing names, including
// duplicates in older documents, are reserved without modifying the document.
class GridItemNames {
public:
    GridItemNames() = default;
    void reserve(const std::string& name) { used.insert(name); }

    explicit GridItemNames(const std::vector<Track>& tracks) {
        for (const auto& track : tracks) for (const auto& clip : track.clips) used.insert(clip.name);
    }

    void assign(std::string& name) {
        if (used.insert(name).second) return;
        const auto dot = name.find_last_of('.');
        std::string stem = name, ext;
        if (dot != std::string::npos && dot > 0 && dot + 1 < name.size() && name.size() - dot <= 6 &&
            std::all_of(name.begin() + dot + 1, name.end(), [](char c) {
                return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
            })) {
            stem = name.substr(0, dot); ext = name.substr(dot);
        }
        const auto space = stem.find_last_of(' ');
        if (space != std::string::npos && space > 0 && stem.size() - space > 3 &&
            std::all_of(stem.begin() + space + 1, stem.end(), [](char c) { return c >= '0' && c <= '9'; }))
            stem.resize(space);
        auto& next = nextSuffix[stem + ext];
        do {
            auto digits = std::to_string(++next);
            if (digits.size() < 3) digits.insert(0, 3 - digits.size(), '0');
            name = stem + " " + digits + ext;
        } while (!used.insert(name).second);
    }
private:
    std::unordered_set<std::string> used;
    std::unordered_map<std::string, size_t> nextSuffix;
};
}
