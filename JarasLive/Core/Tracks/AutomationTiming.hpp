#pragma once
// The native document layer already vendors this header-only JSON parser.
#include "../../WindowsNative/ThirdParty/nlohmann/json.hpp"
#include <algorithm>
#include <cmath>
#include <optional>
#include <string>

namespace jaras::automationTiming {
template<class Position>
void map(std::optional<std::string>& saved, Position position) {
    if (!saved) return;
    auto value = nlohmann::json::parse(*saved, nullptr, false);
    if (!value.is_object() || !value.contains("envelopes") || !value["envelopes"].is_array()) return;
    bool changed = false;
    for (auto& envelope : value["envelopes"]) {
        if (!envelope.is_object() || !envelope.contains("points") || !envelope["points"].is_array()) continue;
        auto& points = envelope["points"];
        if (!std::all_of(points.begin(), points.end(), [](const auto& point) {
            return point.is_object() && point.contains("time") && point["time"].is_number() &&
                std::isfinite(point["time"].template get<double>());
        })) continue;
        bool moved = false;
        for (auto& point : points) {
            const double before = point["time"].template get<double>();
            const double after = position(before);
            if (std::isfinite(after) && after >= 0 && after != before) { point["time"] = after; moved = true; }
        }
        if (!moved) continue;
        std::stable_sort(points.begin(), points.end(), [](const auto& a, const auto& b) {
            return a["time"].template get<double>() < b["time"].template get<double>();
        });
        double previous = -1;
        for (auto& point : points) {
            double time = point["time"].template get<double>();
            if (time <= previous) { time = std::nextafter(previous, INFINITY); point["time"] = time; }
            previous = time;
        }
        changed = true;
    }
    if (changed) saved = value.dump();
}
}
