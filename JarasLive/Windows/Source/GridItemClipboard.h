#pragma once
#include "Common.h"
namespace catlive {
// Same project/track scope and relative timing as Application/Project/GridItemClipboard.swift.
struct GridItemClipboard {
    ID project, song;
    std::vector<jaras::Track> tracks;
    bool moving = false;
    double endPosition() const {
        double end = 0;
        for (const auto &track : tracks) for (const auto &clip : track.clips)
            end = std::max(end, clip.startTime + clip.duration);
        return end;
    }

    static std::optional<GridItemClipboard> copy(const jaras::Project &project, const ID &song,
                                                const std::set<ID> &selection, bool moving = false) {
        GridItemClipboard result{project.id, song, {}, moving};
        for (const auto &source : project.songs) if (source.id == song)
            for (const auto &track : source.tracks) {
                if (track.role.id == "timecode") continue;
                jaras::Track entry; entry.id = track.id;
                for (const auto &clip : track.clips)
                    if (selection.count(clip.id)) entry.clips.push_back(clip);
                if (!entry.clips.empty()) result.tracks.push_back(std::move(entry));
            }
        if (result.tracks.empty()) return {};
        return result;
    }

    std::vector<jaras::Track> items(const jaras::Project &destination, double position) const {
        if (destination.id != project || !std::isfinite(position) || position < 0)
            throw std::runtime_error("Os itens copiados pertencem a outro projeto.");
        const auto source = std::find_if(destination.songs.begin(), destination.songs.end(),
                                         [&](const auto &value) { return value.id == song; });
        if (source == destination.songs.end()) throw std::runtime_error("A timeline de destino não existe mais.");
        auto result = tracks;
        double first = std::numeric_limits<double>::infinity();
        for (auto &entry : result) {
            const auto target = std::find_if(source->tracks.begin(), source->tracks.end(),
                                             [&](const auto &value) { return value.id == entry.id; });
            if (target == source->tracks.end() || target->role.id == "timecode")
                throw std::runtime_error("A pista de destino não existe mais.");
            for (auto &clip : entry.clips) {
                if (moving) {
                    const auto current = std::find_if(target->clips.begin(), target->clips.end(),
                                                      [&](const auto &value) { return value.id == clip.id; });
                    if (current == target->clips.end()) throw std::runtime_error("Um item a mover não existe mais.");
                    clip = *current;
                }
                first = std::min(first, clip.startTime);
            }
        }
        for (auto &entry : result) for (auto &clip : entry.clips) {
            clip.startTime = position + (clip.startTime - first);
            if (!moving) { clip.id = uuid(); clip.separatedStemTracks.clear(); }
        }
        return result;
    }
};
} // namespace catlive
