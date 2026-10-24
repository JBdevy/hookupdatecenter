#pragma once
#include "Session.h"
namespace catlive {
namespace partsPresentation {
inline const jaras::Part *region(const jaras::Song &song, const jaras::TransportState &state) {
    if (state.ignoreNextEnd && state.ignoreNextRegionId)
        for (const auto &part : song.parts)
            if (part.id == *state.ignoreNextRegionId && state.position >= part.startTime &&
                state.position < *state.ignoreNextEnd) return &part;
    const jaras::Part *result = nullptr;
    for (const auto &part : song.parts)
        if (state.position >= part.startTime && state.position < part.endTime &&
            (!result || (part.parentRegionID && !result->parentRegionID) ||
             (part.parentRegionID.has_value() == result->parentRegionID.has_value() &&
              part.endTime - part.startTime < result->endTime - result->startTime))) result = &part;
    return result;
}
inline double end(const jaras::Part &part, const jaras::TransportState &state) {
    return state.ignoreNextRegionId == part.id && state.ignoreNextEnd
        ? *state.ignoreNextEnd : part.endTime;
}
inline std::optional<double> trigger(const jaras::Song &song, const jaras::Part &part,
                                    const jaras::TransportState &state) {
    if (!state.playing) return {};
    // A boundary already rendered when the user armed the jump cannot become
    // its countdown target merely because the audible cursor trails the core.
    const double position = state.queuedSectionMarkerId
        ? std::max(state.position, state.sectionQueueStartedAt) : state.position;
    double next = end(part, state);
    if (next <= position + 1e-9) return {};
    if (song.markers) for (const auto &marker : *song.markers) {
        if (!marker.section.value_or(false) || marker.tempoBPM) continue;
        if (state.ignoreNextAfter && marker.position >= *state.ignoreNextAfter && marker.regionOwnerID != part.id) continue;
        if (marker.position > position + 1e-9 && marker.position <= part.endTime && marker.position < next)
            next = marker.position;
    }
    return next;
}
} // namespace partsPresentation
}
