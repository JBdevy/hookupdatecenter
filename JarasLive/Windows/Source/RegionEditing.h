#pragma once
#include "Common.h"
namespace catlive::regionEditing {
inline void require(bool ok, const std::string &message) { if (!ok) throw std::runtime_error(message); }
inline bool hasChildren(const jaras::Song &song, const ID &id) {
    return std::any_of(song.parts.begin(), song.parts.end(), [&](const auto &part) { return part.parentRegionID == id; });
}
inline std::vector<jaras::Part> overlapping(const jaras::Song &song, const ID &id) {
    const auto seed = std::find_if(song.parts.begin(), song.parts.end(), [&](const auto &part) { return part.id == id && !part.parentRegionID; });
    if (seed == song.parts.end()) return {};
    std::set<ID> ids{id}; double start = seed->startTime, end = seed->endTime;
    bool changed;
    do {
        changed = false;
        for (const auto &part : song.parts)
            if (!part.parentRegionID && !ids.count(part.id) && part.startTime < end && part.endTime > start) {
                ids.insert(part.id); start = std::min(start, part.startTime); end = std::max(end, part.endTime); changed = true;
            }
    } while (changed);
    std::vector<jaras::Part> result;
    for (const auto &part : song.parts) if (ids.count(part.id)) result.push_back(part);
    std::stable_sort(result.begin(), result.end(), [](const auto &a, const auto &b) { return a.startTime == b.startTime ? a.endTime < b.endTime : a.startTime < b.startTime; });
    return result;
}
inline ID unify(jaras::Project &project, const ID &songID, const ID &id, String name) {
    auto at = std::find_if(project.songs.begin(), project.songs.end(), [&](const auto &song) { return song.id == songID; });
    require(at != project.songs.end(), "Unknown song"); auto &song = *at;
    const auto roots = overlapping(song, id);
    require(roots.size() > 1, "Select overlapping regions");
    std::set<ID> rootIDs, replaced, memberIDs;
    for (const auto &root : roots) rootIDs.insert(root.id);
    std::vector<jaras::Part> members;
    for (const auto &part : song.parts) if (part.parentRegionID && rootIDs.count(*part.parentRegionID)) {
        replaced.insert(*part.parentRegionID); members.push_back(part);
    }
    for (const auto &root : roots) if (!replaced.count(root.id)) members.push_back(root);
    std::stable_sort(members.begin(), members.end(), [](const auto &a, const auto &b) { return a.startTime == b.startTime ? a.endTime < b.endTime : a.startTime < b.startTime; });
    std::optional<jaras::Part> existing;
    for (const auto &root : roots) if (replaced.count(root.id) && (!existing || root.id == id)) existing = root;
    require(existing.has_value() || name.trim().isNotEmpty(), "Choose a name");
    jaras::Part group = existing.value_or(jaras::Part{});
    if (!existing) { group.id = uuid(); group.name = utf8(name.trim()); group.color = roots.front().color; }
    group.startTime = roots.front().startTime; group.endTime = roots.front().endTime;
    for (const auto &root : roots) { group.startTime = std::min(group.startTime, root.startTime); group.endTime = std::max(group.endTime, root.endTime); }
    for (const auto &part : members) { memberIDs.insert(part.id); group.startTime = std::min(group.startTime, part.startTime); group.endTime = std::max(group.endTime, part.endTime); }
    std::map<ID, jaras::TimelineMarker> original;
    if (!song.markers) song.markers.emplace();
    for (const auto &marker : *song.markers) if (marker.unifiedRegionID && rootIDs.count(*marker.unifiedRegionID)) {
        group.startTime = std::min(group.startTime, marker.position);
        if (replaced.count(*marker.unifiedRegionID) && marker.sourceRegionID)
            require(original.emplace(*marker.sourceRegionID, marker).second, "Duplicate unified song markers");
    }
    song.parts.erase(std::remove_if(song.parts.begin(), song.parts.end(), [&](const auto &part) { return replaced.count(part.id); }), song.parts.end());
    for (auto &part : song.parts) if (memberIDs.count(part.id)) part.parentRegionID = group.id;
    song.parts.push_back(group);
    for (auto &track : song.tracks) for (auto &clip : track.clips)
        if (clip.regionOwnerID && replaced.count(*clip.regionOwnerID)) clip.regionOwnerID = group.id;
    for (auto &marker : *song.markers)
        if (marker.regionOwnerID && replaced.count(*marker.regionOwnerID)) marker.regionOwnerID = group.id;
    song.markers->erase(std::remove_if(song.markers->begin(), song.markers->end(), [&](const auto &marker) { return marker.unifiedRegionID && replaced.count(*marker.unifiedRegionID); }), song.markers->end());
    for (const auto &part : members) {
        const auto saved = original.find(part.id);
        jaras::TimelineMarker marker; marker.id = uuid(); marker.name = saved == original.end() ? part.name : saved->second.name;
        marker.position = saved == original.end() ? part.startTime : saved->second.position;
        marker.color = saved == original.end() ? part.color.value_or(0x54ff93) : saved->second.color;
        marker.unifiedRegionID = group.id; marker.sourceRegionID = part.id;
        song.markers->push_back(marker);
    }
    if (project.regionSetlist) {
        auto &state = *project.regionSetlist;
        for (auto &playlist : state.playlists) if (playlist.songId == songID) {
            std::vector<ID> next; bool inserted = false;
            for (const auto &entry : playlist.regionIds) {
                if (!rootIDs.count(entry) && !memberIDs.count(entry)) next.push_back(entry);
                else if (!inserted) { next.push_back(group.id); inserted = true; }
            }
            playlist.regionIds = std::move(next);
        }
        if (state.blocks) for (auto &block : *state.blocks)
            if (block.beforeRegionId && (rootIDs.count(*block.beforeRegionId) || memberIDs.count(*block.beforeRegionId))) block.beforeRegionId = group.id;
    }
    return group.id;
}
inline void disunify(jaras::Project &project, const ID &songID, const ID &id) {
    auto at = std::find_if(project.songs.begin(), project.songs.end(), [&](const auto &song) { return song.id == songID; });
    require(at != project.songs.end(), "Unknown song"); auto &song = *at;
    std::vector<jaras::Part> members;
    for (auto &part : song.parts) if (part.parentRegionID == id) {
        members.push_back(part); part.parentRegionID.reset();
        if (song.markers) for (const auto &marker : *song.markers) if (marker.unifiedRegionID == id && marker.sourceRegionID == part.id) {
            part.startTime = marker.position; part.name = marker.name; part.color = marker.color; break;
        }
    }
    require(!members.empty(), "Unknown unified region");
    std::stable_sort(members.begin(), members.end(), [](const auto &a, const auto &b) { return a.startTime < b.startTime; });
    song.parts.erase(std::remove_if(song.parts.begin(), song.parts.end(), [&](const auto &part) { return part.id == id; }), song.parts.end());
    if (song.markers) song.markers->erase(std::remove_if(song.markers->begin(), song.markers->end(), [&](const auto &marker) { return marker.unifiedRegionID == id; }), song.markers->end());
    for (auto &track : song.tracks) for (auto &clip : track.clips) if (clip.regionOwnerID == id) clip.regionOwnerID = jaras::regionOwnerAt(song, clip.startTime);
    if (song.markers) for (auto &marker : *song.markers) if (marker.regionOwnerID == id) marker.regionOwnerID = jaras::regionOwnerAt(song, marker.position);
    if (project.regionSetlist) {
        auto &state = *project.regionSetlist;
        for (auto &playlist : state.playlists) {
            std::vector<ID> next;
            for (const auto &entry : playlist.regionIds)
                if (entry != id) next.push_back(entry); else for (const auto &part : members) next.push_back(part.id);
            playlist.regionIds = std::move(next);
        }
        if (state.blocks) for (auto &block : *state.blocks) if (block.beforeRegionId == id) block.beforeRegionId = members.front().id;
    }
}
// Timeline deletion unwraps a group; All Regions removes owned contents.
// Files remain on disk, and overlapping songs retain their own media.
inline void erase(jaras::Project &project, const ID &songID, const std::set<ID> &ids, bool withContents) {
            for(auto &song:project.songs)if(song.id==songID){
                auto removed=ids;
                if(!withContents){
                    for(const auto &id:ids)if(regionEditing::hasChildren(song,id)){regionEditing::disunify(project,songID,id);removed.erase(id);}
                }else{
                    bool changed;do{changed=false;for(const auto &part:song.parts)if(part.parentRegionID&&removed.count(*part.parentRegionID)&&removed.insert(part.id).second)changed=true;}while(changed);
                    const auto source=song;
                    for(auto &track:song.tracks)track.clips.erase(std::remove_if(track.clips.begin(),track.clips.end(),[&](const auto &clip){
                        auto owner=source.regionOwnershipInitialized?clip.regionOwnerID:jaras::regionOwnerAt(source,clip.startTime);
                        return owner&&removed.count(*owner);
                    }),track.clips.end());
                    if(song.markers)song.markers->erase(std::remove_if(song.markers->begin(),song.markers->end(),[&](const auto &m){
                        auto owner=source.regionOwnershipInitialized?m.regionOwnerID:m.sourceRegionID?m.sourceRegionID:jaras::regionOwnerAt(source,m.position);
                        if((owner&&removed.count(*owner))||(m.unifiedRegionID&&removed.count(*m.unifiedRegionID)))return true;
                        if(m.tempoBPM&&!m.regionOwnerID)for(const auto &part:source.parts)if(removed.count(part.id)&&m.position>=part.startTime&&m.position<part.endTime)return true;
                        return false;
                    }),song.markers->end());
                }
                song.parts.erase(std::remove_if(song.parts.begin(),song.parts.end(),[&](const auto &p){return removed.count(p.id);}),song.parts.end());
                if(song.markers){
                    song.markers->erase(std::remove_if(song.markers->begin(),song.markers->end(),[&](const auto &m){return m.unifiedRegionID&&removed.count(*m.unifiedRegionID);}),song.markers->end());
                    for(auto &m:*song.markers)if(m.regionOwnerID&&removed.count(*m.regionOwnerID))m.regionOwnerID.reset();
                }
                for(auto &track:song.tracks)for(auto &clip:track.clips)if(clip.regionOwnerID&&removed.count(*clip.regionOwnerID))clip.regionOwnerID.reset();
                if(project.regionSetlist){auto &state=*project.regionSetlist;
                    for(auto &playlist:state.playlists){
                        for(auto it=playlist.regionIds.begin();it!=playlist.regionIds.end();){
                            if(!removed.count(*it)){++it;continue;}
                            auto following=std::find_if(it+1,playlist.regionIds.end(),[&](const auto &id){return !removed.count(id);});
                            std::optional<ID> next=following==playlist.regionIds.end()?std::optional<ID>{}:std::optional<ID>{*following};
                            if(state.blocks)for(auto &block:*state.blocks)if(block.playlistId==playlist.id&&block.beforeRegionId==*it)block.beforeRegionId=next;
                            it=playlist.regionIds.erase(it);
                        }
                    }
                    if(state.blocks)for(auto &block:*state.blocks)if(block.beforeRegionId&&removed.count(*block.beforeRegionId))block.beforeRegionId.reset();
                    if(state.playedLiveRegionIDs)state.playedLiveRegionIDs->erase(std::remove_if(state.playedLiveRegionIDs->begin(),state.playedLiveRegionIDs->end(),[&](const auto &id){return removed.count(id);}),state.playedLiveRegionIDs->end());
                }
            }
}

}
