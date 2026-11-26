#pragma once
#include "Track.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>
namespace jaras {
inline AudioClip resizedItemSource(AudioClip clip, double start, double end, std::optional<double> sourceDuration = {}) {
    if (!std::isfinite(start) || !std::isfinite(end) || start < 0 || end - start < .01)
        return clip;
    if(!clip.loopLength && sourceDuration && std::isfinite(*sourceDuration) && *sourceDuration>0) {
        clip.loopStart=0;clip.loopLength=*sourceDuration;
    }
    if(clip.audioFile && !clip.loopLength) {
        const double actualStart=std::max(start,clip.startTime-clip.sourceOffset/clip.playbackRate);
        if(end-actualStart<.01)return clip;
        clip.sourceOffset=std::max(0.,clip.sourceOffset+(actualStart-clip.startTime)*clip.playbackRate);
        clip.startTime=actualStart;clip.duration=end-actualStart;
        return clip;
    }
    const double loopStart = clip.loopStart.value_or(clip.sourceOffset);
    const double loopLength = clip.loopLength.value_or(clip.duration * clip.playbackRate);
    if (!std::isfinite(loopLength) || loopLength <= 0)
        throw std::runtime_error("Duração da fonte inválida.");
    const double offset = clip.sourceOffset - loopStart +
                          (start - clip.startTime) * clip.playbackRate;
    clip.loopStart = loopStart;
    clip.loopLength = loopLength;
    clip.sourceOffset =
        loopStart +
        std::fmod(std::fmod(offset, loopLength) + loopLength, loopLength);

    clip.startTime = start;
    clip.duration = end - start;
    return clip;
}
}
