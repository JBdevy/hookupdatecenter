#pragma once
#include "MultiLoop.hpp"
#include <algorithm>
#include <cmath>

namespace jaras {
// Prepared on control, evaluated against the audio clock. No project values
// are changed by a loop, so bypass, Stop and leaving the loop restore them.
struct MultiLoopMixerEnvelope {
    bool active = false, released = false;
    double start = 0, end = 0, fadeSeconds = 1, releasePosition = 0;
    double amount(double position) const noexcept {
        if (!active || position >= end) return 0;
        const double value = released
            ? (end - position) / std::max(0.000001, end - releasePosition)
            : (position - start + fadeSeconds) / std::max(0.000001, fadeSeconds);
        return std::clamp(value, 0.0, 1.0);
    }
    bool gates(double position) const noexcept {
        return active && position >= start && position < end;
    }
};
struct MultiLoopMixerRule {
    double gain = 1;
    bool autoFader = false, mute = false, solo = false;
    double volume(double base, double amount) const noexcept {
        return autoFader ? base + (std::min(base, gain) - base) * amount : base;
    }
};
inline MultiLoopMixerEnvelope multiLoopMixerEnvelope(const std::optional<MultiLoopPlayback> &loop) {
    if (!loop) return {};
    return {true, loop->released, loop->start, loop->end, loop->config.fadeSeconds, loop->releasePosition};
}
inline bool sameMultiLoopMixer(const std::optional<MultiLoopPlayback> &a,
                              const std::optional<MultiLoopPlayback> &b) {
    if (!a || !b) return bool(a) == bool(b);
    if (a->id != b->id || a->start != b->start || a->end != b->end ||
        a->released != b->released || a->releasePosition != b->releasePosition ||
        a->config.fadeSeconds != b->config.fadeSeconds || a->config.tracks.size() != b->config.tracks.size()) return false;
    for (size_t i = 0; i < a->config.tracks.size(); ++i) {
        const auto &x = a->config.tracks[i], &y = b->config.tracks[i];
        if (x.id != y.id || x.gain != y.gain || x.autoFader != y.autoFader || x.mute != y.mute || x.solo != y.solo) return false;
    }
    return true;
}
}
