#pragma once
#include "../Project/Models.hpp"
#include <limits>
namespace jaras {
// Playback entry is independent of selection and survives continuous playback,
// pause/resume and loop wraps. A deliberate seek starts a new entry.
inline std::optional<ID> playbackEntryRegion(const Song& song, double position) {
    const Part* root = nullptr;
    for (const auto& part : song.parts)
        if (!part.parentRegionID && position >= part.startTime - 1e-6 && position < part.endTime &&
            (!root || part.endTime - part.startTime < root->endTime - root->startTime)) root = &part;
    if (!root) return {};
    const Part* child = nullptr;
    for (const auto& part : song.parts)
        if (part.parentRegionID == root->id && part.startTime <= position + 1e-6 &&
            (!child || part.startTime > child->startTime || (part.startTime == child->startTime && part.id < child->id))) child = &part;
    return child ? std::optional<ID>(child->id) : std::nullopt;
}
inline std::optional<double> playbackItemStart(const Song& song, const AudioClip& clip) {
    // Persisted attachment wins over rounded/moved item onsets. Unattached
    // items in initialized documents remain global; do not adopt them again.
    if (!song.regionOwnershipInitialized) return clip.startTime;
    const auto& owner = clip.regionOwnerID;
    if (owner) for (const auto& part : song.parts) if (part.id == *owner) {
        if (part.parentRegionID) return part.startTime;
        return clip.startTime;
    }
    return song.regionOwnershipInitialized ? std::nullopt : std::optional<double>(clip.startTime);
}
struct PlaybackScope {
    double minimum = -std::numeric_limits<double>::infinity();
    double maximum = std::numeric_limits<double>::infinity();
    bool allows(std::optional<double> itemStart) const noexcept {
        return !itemStart || (*itemStart >= minimum - 1e-6 && *itemStart < maximum - 1e-6);
    }
    bool operator==(const PlaybackScope& other) const { return minimum == other.minimum && maximum == other.maximum; }
    bool operator!=(const PlaybackScope& other) const { return !(*this == other); }
};
inline PlaybackScope playbackScope(const Song& song, const TransportState& transport, bool secondary = false) {
    PlaybackScope scope;
    const auto& entry = secondary ? transport.subPlaybackStartRegionId : transport.playbackStartRegionId;
    if (entry) for (const auto& part : song.parts) if (part.id == *entry && part.parentRegionID) scope.minimum = part.startTime;
    if (!secondary && transport.ignoreNextAfter) scope.maximum = *transport.ignoreNextAfter;
    return scope;
}
}
