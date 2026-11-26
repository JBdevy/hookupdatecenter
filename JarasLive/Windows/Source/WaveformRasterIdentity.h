#pragma once
#include "WaveformRenderer.h"
#include <cstdint>
#include <tuple>

namespace catlive {
// A bitmap belongs to the source and its drawing parameters, rather than a
// track/item UUID. Identical copies can share pixels without sharing edits.
struct WaveformRasterIdentity {
    std::uintptr_t source = 0;
    String version;
    std::vector<double> drawing;
    bool operator<(const WaveformRasterIdentity &other) const {
        return std::tie(source,version,drawing)<std::tie(other.source,other.version,other.drawing);
    }
    bool operator==(const WaveformRasterIdentity &other) const {
        return std::tie(source,version,drawing)==std::tie(other.source,other.version,other.drawing);
    }
    static std::optional<WaveformRasterIdentity> make(const WaveformCache::Data &data,
        const jaras::AudioClip &clip,const ClipTempo &timing,double zoom,float physical,
        float width,float height,float cropLeft,float cropWidth,Colour ink) {
        WaveformRasterIdentity key;
        key.source=reinterpret_cast<std::uintptr_t>(&data);key.version=data.version;
        key.drawing={zoom,physical,width,height,cropLeft,cropWidth,double(ink.getARGB()),
            clip.duration,WaveformRenderer::gain(clip),clip.pan.value_or(0),double(clip.channelMode.value_or(0)),
            clip.loopLength.value_or(0),clip.loopStart.value_or(0),
            clip.fadeIn.value_or(0),clip.fadeOut.value_or(0),
            clip.fadeInCurve.value_or(0),clip.fadeOutCurve.value_or(0),
            clip.fadeInSCurve.value_or(1),clip.fadeOutSCurve.value_or(1)};
        // Tempo changes are relative to the item. Its screen position/name/ID
        // does not affect the waveform, but every source-time span does.
        for(const auto &span:timing.spans) {
            key.drawing.push_back(span.start-clip.startTime);
            key.drawing.push_back(span.end-clip.startTime);
            key.drawing.push_back(span.source);
            key.drawing.push_back(span.rate);
        }
        if(!std::all_of(key.drawing.begin(),key.drawing.end(),[](double value){return std::isfinite(value);}))return {};
        return key;
    }
};
}
