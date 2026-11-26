#pragma once
#include <algorithm>
#include <cmath>
#include <optional>
#include <string>
#include <vector>
namespace catlive {
// Same six-interval estimator as Application/Project/TimelineTempo.swift.
struct TapTempo {
    std::optional<double> last;
    std::vector<double> intervals;
    std::string source;
    std::optional<double> tap(double time, const std::string& origin = {}) {
        if (!std::isfinite(time)) return {};
        if (source != origin || !last || time - *last > 4) {
            source = origin;
            last = time; intervals.clear(); return {};
        }
        const auto interval = time - *last;
        if (interval < .08) return {};
        last = time; intervals.push_back(interval);
        if (intervals.size() > 6) intervals.erase(intervals.begin());
        double sum = 0; for (auto value : intervals) sum += value;
        return std::clamp(std::round(60 * intervals.size() / sum), 60., 300.);
    }
};
}
