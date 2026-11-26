#pragma once
#include <algorithm>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace jaras::overlap {
struct Item { std::string id; double start, end; };
// Times are relative to the receiving clip, including when it plays as tempo fragments.
struct Ramp { double start, peak, end, inverse; };
using Envelopes = std::map<std::string, std::vector<Ramp>>;

inline Envelopes compile(std::vector<Item> items) {
    std::sort(items.begin(), items.end(), [](const Item &a, const Item &b) {
        if (a.start != b.start) return a.start < b.start;
        if (a.end != b.end) return a.end > b.end;
        return a.id < b.id;
    });
    Envelopes result;
    std::vector<const Item*> active;
    for (const auto &item : items) {
        active.erase(std::remove_if(active.begin(), active.end(), [&](const auto *p) { return p->end <= item.start; }), active.end());
        if (!active.empty()) {
            double underEnd = item.start;
            for (auto p : active) underEnd = std::max(underEnd, p->end);
            const double end = std::min(underEnd, item.end);
            // A contained clip must hand the mix back to the underlying material.
            const double peak = item.end < underEnd ? (item.start + end) * .5 : end;
            auto ramp = [&](const Item &owner, bool inverse) {
                result[owner.id].push_back({item.start-owner.start, peak-owner.start, end-owner.start, inverse ? 1.0 : 0.0});
            };
            ramp(item, false);
            for (auto p : active) ramp(*p, true);
        }
        active.push_back(&item);
    }
    return result;
}
inline double gain(const std::vector<Ramp>& ramps, double position) noexcept {
    double value = 1;
    for (const auto &r : ramps) {
        if (position < r.start || position >= r.end) continue;
        const double opacity = position < r.peak ? (position-r.start)/(r.peak-r.start) : (r.end-position)/(r.end-r.peak);
        value *= r.inverse ? 1-opacity : opacity;
    }
    return value;
}
}
