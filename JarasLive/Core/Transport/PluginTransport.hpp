#pragma once
#include <algorithm>
#include <cmath>
#include <vector>

namespace jaras {
struct PluginTransport {
    double seconds = 0, quarterNotes = 0, tempo = 120;
    int numerator = 4, denominator = 4;
    bool playing = false;
    double barStartQuarterNotes = 0;
};

// Construct and replace on control. Queries on the render thread neither
// allocate nor lock. Quarter notes accumulate across tempo changes; a tempo
// marker starts a new measure, matching the timeline's bar numbering.
class PluginTempoMap {
public:
    struct Point { double seconds = 0, bpm = 120; int beats = 4, unit = 4; };
    PluginTempoMap() = default;
    explicit PluginTempoMap(std::vector<Point> points) {
        std::stable_sort(points.begin(), points.end(), [](const auto& a, const auto& b) { return a.seconds < b.seconds; });
        for (const auto& p : points) {
            if (!std::isfinite(p.seconds) || p.seconds < 0 || !std::isfinite(p.bpm) || p.bpm <= 0 || p.beats <= 0 || p.unit <= 0) continue;
            if (sections.empty() && p.seconds > 0) sections.push_back({{}, 0});
            if (!sections.empty() && sections.back().point.seconds == p.seconds) sections.pop_back();
            const double quarter = sections.empty() ? 0 : sections.back().quarter +
                (p.seconds - sections.back().point.seconds) * sections.back().point.bpm / 60.;
            sections.push_back({p, quarter});
        }
    }
    PluginTransport at(double seconds, bool playing) const noexcept {
        const Section fallback{{}, 0};
        auto found = std::upper_bound(sections.begin(), sections.end(), seconds,
            [](double time, const Section& s) { return time < s.point.seconds; });
        const auto& s = found == sections.begin() ? (sections.empty() ? fallback : sections.front()) : *--found;
        const double offset = (seconds - s.point.seconds) * s.point.bpm / 60.;
        const double bar = s.point.beats * 4. / s.point.unit;
        return {seconds, s.quarter + offset, s.point.bpm, s.point.beats, s.point.unit, playing,
                s.quarter + std::floor(offset / bar + 1e-10) * bar};
    }
    void swap(PluginTempoMap& other) noexcept { sections.swap(other.sections); }
private:
    struct Section { Point point; double quarter; };
    std::vector<Section> sections;
};
}
