#pragma once
#include "Song.hpp"
#include <cmath>
#include <algorithm>
#include <limits>
namespace jaras::tempoPlayback {
// Region-owned tempo stops at the song boundary without a persisted reset marker.
inline double markerEnd(const Song& song,const TimelineMarker& marker) {
    const auto folder=[&](const auto& part){return std::any_of(song.parts.begin(),song.parts.end(),[&](const auto& child){return child.parentRegionID==part.id;});};
    const auto id=marker.regionOwnerID;
    const auto found=id?std::find_if(song.parts.begin(),song.parts.end(),[&](const auto& p){return p.id==*id;}):song.parts.end();
    const Part* owner=found==song.parts.end()?nullptr:&*found;
    if(!owner)return std::numeric_limits<double>::infinity();
    double end=owner->endTime;
    if(!folder(*owner))for(const auto& next:song.parts)
        if(!folder(next) && next.startTime>owner->startTime && (!owner->parentRegionID || next.parentRegionID==owner->parentRegionID))end=std::min(end,next.startTime);
    return end;
}
inline const TimelineMarker* active(const Song& song,double position) {
    const TimelineMarker* result=nullptr;
    if(song.markers)for(const auto& marker:*song.markers)
        if(marker.tempoBPM && marker.position<=position && position<markerEnd(song,marker) &&
           (!result || marker.position>result->position || (marker.position==result->position && marker.id>result->id)))result=&marker;
    return result;
}
inline bool follows(const Song& song,const TimelineMarker& marker) {
    const auto mode=marker.tempoTimebase.value_or("global");
    return mode=="relative" || (mode=="global" && song.timeSettings.value_or(ProjectTimeSettings{}).timebase==ProjectTimebase::relative);
}
inline const TimelineMarker* regionAnchor(const Song& song, const ID& owner) {
    if (song.markers) for (const auto& marker : *song.markers)
        if (marker.regionOwnerID == owner && marker.regionTempoAnchor.value_or(false) && marker.tempoBPM && marker.tempoPlaybackRate) return &marker;
    return nullptr;
}
inline double rate(const Song& song,const TimelineMarker& marker) {
    if (!marker.regionTempoAnchor.value_or(false) && marker.regionOwnerID)
        if (const auto* anchor = regionAnchor(song, *marker.regionOwnerID)) return *anchor->tempoPlaybackRate;
    if(marker.tempoPlaybackRate)return *marker.tempoPlaybackRate;
    return marker.tempoBPM && follows(song,marker) ? *marker.tempoBPM/marker.tempoReferenceBPM.value_or(song.bpm) : 1.;
}
inline void edited(const Song& before,const TimelineMarker* previous,TimelineMarker& next) {
    if(!next.tempoBPM){next.tempoPlaybackRate.reset();next.regionTempoAnchor.reset();return;}
    const auto owner = previous && previous->regionOwnerID ? previous->regionOwnerID : next.regionOwnerID;
    if (owner) if (const auto* anchor = regionAnchor(before, *owner)) {
        next.regionTempoAnchor = previous ? previous->regionTempoAnchor : std::nullopt;
        next.tempoPlaybackRate = anchor->tempoPlaybackRate;
        return;
    }
    if(previous && previous->tempoBPM) {
        const double prior=rate(before,*previous);
        next.tempoPlaybackRate=follows(before,next)?prior*(*next.tempoBPM/ *previous->tempoBPM):prior;
    } else if(!next.tempoPlaybackRate) {
        const auto* active=tempoPlayback::active(before,next.position);
        const double prior=active?rate(before,*active):1.;
        const double oldBPM=active?*active->tempoBPM:before.bpm;
        next.tempoPlaybackRate=follows(before,next)?prior*(*next.tempoBPM/oldBPM):prior;
    }
}
// Follow mode controls future edits; it never undoes audio already stretched.
inline void retainRates(Song& song) {
    if(song.markers)for(auto& marker:*song.markers)if(marker.tempoBPM)
        marker.tempoPlaybackRate=rate(song,marker);
}
}
