#pragma once
#include "Common.h"
namespace catlive::clipEditing {
inline bool projection(const jaras::AudioClip &clip) {
    return clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0;
}
inline bool singleLane(const jaras::Track &track) {
    return jaras::isTeleprompterRole(track.role) || track.role.id == "chords" ||
           track.role.id == "video";
}
inline void split(jaras::Song &song, const ID &selected, double at) {
    if (!std::isfinite(at))
        return;
    for (auto &track : song.tracks) {
        std::vector<jaras::AudioClip> added;
        for (auto &clip : track.clips) {
            if ((!selected.empty() && clip.id != selected) || at <= clip.startTime + .001 ||
                at >= clip.startTime + clip.duration - .001 ||
                ((track.role.id == "timecode" || track.role.id == "generatedClick") &&
                 !projection(clip)))
                continue;
            auto right = clip;
            right.id = uuid();
            const double length = at - clip.startTime, fraction = length / clip.duration;
            right.startTime = at;
            right.duration -= length;
            if (!clip.text || clip.audioFile || clip.loopLength)
                right.sourceOffset += length * clip.playbackRate;
            if (!clip.loopLength) {
                auto divide = [fraction](std::vector<double> &left, std::vector<double> &right) {
                    const auto cut =
                        std::min(left.size(), (size_t)std::round(left.size() * fraction));
                    right.assign(left.begin() + cut, left.end());
                    left.resize(cut);
                };
                divide(clip.waveform, right.waveform);
                for (size_t i = 0; i < clip.waveformChannels.size(); ++i)
                    divide(clip.waveformChannels[i], right.waveformChannels[i]);
            }
            clip.duration = length;
            added.push_back(std::move(right));
        }
        track.clips.insert(track.clips.end(), added.begin(), added.end());
    }
}
inline void requireSpace(const jaras::Track &track, const jaras::AudioClip &clip, double start,
                         double end) {
    if (!singleLane(track))
        return;
    for (const auto &other : track.clips)
        if (other.id != clip.id &&
            (!jaras::isTeleprompterRole(track.role) || projection(other) == projection(clip)) &&
            start < other.startTime + other.duration - 1e-7 && end > other.startTime + 1e-7)
            throw std::runtime_error("Já existe um item nesta posição da pista.");
}
inline void resize(jaras::Project &project, const ID &id, double start, double end) {
    if (!std::isfinite(start) || !std::isfinite(end) || start < 0 || end - start < .01)
        throw std::runtime_error("O item precisa ter pelo menos 10 ms.");
    for (auto &song : project.songs)
        for (auto &track : song.tracks)
            for (auto &clip : track.clips)
                if (clip.id == id) {
                    if (track.role.id == "generatedClick" && !projection(clip))
                        throw std::runtime_error("Os itens de Click acompanham suas regiões.");
                    requireSpace(track, clip, start, end);
                    if (track.role.id == "timecode" && !projection(clip)) {
                        if (!track.importedTimecodeItems) {
                            const auto region = std::find_if(
                                song.parts.begin(), song.parts.end(),
                                [&](const auto &part) { return clip.regionOwnerID == part.id; });
                            if (region == song.parts.end())
                                throw std::runtime_error("Região do timecode não encontrada.");
                            clip.timecodeStartOffset = start - region->startTime;
                            clip.timecodeEndOffset = end - region->endTime;
                        }
                    } else if (clip.midi) {
                        const double offset =
                            clip.sourceOffset + (start - clip.startTime) * clip.playbackRate;
                        if (offset < 0)
                            for (auto &note : clip.midi->notes)
                                note.start -= offset * clip.midi->sourceBPM / 60.;
                        clip.sourceOffset = std::max(0., offset);
                    } else {
                        const double loopStart = clip.loopStart.value_or(clip.sourceOffset);
                        const double loopLength =
                            clip.loopLength.value_or(clip.duration * clip.playbackRate);
                        if (!std::isfinite(loopLength) || loopLength <= 0)
                            throw std::runtime_error("Duração da fonte inválida.");
                        const double offset = clip.sourceOffset - loopStart +
                                              (start - clip.startTime) * clip.playbackRate;
                        clip.loopStart = loopStart;
                        clip.loopLength = loopLength;
                        clip.sourceOffset =
                            loopStart +
                            std::fmod(std::fmod(offset, loopLength) + loopLength, loopLength);
                    }
                    clip.startTime = start;
                    clip.duration = end - start;
                    song.duration = std::max(song.duration, end);
                    return;
                }
    throw std::runtime_error("O item não existe mais.");
}
inline void move(jaras::Project &project, const ID &id, double start, const ID &targetID = {}) {
    if (!std::isfinite(start) || start < 0)
        throw std::runtime_error("Posição do item inválida.");
    for (auto &song : project.songs)
        for (auto &track : song.tracks)
            for (auto it = track.clips.begin(); it != track.clips.end(); ++it)
                if (it->id == id) {
                    auto target = std::find_if(
                        song.tracks.begin(), song.tracks.end(), [&](const auto &value) {
                            return value.id == (targetID.empty() ? track.id : targetID);
                        });
                    if (target == song.tracks.end())
                        throw std::runtime_error("Pista de destino não encontrada.");
                    if (!projection(*it)) {
                        if (track.role.id == "timecode")
                            throw std::runtime_error(
                                "Os itens de timecode acompanham suas regiões.");
                        if ((!jaras::fixedTrackName(track.role).empty() &&
                             target->id != track.id) ||
                            jaras::fixedTrackName(track.role) !=
                                jaras::fixedTrackName(target->role))
                            throw std::runtime_error("Mova este item em sua própria pista.");
                    }
                    requireSpace(*target, *it, start, start + it->duration);
                    auto moved = *it;
                    moved.startTime = start;
                    moved.regionOwnerID = jaras::regionOwnerAt(song, start);
                    track.clips.erase(it);
                    song.duration = std::max(song.duration, start + moved.duration);
                    target->clips.push_back(std::move(moved));
                    return;
                }
    throw std::runtime_error("O item não existe mais.");
}
} // namespace catlive::clipEditing
