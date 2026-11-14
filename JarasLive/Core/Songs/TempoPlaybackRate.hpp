#pragma once
#include "Song.hpp"
#include <cmath>
namespace jaras::tempoPlayback {
inline bool follows(const Song& song,const TimelineMarker& marker) {
    const auto mode=marker.tempoTimebase.value_or("global");
    return mode=="relative" || (mode=="global" && song.timeSettings.value_or(ProjectTimeSettings{}).timebase==ProjectTimebase::relative);
}
inline double rate(const Song& song,const TimelineMarker& marker) {
    if(marker.tempoPlaybackRate)return *marker.tempoPlaybackRate;
    return marker.tempoBPM && follows(song,marker) ? *marker.tempoBPM/marker.tempoReferenceBPM.value_or(song.bpm) : 1.;
}
inline void edited(const Song& before,const TimelineMarker* previous,TimelineMarker& next) {
    if(!next.tempoBPM){next.tempoPlaybackRate.reset();return;}
    if(previous && previous->tempoBPM) {
        const double prior=rate(before,*previous);
        next.tempoPlaybackRate=follows(before,next)?prior*(*next.tempoBPM/ *previous->tempoBPM):prior;
    } else if(!next.tempoPlaybackRate) {
        const TimelineMarker* active=nullptr;
        if(before.markers)for(const auto& marker:*before.markers)
            if(marker.tempoBPM && marker.position<=next.position && (!active || marker.position>active->position || (marker.position==active->position && marker.id>active->id)))active=&marker;
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
