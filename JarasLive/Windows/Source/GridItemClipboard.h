#pragma once
#include "Common.h"
namespace catlive {
// Same project/track scope and relative timing as Application/Project/GridItemClipboard.swift.
struct GridItemClipboard {
    ID project, song;
    std::vector<jaras::Track> tracks;
    bool moving = false;
    std::map<ID, size_t> sourceRows;
    std::vector<jaras::Track> sourceTrackTemplates;
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
                result.sourceRows[track.id] = size_t(&track - source.tracks.data());
                jaras::Track row; row.id = track.id; row.name = track.name; row.color = track.color;
                row.role = jaras::fixedTrackName(track.role).empty() ? track.role : jaras::TrackRole{"other"};
                result.sourceTrackTemplates.push_back(std::move(row));
                if (track.role.id == "timecode") continue;
                jaras::Track entry; entry.id = track.id;
                for (const auto &clip : track.clips)
                    if (selection.count(clip.id) && !(track.role.id == "generatedClick" && !clip.audioFile)) entry.clips.push_back(clip);
                if (!entry.clips.empty()) result.tracks.push_back(std::move(entry));
            }
        if (result.tracks.empty()) return {};
        return result;
    }

    struct CopyPlan { std::vector<jaras::Track> entries, newTracks; };
    CopyPlan copyPlan(const jaras::Song &destination, double position, const std::set<ID> &selectedTracks) const {
        if (moving || tracks.empty()) throw std::runtime_error("Select a destination track before pasting.");
        auto target = std::find_if(destination.tracks.begin(), destination.tracks.end(),
            [&](const auto &track) { return selectedTracks.count(track.id) != 0; });
        if (target == destination.tracks.end()) target = std::find_if(destination.tracks.begin(), destination.tracks.end(),
            [](const auto &track) { return jaras::fixedTrackName(track.role).empty(); });
        const auto targetRow = size_t(target - destination.tracks.begin());
        size_t first = std::numeric_limits<size_t>::max(), last = 0;
        for (const auto &track : tracks) { first = std::min(first, sourceRows.at(track.id)); last = std::max(last, sourceRows.at(track.id)); }
        auto expanded = destination;
        CopyPlan plan;
        while (expanded.tracks.size() <= targetRow + last - first) {
            auto track = sourceTrackTemplates.at(first + expanded.tracks.size() - targetRow);
            track.id = uuid(); expanded.tracks.push_back(track); plan.newTracks.push_back(std::move(track));
        }
        plan.entries = copiedItems(expanded, position, {expanded.tracks[targetRow].id});
        return plan;
    }

    std::vector<jaras::Track> copiedItems(const jaras::Song &destination, double position,
                                        const std::set<ID> &selectedTracks) const {
        auto target = std::find_if(destination.tracks.begin(), destination.tracks.end(),
            [&](const auto &track) { return selectedTracks.count(track.id) != 0; });
        if (target == destination.tracks.end())
            target = std::find_if(destination.tracks.begin(), destination.tracks.end(),
                [](const auto &track) { return jaras::fixedTrackName(track.role).empty(); });
        if (moving || tracks.empty() || !std::isfinite(position) || position < 0 || target == destination.tracks.end())
            throw std::runtime_error("Select a destination track before pasting.");
        size_t firstRow = std::numeric_limits<size_t>::max();
        double firstTime = std::numeric_limits<double>::infinity();
        for (const auto &entry : tracks) {
            firstRow = std::min(firstRow, sourceRows.at(entry.id));
            for (const auto &clip : entry.clips) firstTime = std::min(firstTime, clip.startTime);
        }
        auto result = tracks;
        for (auto &entry : result) {
            const auto row = size_t(target - destination.tracks.begin()) + sourceRows.at(entry.id) - firstRow;
            if (row >= destination.tracks.size()) throw std::runtime_error("Not enough destination tracks to paste these items.");
            entry.id = destination.tracks[row].id;
            for (auto &clip : entry.clips) {
                clip.id = uuid(); clip.separatedStemTracks.clear(); clip.regionOwnerID.reset();
                clip.startTime = position + clip.startTime - firstTime;
            }
        }
        return result;
    }

    std::vector<jaras::Track> items(const jaras::Project &destination, double position,
                                  const std::set<ID> &selectedTracks = {}) const {
        if (destination.id != project || !std::isfinite(position) || position < 0)
            throw std::runtime_error("Os itens copiados pertencem a outro projeto.");
        const auto source = std::find_if(destination.songs.begin(), destination.songs.end(),
                                         [&](const auto &value) { return value.id == song; });
        if (source == destination.songs.end()) throw std::runtime_error("A timeline de destino não existe mais.");
        auto result = tracks;
        const auto destinationTrack = std::find_if(source->tracks.begin(), source->tracks.end(),
            [&](const auto &track) { return selectedTracks.count(track.id) != 0; });
        const auto firstSource = std::find_if(source->tracks.begin(), source->tracks.end(), [&](const auto &track) {
            return std::any_of(tracks.begin(), tracks.end(), [&](const auto &entry) { return entry.id == track.id; });
        });
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
                if (target->role.id == "generatedClick" && !clip.audioFile)
                    throw std::runtime_error("Os itens de Click só podem ser cortados ou redimensionados dentro da região.");
                first = std::min(first, clip.startTime);
            }
            if (destinationTrack != source->tracks.end() && firstSource != source->tracks.end()) {
                const auto row = std::distance(source->tracks.begin(), destinationTrack) + std::distance(firstSource, target);
                if (row < 0 || row >= static_cast<decltype(row)>(source->tracks.size()))
                    throw std::runtime_error("Invalid destination track");
                entry.id = source->tracks[static_cast<size_t>(row)].id;
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
