#pragma once
#include <cmath>
#include <optional>
namespace jaras {
class LiveTempoEditGate {
    std::optional<double> last;
public:
    void reset() { last.reset(); }
    bool accept(bool running, double now) {
        if (!std::isfinite(now)) return false;
        if (!running) { reset(); return true; }
        if (last && now >= *last && now - *last < .5 - 1e-9) return false;
        last = now;
        return true;
    }
};
}
