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
inline void removeBlocks(jaras::RegionSetlist &state, const jaras::ID &songID,
                         const std::optional<jaras::ID> &playlistID, const std::set<jaras::ID> &targets) {
    if (!state.blocks) return;
    auto &blocks = *state.blocks;
    blocks.erase(std::remove_if(blocks.begin(), blocks.end(), [&](const auto &block) {
        return block.songId == songID && block.playlistId == playlistID && targets.count(block.id);
    }), blocks.end());
}
inline bool moveEntries(jaras::RegionSetlist &state, const jaras::ID &songID,
                        const jaras::ID &playlistID, const std::set<jaras::ID> &targets,
                        const std::optional<jaras::ID> &before) {
    auto playlist = std::find_if(state.playlists.begin(), state.playlists.end(), [&](const auto &list) {
        return list.id == playlistID && list.songId == songID;
    });
    if (playlist == state.playlists.end() || targets.empty()) return false;
    std::vector<jaras::ID> ordered;
    std::map<jaras::ID, jaras::SetlistBlock> blocks;
    if (state.blocks) for (const auto &block : *state.blocks)
        if (block.songId == songID && block.playlistId == playlistID) blocks.emplace(block.id, block);
    const auto appendBlocks = [&](const std::optional<jaras::ID> &anchor) {
        if (state.blocks) for (const auto &block : *state.blocks)
            if (blocks.count(block.id) && block.beforeRegionId == anchor) ordered.push_back(block.id);
    };
    for (const auto &id : playlist->regionIds) { appendBlocks(id); ordered.push_back(id); }
    appendBlocks(std::nullopt);
    if (before && std::find(ordered.begin(), ordered.end(), *before) == ordered.end()) return false;
    if (before && targets.count(*before)) return false;
    std::vector<jaras::ID> moving, remaining;
    for (const auto &id : ordered) (targets.count(id) ? moving : remaining).push_back(id);
    if (moving.empty()) return false;
    const auto position = before ? std::find(remaining.begin(), remaining.end(), *before) : remaining.end();
    remaining.insert(position, moving.begin(), moving.end());
    if (remaining == ordered) return false;
    std::vector<jaras::SetlistBlock> reorderedBlocks;
    playlist->regionIds.clear();
    for (size_t index = 0; index < remaining.size(); ++index) {
        const auto at = blocks.find(remaining[index]);
        if (at == blocks.end()) { playlist->regionIds.push_back(remaining[index]); continue; }
        auto block = at->second;
        block.beforeRegionId.reset();
        for (size_t next = index + 1; next < remaining.size(); ++next)
            if (!blocks.count(remaining[next])) { block.beforeRegionId = remaining[next]; break; }
        reorderedBlocks.push_back(std::move(block));
    }
    size_t index = 0;
    if (state.blocks) for (auto &block : *state.blocks)
        if (block.songId == songID && block.playlistId == playlistID) block = std::move(reorderedBlocks[index++]);
    return true;
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
