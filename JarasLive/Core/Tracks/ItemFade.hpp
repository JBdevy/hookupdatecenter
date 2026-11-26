#pragma once
#include "Track.hpp"
#include <algorithm>
#include <cmath>

namespace jaras {
// Independent curvature and S controls. Zero curvature / S=1 preserves the
// original Mac smoothstep envelope. Coefficients are prepared off the sample loop.
struct FadeCurve {
    double bias = 1, s = 1;
    FadeCurve(double curvature = 0, double shape = 1)
        : bias(std::exp2(4 * std::clamp(curvature, -1., 1.))), s(std::clamp(shape, -1., 1.)) {}
    double value(double position) const noexcept {
        const auto t = std::clamp(position, 0., 1.);
        const auto shaped = t + s * (t * t * (3 - 2 * t) - t);
        return shaped / (bias + (1 - bias) * shaped);
    }
};
inline bool itemSupportsFades(const Track& track, const AudioClip& clip) {
    const bool projection = clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0;
    return clip.duration > 0 && (projection ||
        (fixedTrackName(track.role).empty() && (clip.midi || clip.audioFile || track.audioFile)));
}
inline bool itemShowsFadeHandles(const AudioClip& clip) {
    return clip.fadeControlsEnabled.value_or(false) || clip.fadeIn.value_or(0) > 0 || clip.fadeOut.value_or(0) > 0;
}
inline void setItemFadeControls(AudioClip& clip, bool enabled) {
    if (enabled) {
        if (clip.fadeControlsEnabled.value_or(false)) return;
        clip.fadeControlsEnabled = true;
        const auto initial = std::min(.05, clip.duration / 4);
        if (clip.fadeIn.value_or(0) <= 0) clip.fadeIn = initial;
        if (clip.fadeOut.value_or(0) <= 0) clip.fadeOut = initial;
    } else {
        clip.fadeControlsEnabled.reset();
        clip.fadeIn.reset();
        clip.fadeOut.reset();
    }
}
inline double itemFadeGain(const AudioClip &clip, double position) {
    const auto in = std::min(clip.duration, clip.fadeIn.value_or(0));
    const auto out = std::min(clip.duration, clip.fadeOut.value_or(0));
    return (in > 0 ? FadeCurve(clip.fadeInCurve.value_or(0), clip.fadeInSCurve.value_or(1)).value((position - clip.startTime) / in) : 1)
         * (out > 0 ? FadeCurve(clip.fadeOutCurve.value_or(0), clip.fadeOutSCurve.value_or(1)).value((clip.startTime + clip.duration - position) / out) : 1);
}
}
