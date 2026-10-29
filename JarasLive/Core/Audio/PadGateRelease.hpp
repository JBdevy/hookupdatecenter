#pragma once
#include <algorithm>
#include <cmath>

namespace jaras {
// Render-thread envelope: independent of UI timers and callback block size.
struct PadGateRelease {
    static constexpr double seconds = 0.010;
    unsigned remaining = 0, total = 0;
    bool started = false;

    void begin(double sampleRate) {
        if (started) return;
        started = true;
        remaining = total = std::max(1u, unsigned(std::lround(sampleRate * seconds)));
    }
    float next() {
        if (!started) return 1;
        if (!remaining) return 0;
        return float(remaining--) / float(total);
    }
    bool finished() const { return started && remaining == 0; }
};
}
