#pragma once
#include "PartsPresentation.h"
namespace catlive {
inline bool clearFinishedSetlistSelection(const jaras::Project &project, const std::optional<ID> &focused,
                                         const jaras::TransportState &before, const jaras::TransportState &after) {
    if(!focused || !before.playing || after.paused)return false;
    const jaras::Song *song=nullptr;
    for(const auto &candidate:project.songs)if(candidate.id==before.songId)song=&candidate;
    if(!song)return false;
    ID source=*focused;
    if(project.regionSetlist)for(const auto &list:project.regionSetlist->playlists)
        if(list.id==project.regionSetlist->selectedId)source=list.resolvedRegionId(source);
    const auto matches=[&](const jaras::TransportState &state) {
        if(state.songId!=song->id)return false;
        const auto *leaf=partsPresentation::region(*song,state);
        if(!leaf)return false;
        const auto root=leaf->parentRegionID.value_or(leaf->id);
        if(source==root)return state.playlistEntryId ? *focused==*state.playlistEntryId : *focused==source;
        return source==leaf->id;
    };
    return matches(before) && (!after.playing || !matches(after));
}
}
