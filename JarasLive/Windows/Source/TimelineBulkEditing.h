#pragma once
#include "RegionEditing.h"
namespace catlive::timelineBulk {
enum class Kind { tempo, regions, markers };
inline bool matches(const jaras::TimelineMarker &marker, Kind kind) {
    if(marker.unifiedRegionID || marker.sourceRegionID) return kind==Kind::regions;
    return kind==Kind::tempo ? marker.tempoBPM.has_value() : kind==Kind::markers && !marker.tempoBPM;
}
inline void erase(jaras::Project &project, const ID &songID, Kind kind) {
    if(kind==Kind::regions) {
        std::set<ID> regions;
        for(const auto &song:project.songs)if(song.id==songID)for(const auto &part:song.parts)regions.insert(part.id);
        regionEditing::erase(project,songID,regions,false);
    }
    for(auto &song:project.songs)if(song.id==songID && song.markers) {
        std::set<ID> removed;
        for(const auto &marker:*song.markers)if(matches(marker,kind))removed.insert(marker.id);
        song.markers->erase(std::remove_if(song.markers->begin(),song.markers->end(),[&](const auto &m){return removed.count(m.id);}),song.markers->end());
        for(auto &part:song.parts)part.multiLoops.erase(std::remove_if(part.multiLoops.begin(),part.multiLoops.end(),[&](const auto &loop){return removed.count(loop.marker1)||removed.count(loop.marker2);}),part.multiLoops.end());
    }
}
}
