#pragma once
#include "Models.hpp"
#include "../Tracks/AutomationTiming.hpp"
#include <map>
#include <set>

namespace jaras {
inline bool ordinaryRegion(const Song& song, const Part& part) {
    return !part.parentRegionID && std::none_of(song.parts.begin(), song.parts.end(),
        [&](const auto& child){return child.parentRegionID == part.id;});
}
inline std::optional<double> regionEndAtLongestItem(const Song& song, const ID& id) {
    const auto region = std::find_if(song.parts.begin(), song.parts.end(), [&](const auto& p){return p.id == id;});
    if(region == song.parts.end() || !ordinaryRegion(song,*region)) return {};
    std::optional<double> end;
    for(const auto& track:song.tracks) for(const auto& clip:track.clips) {
        // Generated timecode/click lengths derive from region bounds themselves.
        if((track.role.id == "timecode" && !track.importedTimecodeItems) ||
           (track.role.id == "generatedClick" && !clip.audioFile)) continue;
        if(regionMovementOwner(song,clip.startTime,clip.startTime+clip.duration,clip.regionOwnerID) == id)
            end = std::max(end.value_or(region->startTime),clip.startTime+clip.duration);
    }
    return end && *end > region->startTime ? end : std::nullopt;
}
/// Freeze every displacement before editing, so crossing items move only once.
/// Each selected ordinary root inserts one gap after itself; later roots also
/// move when they were not selected, including entire unified families.
struct RegionSpacingPlan {
    std::map<ID,double> offsets;
    std::vector<double> cuts;
    explicit RegionSpacingPlan(const Song& song,const std::set<ID>& selected,double seconds=30): gap(seconds) {
        if(!std::isfinite(seconds) || seconds <= 0) return;
        std::vector<const Part*> roots;
        for(const auto& part:song.parts) if(!part.parentRegionID) roots.push_back(&part);
        std::sort(roots.begin(),roots.end(),[](auto a,auto b){return a->startTime == b->startTime ? a->id < b->id : a->startTime < b->startTime;});
        double offset=0;
        for(size_t i=0;i<roots.size();++i) {
            offsets[roots[i]->id]=offset;
            if(i+1<roots.size() && selected.count(roots[i]->id) && ordinaryRegion(song,*roots[i])) {
                cuts.push_back(roots[i]->endTime);offset+=gap;
            }
        }
    }
    double displacement(const Song& song,double time,std::optional<ID> owner={}) const {
        if(owner) for(const auto& root:offsets) if(regionOwns(song,root.first,owner)) return root.second;
        return gap*std::count_if(cuts.begin(),cuts.end(),[&](double cut){return time>=cut;});
    }
    double position(const Song& song,double time) const {
        return time+displacement(song,time,regionMovementOwner(song,time));
    }
    void apply(Song& song) const {
        if(cuts.empty()) return;
        const Song original=song;
        for(auto& track:song.tracks) {
            automationTiming::map(track.automationJSON,[&](double t){return position(original,t);});
            for(auto& pc:track.programChanges) pc.position=position(original,pc.position);
            std::stable_sort(track.programChanges.begin(),track.programChanges.end(),[](const auto& a,const auto& b){return a.position<b.position;});
            for(auto& clip:track.clips) {
                const auto owner=regionMovementOwner(original,clip.startTime,clip.startTime+clip.duration,clip.regionOwnerID);
                const auto offset=displacement(original,clip.startTime,owner);
                clip.startTime+=offset;
                if(offset!=0 && owner && !regionOwns(original,*owner,clip.regionOwnerID)) clip.regionOwnerID=owner;
            }
        }
        if(song.markers) for(auto& marker:*song.markers) {
            auto owner=marker.unifiedRegionID ? marker.unifiedRegionID : regionMovementOwner(original,marker.position,{},marker.regionOwnerID ? marker.regionOwnerID : marker.sourceRegionID);
            const auto offset=displacement(original,marker.position,owner);
            marker.position+=offset;
            if(offset!=0 && owner && !regionOwns(original,*owner,marker.regionOwnerID)) marker.regionOwnerID=owner;
        }
        for(auto& part:song.parts) {
            auto found=offsets.find(part.parentRegionID.value_or(part.id));
            if(found!=offsets.end()) {part.startTime+=found->second;part.endTime+=found->second;}
        }
        song.duration=position(original,original.duration);
        for(const auto& track:song.tracks) for(const auto& clip:track.clips) song.duration=std::max(song.duration,clip.startTime+clip.duration);
        for(const auto& part:song.parts) song.duration=std::max(song.duration,part.endTime);
    }
private:
    double gap=30;
};
}
