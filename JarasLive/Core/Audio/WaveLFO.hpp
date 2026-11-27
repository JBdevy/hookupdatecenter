#pragma once
#include <algorithm>

namespace jaras {
// The three timed segments share the available duration on very short items.
// Precompute slopes on a parameter edit, outside the per-sample loop.
struct WaveLFO {
    bool enabled = false;
    double attackEnd = 0, decayEnd = 0, releaseStart = 0, end = 0;
    double attackSlope = 0, decaySlope = 0, sustain = 1, releaseSlope = 0;

    static WaveLFO prepare(double duration, double attack, double decay, double level, double release) {
        const double total = attack + decay + release;
        const double scale = total > duration && total > 0 ? duration / total : 1;
        attack *= scale;
        decay *= scale;
        release *= scale;
        return {true, attack, attack + decay, duration - release, duration,
                attack > 0 ? 1 / attack : 0, decay > 0 ? (level - 1) / decay : 0,
                level, release > 0 ? level / release : 0};
    }

    double gain(double local) const {
        if (!enabled) return 1;
        if (local < 0 || local >= end) return 0;
        if (local < attackEnd) return local * attackSlope;
        if (local < decayEnd) return 1 + (local - attackEnd) * decaySlope;
        if (local > releaseStart) return (end - local) * releaseSlope;
        return sustain;
    }
};
}
