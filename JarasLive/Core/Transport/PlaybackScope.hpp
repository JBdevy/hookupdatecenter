#pragma once
#include "../Project/Models.hpp"
#include <limits>
namespace jaras {
// Playback entry is independent of selection and survives continuous playback,
// pause/resume and loop wraps. A deliberate seek starts a new entry.
inline double playbackRegionStart(const Song& song, const Part& part) {
    if (part.parentRegionID && song.markers) for (const auto& marker : *song.markers)
        if (marker.sourceRegionID == part.id && marker.unifiedRegionID == part.parentRegionID) return marker.position;
    return part.startTime;
}
inline std::optional<ID> playbackEntryRegion(const Song& song, double position) {
    const Part* root = nullptr;
    for (const auto& part : song.parts)
        if (!part.parentRegionID && position >= part.startTime - 1e-6 && position < part.endTime &&
            (!root || part.endTime - part.startTime < root->endTime - root->startTime)) root = &part;
    if (!root) return {};
    const Part* child = nullptr;
    for (const auto& part : song.parts)
        if (part.parentRegionID == root->id && playbackRegionStart(song, part) <= position + 1e-6 &&
            (!child || playbackRegionStart(song, part) > playbackRegionStart(song, *child) || (playbackRegionStart(song, part) == playbackRegionStart(song, *child) && part.id < child->id))) child = &part;
    return child ? std::optional<ID>(child->id) : std::nullopt;
}
inline std::optional<double> playbackItemStart(const Song& song, const AudioClip& clip) {
    // Persisted attachment wins over rounded/moved item onsets. Unattached
    // items in initialized documents remain global; do not adopt them again.
    if (!song.regionOwnershipInitialized) return clip.startTime;
    const auto& owner = clip.regionOwnerID;
    if (owner) for (const auto& part : song.parts) if (part.id == *owner) {
        if (part.parentRegionID) {
            const Part* incoming = nullptr;
            for (const auto& candidate : song.parts) {
                const auto start = playbackRegionStart(song, candidate);
                if (candidate.parentRegionID == part.parentRegionID && candidate.id != part.id &&
                    start < candidate.startTime - 1e-6 && clip.startTime >= start - 1e-6 &&
                    clip.startTime < candidate.startTime - 1e-6 && candidate.startTime > part.startTime &&
                    (!incoming || start > playbackRegionStart(song, *incoming))) incoming = &candidate;
            }
            return playbackRegionStart(song, incoming ? *incoming : part);
        }
        return clip.startTime;
    }
    return song.regionOwnershipInitialized ? std::nullopt : std::optional<double>(clip.startTime);
}
struct PlaybackScope {
    double minimum = -std::numeric_limits<double>::infinity();
    double maximum = std::numeric_limits<double>::infinity();
    // Zero keeps ordinary playback; UINT32_MAX excludes all attached items.
    std::uint32_t requiredOwner = 0;
    bool allows(std::optional<double> itemStart, std::uint32_t owner) const noexcept {
        return allows(itemStart) && (!owner || !requiredOwner || owner == requiredOwner);
    }
    bool allows(std::optional<double> itemStart) const noexcept {
        return !itemStart || (*itemStart >= minimum - 1e-6 && *itemStart < maximum - 1e-6);
    }
    bool operator==(const PlaybackScope& other) const { return minimum == other.minimum && maximum == other.maximum && requiredOwner == other.requiredOwner; }
    bool operator!=(const PlaybackScope& other) const { return !(*this == other); }
};
inline std::uint32_t playbackOwnerIndex(const Song& song, const std::optional<ID>& owner) {
    if (owner) for (size_t i = 0; i < song.parts.size(); ++i)
        if (song.parts[i].id == *owner) return std::uint32_t(i + 1);
    return 0;
}
inline PlaybackScope playbackScope(const Song& song, const TransportState& transport, bool secondary = false) {
    PlaybackScope scope;
    const auto& entry = secondary ? transport.subPlaybackStartRegionId : transport.playbackStartRegionId;
    if (entry) for (const auto& part : song.parts) if (part.id == *entry && part.parentRegionID) scope.minimum = playbackRegionStart(song, part);
    if (!secondary && transport.ignoreNextAfter) scope.maximum = *transport.ignoreNextAfter;
    return scope;
}
inline PlaybackScope exclusiveSubplayScope(const Song& song, const TransportState& transport, bool secondary = false) {
    auto scope = playbackScope(song, transport, secondary);
    if (!secondary && transport.subPlay.playing && transport.subExclusivePlaybackRegionId)
        scope.requiredOwner = std::numeric_limits<std::uint32_t>::max();
    else scope.requiredOwner = playbackOwnerIndex(song, secondary ? transport.subExclusivePlaybackRegionId : transport.exclusivePlaybackRegionId);
    return scope;
}
}
