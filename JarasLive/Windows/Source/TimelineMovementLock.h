#pragma once
#include "Project/Models.hpp"
#include <string_view>
#include <unordered_map>

namespace catlive::timelineGrid {
inline bool movementLocked(const jaras::Project &project) noexcept {
    return project.timelineMovementLocked.value_or(false);
}

// Guard the candidate before committing history/audio. Only surviving entities
// are compared: creation, duplication and deletion remain available. Metadata,
// fades, MIDI contents, FX and track ordering do not change grid geometry.
// Explicit tempo-retiming commands bypass this check at their action boundary;
// editing a marker's BPM/meter/name/color alone is always allowed here.
inline bool changesLockedGeometry(const jaras::Project &before, const jaras::Project &after) {
    if (!movementLocked(before)) return false;
    struct ClipLocation { const jaras::AudioClip *clip; std::string_view song, track; };
    struct RegionLocation { const jaras::Part *part; std::string_view song; };
    struct MarkerLocation { const jaras::TimelineMarker *marker; std::string_view song; };
    std::unordered_map<std::string_view, ClipLocation> clips;
    std::unordered_map<std::string_view, RegionLocation> regions;
    std::unordered_map<std::string_view, MarkerLocation> markers;
    for (const auto &song : before.songs) {
        for (const auto &track : song.tracks)
            for (const auto &clip : track.clips)
                clips.emplace(clip.id, ClipLocation{&clip, song.id, track.id});
        for (const auto &part : song.parts)
            regions.emplace(part.id, RegionLocation{&part, song.id});
        if (song.markers) for (const auto &marker : *song.markers)
            markers.emplace(marker.id, MarkerLocation{&marker, song.id});
    }
    for (const auto &song : after.songs) {
        for (const auto &track : song.tracks) for (const auto &clip : track.clips) {
            const auto found = clips.find(clip.id);
            if (found == clips.end()) continue;
            const auto &old = found->second;
            if (old.song != song.id || old.track != track.id ||
                old.clip->startTime != clip.startTime || old.clip->duration != clip.duration ||
                old.clip->sourceOffset != clip.sourceOffset) return true;
        }
        for (const auto &part : song.parts) {
            const auto found = regions.find(part.id);
            if (found == regions.end()) continue;
            const auto &old = found->second;
            if (old.song != song.id || old.part->startTime != part.startTime ||
                old.part->endTime != part.endTime) return true;
        }
        if (song.markers) for (const auto &marker : *song.markers) {
            const auto found = markers.find(marker.id);
            if (found == markers.end()) continue;
            const auto &old = found->second;
            if (old.song != song.id || old.marker->position != marker.position) return true;
        }
    }
    return false;
}
} // namespace catlive::timelineGrid
