#pragma once
#include "PluginTransport.hpp"
#include "../Project/Models.hpp"

namespace jaras {
inline PluginTempoMap pluginTempoMap(const Song& song) {
    std::vector<PluginTempoMap::Point> points{{0, song.bpm, song.beatsPerBar, song.beatUnit}};
    auto markers = song.markers.value_or(std::vector<TimelineMarker>{});
    std::stable_sort(markers.begin(), markers.end(), [](const auto& a, const auto& b) {
        return a.position == b.position ? a.id < b.id : a.position < b.position;
    });
    for (const auto& marker : markers) if (marker.tempoBPM)
        points.push_back({marker.position, *marker.tempoBPM, marker.tempoBeats.value_or(4), marker.tempoUnit.value_or(4)});
    return PluginTempoMap(std::move(points));
}
}
