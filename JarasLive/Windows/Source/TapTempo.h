#pragma once
#include "Common.h"
namespace catlive {
// Same six-interval estimator as Application/Project/TimelineTempo.swift.
struct TapTempo {
    std::optional<double> last;
    std::vector<double> intervals;
    std::optional<double> tap(double time) {
        if (!std::isfinite(time)) return {};
        if (!last || time <= *last || time - *last > 4) {
            last = time; intervals.clear(); return {};
        }
        const auto interval = time - *last;
        if (interval < .08) return {};
        last = time; intervals.push_back(interval);
        if (intervals.size() > 6) intervals.erase(intervals.begin());
        double sum = 0; for (auto value : intervals) sum += value;
        return jlimit(60., 300., std::round(60 * intervals.size() / sum));
    }
};
}
