#pragma once
#include "Common.h"
#include "ClipTempo.h"
namespace catlive::tempoEditing {
inline const jaras::TimelineMarker *active(const jaras::Song &song, double position) {
    return jaras::tempoPlayback::active(song, position);
}
inline const jaras::Part *region(const jaras::Song &song, const jaras::TransportState &state) {
    if (!state.playing) {
        for (const auto &part : song.parts) if (state.regionId == part.id) {
            const jaras::Part *child = nullptr, *first = nullptr;
            for (const auto &candidate : song.parts) if (candidate.parentRegionID == part.id) {
                if (!first || candidate.startTime < first->startTime) first = &candidate;
                if (candidate.startTime <= state.editPosition && state.editPosition < candidate.endTime &&
                    (!child || candidate.startTime > child->startTime)) child = &candidate;
            }
            return child ? child : first ? first : &part;
        }
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
inline double referencePosition(const jaras::Song& song,const jaras::TransportState& state) {
    const auto* part=region(song,state);
    return part?part->startTime:position(song,state);
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
    marker.tempoPlaybackRate = previous ? jaras::tempoPlayback::rate(song,*previous) : 1.;
    return marker;
}
inline std::vector<jaras::TimelineMarker> regionChange(const jaras::Song &song, const jaras::Part &part, double delta) {
    std::vector<jaras::TimelineMarker> targets;
    const double end = jaras::TempoEditMap::tempoEditEnd(song, part);
    bool hasStart = false;
    if (song.markers) for (const auto &marker : *song.markers) if (marker.tempoBPM) {
        if (marker.position >= part.startTime && marker.position < end) {
            targets.push_back(marker);
            hasStart |= std::abs(marker.position - part.startTime) < .000001;
        }
    }
    if (!hasStart) targets.push_back(boundary(song, part.startTime));
    double low = 300, high = 60;
    for (const auto &marker : targets) { low = std::min(low, *marker.tempoBPM); high = std::max(high, *marker.tempoBPM); }
    if (!std::isfinite(delta)) return {};
    delta = jlimit(60-low, 300-high, delta);
    if (std::abs(delta) < .000000001) return {};
    std::sort(targets.begin(), targets.end(), [](const auto& a, const auto& b) {
        return a.position == b.position ? a.id > b.id : a.position < b.position;
    });
    std::unordered_map<ID, std::optional<double>> regionRates;
    for (auto &marker : targets) {
        const auto previous = marker;
        if (!marker.regionOwnerID) marker.regionOwnerID = jaras::regionOwnerAt(song, marker.position).value_or(part.id);
        *marker.tempoBPM += delta;
        marker.tempoBeats = marker.tempoBeats.value_or(song.beatsPerBar);
        marker.tempoUnit = marker.tempoUnit.value_or(song.beatUnit);
        auto [entry, first] = regionRates.try_emplace(*marker.regionOwnerID);
        if (first) {
            const auto prior = jaras::tempoPlayback::rate(song, previous);
            const bool follows = jaras::tempoPlayback::follows(song, previous);
            if (follows || previous.regionTempoAnchor.value_or(false))
                entry->second = follows ? prior * (*marker.tempoBPM / *previous.tempoBPM) : prior;
        }
        if (entry->second) {
            marker.tempoPlaybackRate = entry->second;
            marker.regionTempoAnchor = first;
        } else {
            marker.tempoPlaybackRate = jaras::tempoPlayback::rate(song, previous);
        }
    }
    return targets;
}
}
