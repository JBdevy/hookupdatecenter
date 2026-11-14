#pragma once
#include <algorithm>
#include <cmath>

namespace catlive {
// Same feedback budget as the Apple bridge. MIDI note input and heartbeat
// bypass this limiter. JUCE does not expose the Windows device transport, so
// use this conservative budget for every SMK connection on Windows.
class SMK37FeedbackBudget final {
  public:
    bool allow(int bytes, double now) {
        if (!std::isfinite(now) || bytes <= 0 || bytes > 96) return false;
        if (hasUpdated) {
            if (now < updated) return false;
            tokens = std::min(96., tokens + (now - updated) * 1200.);
        }
        updated = now; hasUpdated = true;
        if (hasSent && now - sent < .02 - 1e-9) return false;
        if (tokens + 1e-9 < bytes) return false;
        tokens -= bytes; sent = now; hasSent = true;
        return true;
    }
  private:
    double tokens = 96, updated = 0, sent = 0;
    bool hasUpdated = false, hasSent = false;
};
}
