#pragma once
#include "Common.h"
#include "ClipTempo.h"
namespace catlive::tempoEditing {
inline const jaras::TimelineMarker *active(const jaras::Song &song, double position) {
    const jaras::TimelineMarker *result = nullptr;
    if (song.markers) for (const auto &marker : *song.markers)
        if (marker.tempoBPM && marker.position <= position && (!result || marker.position > result->position ||
            (marker.position == result->position && marker.id > result->id))) result = &marker;
    return result;
}
inline const jaras::Part *region(const jaras::Song &song, const jaras::TransportState &state) {
    if (!state.playing) {
        for (const auto &part : song.parts) if (state.regionId == part.id) return &part;
        return nullptr;
    }
    const jaras::Part *result = nullptr;
    for (const auto &part : song.parts) if (part.startTime <= state.position && state.position < part.endTime) {
        if (!result || (bool(part.parentRegionID) != bool(result->parentRegionID) ? bool(part.parentRegionID)
            : part.startTime != result->startTime ? part.startTime > result->startTime : part.endTime < result->endTime)) result = &part;
    }
    return result;
}
inline double position(const jaras::Song &song, const jaras::TransportState &state) {
    const double at = state.playing ? state.position : state.editPosition;
    const auto *part = region(song, state);
    return part && (at < part->startTime || at >= part->endTime) ? part->startTime : at;
}
inline double bpm(const jaras::Song &song, double at) {
    const auto *marker = active(song, at);
    return marker ? *marker->tempoBPM : song.bpm;
}
inline bool needsRender(const jaras::Song &song, const jaras::Part *part = nullptr) {
    for (const auto &track : song.tracks) for (const auto &clip : track.clips) {
        if (!clip.audioFile && !clip.midi && !track.audioFile) continue;
        if (part) {
            if (const auto *owner = jaras::TempoEditMap::tempoOwner(song, clip)) {
                if (owner->id != part->id && owner->parentRegionID != part->id) continue;
            } else if (clip.startTime >= part->endTime || clip.startTime + clip.duration <= part->startTime) continue;
        }
        for (const auto &span : ClipTempo(clip, &song).spans)
            if (std::abs(span.rate - 1.0) > .0000005) return true;
    }
    return false;
}
inline jaras::TimelineMarker boundary(const jaras::Song &song, double at) {
    jaras::TimelineMarker marker;
    marker.id = uuid(); marker.name = "TEMPO"; marker.color = 0x999999; marker.position = at;
    const auto *previous = active(song, at);
    marker.tempoBPM = previous ? *previous->tempoBPM : song.bpm;
    marker.tempoBeats = previous ? previous->tempoBeats.value_or(song.beatsPerBar) : song.beatsPerBar;
    marker.tempoUnit = previous ? previous->tempoUnit.value_or(song.beatUnit) : song.beatUnit;
    marker.tempoTimebase = previous ? previous->tempoTimebase : std::optional<std::string>("global");
    marker.tempoReferenceBPM = previous ? previous->tempoReferenceBPM : std::nullopt;
    return marker;
}
inline std::vector<jaras::TimelineMarker> regionChange(const jaras::Song &song, const jaras::Part &part, double delta) {
    std::vector<jaras::TimelineMarker> targets;
    const double end = jaras::TempoEditMap::tempoEditEnd(song, part);
    bool hasStart = false, hasEnd = false;
    if (song.markers) for (const auto &marker : *song.markers) if (marker.tempoBPM) {
        if (marker.position >= part.startTime && marker.position < end) {
            targets.push_back(marker);
            hasStart |= std::abs(marker.position - part.startTime) < .000001;
        }
        hasEnd |= std::abs(marker.position - end) < .000001;
    }
    if (!hasStart) targets.push_back(boundary(song, part.startTime));
    double low = 300, high = 60;
    for (const auto &marker : targets) { low = std::min(low, *marker.tempoBPM); high = std::max(high, *marker.tempoBPM); }
    delta = jlimit(60 - low, 300 - high, delta);
    if (std::abs(delta) < .0000001) return {};
    for (auto &marker : targets) {
        *marker.tempoBPM += delta;
        marker.tempoBeats = marker.tempoBeats.value_or(song.beatsPerBar);
        marker.tempoUnit = marker.tempoUnit.value_or(song.beatUnit);
    }
    if (!hasEnd) targets.push_back(boundary(song, end));
    bool atZero = false;
    if (song.markers) for (const auto &marker : *song.markers) atZero |= marker.tempoBPM && marker.position == 0;
    for (const auto &marker : targets) atZero |= marker.position == 0;
    if (!atZero) {
        auto initial = boundary(song, 0); initial.tempoBPM = 120; initial.tempoBeats = 4;
        initial.tempoUnit = 4; initial.tempoReferenceBPM = 120; initial.tempoTimebase = "global";
        targets.push_back(initial);
    }
    return targets;
}
}
