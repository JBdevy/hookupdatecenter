#pragma once
#include "Common.h"
namespace catlive::regionPitch {
inline const jaras::Part *at(const jaras::Song &song, double position) {
    const jaras::Part *result = nullptr;
    for (const auto &p : song.parts)
        if (position >= p.startTime && position < p.endTime) {
            if (!result || (p.parentRegionID && !result->parentRegionID) ||
                (p.parentRegionID.has_value() == result->parentRegionID.has_value() &&
                 p.startTime > result->startTime))
                result = &p;
        }
    return result;
}
// Local and Remote Tuner must address the same audible/selected source region.
inline const jaras::Part *target(const jaras::Song &song, const jaras::TransportState &transport) {
    if (transport.playing) {
        for (const auto &part : song.parts) if (transport.ignoreNextRegionId == part.id) return &part;
        if (const auto *part = at(song, transport.position)) return part;
    }
    for (const auto &part : song.parts) if (transport.regionId == part.id) {
        if (transport.playing) return &part;
        const jaras::Part *first = nullptr;
        for (const auto &child : song.parts)
            if (child.parentRegionID == part.id && (!first || child.startTime < first->startTime)) first = &child;
        return first ? first : &part;
    }
    return nullptr;
}
inline bool contains(const std::optional<std::vector<ID>> &ids, const ID &id) {
    return !ids || std::find(ids->begin(), ids->end(), id) != ids->end();
}
inline bool folder(const jaras::Song &song, const ID &id) {
    return std::any_of(song.tracks.begin(), song.tracks.end(),
                       [&](const auto &t) { return t.parentTrackID == id; });
}
inline bool selected(const jaras::Song &song, const jaras::Track &track, const jaras::Part &part) {
    if (!jaras::fixedTrackName(track.role).empty())
        return false;
    const bool isFolder = folder(song, track.id);
    if (part.pitchTrackIDs ? contains(part.pitchTrackIDs, track.id) : !isFolder)
        return true;
    if (part.pitchGroupIDs ? contains(part.pitchGroupIDs, track.id) : isFolder)
        return true;
    auto parent = track.parentTrackID;
    for (size_t depth = 0; parent && depth < song.tracks.size(); ++depth) {
        if (contains(part.pitchGroupIDs, *parent))
            return true;
        auto found = std::find_if(song.tracks.begin(), song.tracks.end(),
                                  [&](const auto &t) { return t.id == *parent; });
        if (found == song.tracks.end())
            break;
        parent = found->parentTrackID;
    }
    return false;
}
inline int value(const jaras::Song &song, const jaras::Track &track, double position) {
    auto *part = at(song, position);
    return part && selected(song, track, *part) ? part->pitchSemitones.value_or(0) : 0;
}
inline std::vector<ID> defaults(const jaras::Song &song, bool groups) {
    std::vector<ID> result;
    for (const auto &track : song.tracks)
        if (jaras::fixedTrackName(track.role).empty() && folder(song, track.id) == groups)
            result.push_back(track.id);
    return result;
}
} // namespace catlive::regionPitch
