#pragma once
#include "../../Core/Project/Models.hpp"
#include <algorithm>
#include <map>
#include <set>

namespace catlive::playlistOccurrences {
inline std::optional<jaras::ID> queuedVisibleEntry(const jaras::Song* song,
    const std::optional<jaras::ID>& region, const std::optional<jaras::ID>& occurrence,
    const std::set<jaras::ID>& expanded) {
    if (song && region) for (const auto& part : song->parts) if (part.id == *region && part.parentRegionID) {
        const auto& parent = *part.parentRegionID;
        if (expanded.count(parent) && (!occurrence || occurrence == parent || occurrence == region)) return region;
        return occurrence ? occurrence : part.parentRegionID;
    }
    return occurrence ? occurrence : region;
}
inline bool duplicate(jaras::RegionPlaylist &playlist, const jaras::ID &entry, jaras::ID copy) {
    const auto at = std::find(playlist.regionIds.begin(), playlist.regionIds.end(), entry);
    if (at == playlist.regionIds.end() || copy.empty() || playlist.containsEntry(copy)) return false;
    const auto source = playlist.resolvedRegionId(entry);
    playlist.regionIds.insert(at + 1, copy);
    if (!playlist.duplicates) playlist.duplicates.emplace();
    playlist.duplicates->push_back({std::move(copy), source});
    return true;
}
inline void prune(jaras::RegionPlaylist &playlist) {
    if (!playlist.duplicates) return;
    auto &copies = *playlist.duplicates;
    copies.erase(std::remove_if(copies.begin(), copies.end(), [&](const auto &entry) {
        return !playlist.containsEntry(entry.id);
    }), copies.end());
    if (copies.empty()) playlist.duplicates.reset();
}
inline void remove(jaras::RegionSetlist &state, const jaras::ID &playlistID,
                   const std::set<jaras::ID> &targets) {
    for (auto &playlist : state.playlists) if (playlist.id == playlistID) {
        if (state.blocks) for (auto &block : *state.blocks)
            if (block.playlistId == playlistID && block.beforeRegionId && targets.count(*block.beforeRegionId)) {
                auto next = std::find(playlist.regionIds.begin(), playlist.regionIds.end(), *block.beforeRegionId);
                while (next != playlist.regionIds.end() && targets.count(*next)) ++next;
                block.beforeRegionId = next == playlist.regionIds.end() ? std::optional<jaras::ID>{} : *next;
            }
        playlist.regionIds.erase(std::remove_if(playlist.regionIds.begin(), playlist.regionIds.end(),
            [&](const auto &entry) { return targets.count(entry); }), playlist.regionIds.end());
        prune(playlist);
    }
}
template<class NewID>
std::map<jaras::ID, jaras::ID> reidentifyCopies(jaras::RegionPlaylist &playlist, NewID newID) {
    std::map<jaras::ID, jaras::ID> remapped;
    if (playlist.duplicates) for (auto &entry : *playlist.duplicates) {
        const auto old = entry.id; entry.id = newID(); remapped.emplace(old, entry.id);
    }
    for (auto &entry : playlist.regionIds) if (auto at = remapped.find(entry); at != remapped.end()) entry = at->second;
    return remapped;
}
} // namespace catlive::playlistOccurrences
