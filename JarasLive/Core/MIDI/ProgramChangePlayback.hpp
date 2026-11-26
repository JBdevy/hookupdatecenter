#pragma once
#include "../Tracks/Track.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
namespace jaras {
// Shared by the Windows MIDI worker and CoreMIDI. Each playback head has its
// own cursor; transport jumps send only a cue at the destination, never skipped cues.
class ProgramChangeCursor {
    double previous=0;
    bool wasRunning=false;
public:
    void stop() { wasRunning=false; }
    template<class Send> void advance(const std::vector<ProgramChangeMarker>& markers,
                                     double at,bool running,bool jumped,Send&& send) {
        if(!running || !std::isfinite(at)) {stop();return;}
        const bool restart=!wasRunning || jumped || at<previous-.002;
        double from=restart?at-.000001:previous;
        wasRunning=true;
        if(!restart && at<previous)return;
        previous=at;
        for(const auto& marker:markers)
            if(marker.position>from && marker.position<=at+.00000001)send(marker);
    }
};
}
