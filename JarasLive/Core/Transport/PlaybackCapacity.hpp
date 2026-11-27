#pragma once
#include "PlaybackScope.hpp"
#include <algorithm>
#include <cmath>
#include <array>

namespace jaras::playbackCapacity {
inline constexpr std::size_t limit = 250;
// In a free audio arrangement with no tempo map, a BPM edit only updates the clock.
inline bool tempoChangesClockOnly(const Song& song) {
    if (song.timeSettings.value_or(ProjectTimeSettings{}).timebase != ProjectTimebase::free || !song.parts.empty())
        return false;
    if (song.markers && std::any_of(song.markers->begin(), song.markers->end(),
            [](const auto& marker) { return marker.tempoBPM.has_value(); })) return false;
    return std::none_of(song.tracks.begin(), song.tracks.end(), [](const auto& track) {
        return std::any_of(track.clips.begin(), track.clips.end(), [](const auto& clip) { return clip.midi.has_value(); });
    });
}
inline constexpr const char* notice = "250+ — Not available";
inline constexpr const char* openingNotice = "Some passages exceed 250 simultaneous audio voices. Parts, quantized seeks, Repeat and certain live tempo changes are limited in those passages.";
inline bool isFile(const Track& track, const AudioClip& clip) {
    const auto& file = clip.audioFile ? clip.audioFile : track.audioFile;
    return file && !file->path.empty() && file->path.rfind("Images/", 0) != 0 &&
        (!clip.midi || clip.frozenMIDI.value_or(false));
}
inline std::size_t at(const Song& song, double position, const PlaybackScope& scope = {}) {
    std::size_t count = 0;
    for (const auto& track : song.tracks) for (const auto& clip : track.clips)
        if (isFile(track, clip) && clip.startTime <= position && position < clip.startTime + clip.duration &&
            scope.allows(playbackItemStart(song, clip), playbackOwnerIndex(song, clip.regionOwnerID))) ++count;
    // Mute, Solo, gain and shared file names deliberately do not reduce load.
    return count;
}
inline std::array<std::size_t, 2> heads(const Song& song, const TransportState& transport, const std::vector<ID>& exclusiveTracks = {}) {
    std::array<std::size_t, 2> count{};
    for (int head = 0; head != 2; ++head) {
        if (head ? !transport.subPlay.playing : !transport.playing) continue;
        const double position = head ? transport.subPlay.position : transport.position;
        const auto scope = playbackScope(song, transport, head != 0);
        for (const auto& track : song.tracks) for (const auto& clip : track.clips) {
            if (!isFile(track, clip) || position < clip.startTime || position >= clip.startTime + clip.duration || !scope.allows(playbackItemStart(song, clip))) continue;
            if (clip.regionOwnerID && std::find(exclusiveTracks.begin(), exclusiveTracks.end(), track.id) != exclusiveTracks.end()) {
                if (!head && transport.subPlay.playing && transport.subExclusivePlaybackRegionId) continue;
                const auto& owner = head ? transport.subExclusivePlaybackRegionId : transport.exclusivePlaybackRegionId;
                if (owner && owner != clip.regionOwnerID) continue;
            }
            ++count[head];
        }
    }
    return count;
}
inline std::size_t active(const Song& song, const TransportState& transport, const std::vector<ID>& exclusiveTracks = {}) {
    const auto count = heads(song, transport, exclusiveTracks);
    return count[0] + count[1];
}
inline bool exceeded(const Song& song, const TransportState& transport, const std::vector<ID>& exclusiveTracks = {}) {
    const auto count = heads(song, transport, exclusiveTracks);
    return count[0] > limit || count[1] > limit;
}
// Check the whole travel interval, including files that start and end between
// two transport updates. The two playback heads retain independent budgets.
inline bool exceededDuring(const Song& song, const TransportState& transport, double elapsed,
                           const std::vector<ID>& exclusiveTracks = {}) {
    if (!std::isfinite(elapsed) || elapsed < 0) return false;
    for (int head = 0; head != 2; ++head) {
        if (head ? !transport.subPlay.playing : !transport.playing) continue;
        const double start = head ? transport.subPlay.position : transport.position;
        const double end = start + elapsed;
        const auto scope = playbackScope(song, transport, head != 0);
        std::size_t count = 0;
        std::vector<std::pair<double, int>> edges;
        for (const auto& track : song.tracks) for (const auto& clip : track.clips) {
            if (!isFile(track, clip) || !scope.allows(playbackItemStart(song, clip))) continue;
            if (clip.regionOwnerID && std::find(exclusiveTracks.begin(), exclusiveTracks.end(), track.id) != exclusiveTracks.end()) {
                if (!head && transport.subPlay.playing && transport.subExclusivePlaybackRegionId) continue;
                const auto& owner = head ? transport.subExclusivePlaybackRegionId : transport.exclusivePlaybackRegionId;
                if (owner && owner != clip.regionOwnerID) continue;
            }
            const double clipEnd = clip.startTime + clip.duration;
            if (clip.startTime <= start && start < clipEnd) ++count;
            if (clip.startTime > start && clip.startTime <= end && clip.startTime < clipEnd)
                edges.emplace_back(clip.startTime, 1);
            if (clipEnd > start && clipEnd <= end && clip.startTime < clipEnd)
                edges.emplace_back(clipEnd, -1);
        }
        if (count > limit) return true;
        std::sort(edges.begin(), edges.end());
        for (const auto& edge : edges) {
            if (edge.second < 0) --count; else ++count;
            if (count > limit) return true;
        }
    }
    return false;
}
inline std::size_t peak(const Project& project) {
    std::size_t maximum = 0;
    for (const auto& song : project.songs) {
        std::vector<std::pair<double, int>> edges;
        for (const auto& track : song.tracks) for (const auto& clip : track.clips)
            if (isFile(track, clip) && clip.duration > 0 && std::isfinite(clip.startTime) && std::isfinite(clip.duration)) {
                edges.emplace_back(clip.startTime, 1);
                edges.emplace_back(clip.startTime + clip.duration, -1);
            }
        std::sort(edges.begin(), edges.end()); // End precedes start at the same sample boundary.
        std::size_t count = 0;
        for (const auto& edge : edges) {
            if (edge.second < 0) --count; else ++count;
            maximum = std::max(maximum, count);
        }
    }
    return maximum;
}
}
