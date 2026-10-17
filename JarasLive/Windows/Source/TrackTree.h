#pragma once
#include "Common.h"
namespace catlive::trackTree {
inline size_t index(const jaras::Song &song, const ID &id) {
    for (size_t i = 0; i < song.tracks.size(); ++i)
        if (song.tracks[i].id == id)
            return i;
    return song.tracks.size();
}
inline bool descendant(const jaras::Song &song, size_t child, const ID &ancestor) {
    for (size_t count = 0; child < song.tracks.size() && count < song.tracks.size(); ++count) {
        const auto parent = song.tracks[child].parentTrackID;
        if (!parent)
            return false;
        if (*parent == ancestor)
            return true;
        child = index(song, *parent);
    }
    return false;
}
inline size_t end(const jaras::Song &song, size_t first) {
    if (first >= song.tracks.size())
        return first;
    size_t last = first + 1;
    while (last < song.tracks.size() && descendant(song, last, song.tracks[first].id))
        ++last;
    return last;
}
inline bool silenced(const jaras::Song &song, const jaras::Track &track) {
    if (track.mute || !jaras::fixedTrackName(track.role).empty()) return track.mute;
    bool anySolo = false;
    const auto at = index(song, track.id);
    for (size_t i = 0; i < song.tracks.size(); ++i) {
        if (!song.tracks[i].solo) continue;
        anySolo = true;
        if (i == at || descendant(song, at, song.tracks[i].id) || descendant(song, i, track.id)) return false;
    }
    return anySolo;
}
inline void resetGroupOutput(jaras::Track &track) {
    if (track.parentTrackID)
        return;
    auto reset = [](jaras::OutputPatch &patch) {
        if (patch.firstChannel == -2)
            patch.firstChannel = 0;
    };
    if (track.patch)
        reset(*track.patch);
    if (track.secondaryPatch)
        reset(*track.secondaryPatch);
    if (track.outputs)
        for (auto &patch : *track.outputs)
            reset(patch);
}
// Removing a folder preserves its children and their order, promoting them one level.
inline void remove(jaras::Song &song, const ID &id) {
    const auto at = index(song, id);
    if (at == song.tracks.size())
        return;
    const auto parent = song.tracks[at].parentTrackID;
    for (auto &track : song.tracks) {
        if (track.parentTrackID == id) {
            track.parentTrackID = parent;
            resetGroupOutput(track);
        }
        if (track.routing) {
            for (auto *slots : {&track.routing->receives, &track.routing->transmitters})
                for (auto &slot : *slots)
                    if (slot == id)
                        slot.reset();
        }
        if (track.stereoLinkPartner == id) {
            track.stereoLinkPartner.reset();
            track.stereoLinkJSON.reset();
            track.stereoLinkLeft = false;
        }
        for (auto &clip : track.clips)
            clip.separatedStemTracks.erase(
                std::remove(clip.separatedStemTracks.begin(), clip.separatedStemTracks.end(), id),
                clip.separatedStemTracks.end());
    }
    song.tracks.erase(song.tracks.begin() + at);
}
inline void move(jaras::Song &song, const ID &id, const ID &before) {
    const auto first = index(song, id), target = index(song, before);
    if (first == song.tracks.size() || target == song.tracks.size() || first == target)
        return;
    const auto last = end(song, first);
    if (target >= first && target < last)
        return;
    auto parent = song.tracks[target].parentTrackID;
    // Special tracks always remain at the root.
    if (!jaras::fixedTrackName(song.tracks[first].role).empty()) {
        if (parent)
            return;
        parent.reset();
    }
    std::vector<jaras::Track> moving(song.tracks.begin() + first, song.tracks.begin() + last);
    moving.front().parentTrackID = parent;
    resetGroupOutput(moving.front());
    song.tracks.erase(song.tracks.begin() + first, song.tracks.begin() + last);
    song.tracks.insert(song.tracks.begin() + index(song, before), moving.begin(), moving.end());
}
} // namespace catlive::trackTree
