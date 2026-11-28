#pragma once
#include <array>

namespace jaras {
// Fit timed stages once per parameter change or audio block.
struct WaveLFO {
    bool enabled = false;
    double attackEnd = 0, holdEnd = 0, decayEnd = 0, releaseStart = 0, end = 0;
    double attackSlope = 0, decaySlope = 0, sustain = 1, releaseSlope = 0;

    static WaveLFO prepare(double duration, double attack, double hold, double decay, double level, double release) {
        const double total = attack + hold + decay + release;
        const double scale = total > duration && total > 0 ? duration / total : 1;
        attack *= scale;
        hold *= scale;
        decay *= scale;
        release *= scale;
        const double holdEnd = attack + hold;
        return {true, attack, holdEnd, holdEnd + decay, duration - release, duration,
                attack > 0 ? 1 / attack : 0, decay > 0 ? (level - 1) / decay : 0,
                level, release > 0 ? level / release : 0};
    }

    double gain(double local) const {
        if (!enabled) return 1;
        if (local < 0 || local >= end) return 0;
        if (local < attackEnd) return local * attackSlope;
        if (local < holdEnd) return 1;
        if (local < decayEnd) return 1 + (local - holdEnd) * decaySlope;
        if (local > releaseStart) return (end - local) * releaseSlope;
        return sustain;
    }
    struct Vertex { double time, gain; };
    std::array<Vertex,6> vertices() const {
        return {{{0, 0}, {attackEnd, 1}, {holdEnd, 1}, {decayEnd, sustain}, {releaseStart, sustain}, {end, 0}}};
    }
};
}
