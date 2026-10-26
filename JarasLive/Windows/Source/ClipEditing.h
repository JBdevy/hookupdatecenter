#pragma once
#include "Common.h"
#include "ClipTempo.h"
namespace catlive::clipEditing {
inline bool projection(const jaras::AudioClip &clip) {
    return clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0;
}
inline bool singleLane(const jaras::Track &track) {
    return jaras::isTeleprompterRole(track.role) || track.role.id == "chords" ||
           track.role.id == "video";
}
inline void splitSelected(jaras::Song &song, const std::set<ID> &selected, double at, std::map<ID, ID> *sources = nullptr) {
    if (!std::isfinite(at))
        return;
    for (auto &track : song.tracks) {
        std::vector<jaras::AudioClip> added;
        for (auto &clip : track.clips) {
            if ((!selected.empty() && !selected.count(clip.id)) || at <= clip.startTime + .001 ||
                at >= clip.startTime + clip.duration - .001 ||
                ((track.role.id == "timecode" || track.role.id == "generatedClick") &&
                 !projection(clip)))
                continue;
            auto right = clip;
            right.id = uuid();
            if (sources) sources->emplace(right.id, clip.id);
            const double length = at - clip.startTime, fraction = length / clip.duration;
            right.startTime = at;
            right.duration -= length;
            if (!clip.text || clip.audioFile || clip.loopLength) {
                // The source clock includes every relative-tempo segment before
                // the cut. Multiplying by the item's base rate repeats/skips
                // audio as soon as a marker has changed its actual speed.
                right.sourceOffset = ClipTempo(clip, &song).sourceAt(at);
                if (const double loop = clip.loopLength.value_or(0); loop > 0) {
                    const double origin = clip.loopStart.value_or(0);
                    if (right.sourceOffset >= origin)
                        right.sourceOffset = origin + std::fmod(right.sourceOffset - origin, loop);
                }
            }
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
            // Keep the original outer fades; the newly cut seam has no fade.
            clip.fadeOut = 0; right.fadeIn = 0;
            clip.duration = length;
            added.push_back(std::move(right));
        }
        track.clips.insert(track.clips.end(), added.begin(), added.end());
    }
}
inline void split(jaras::Song &song, const ID &selected, double at) {
    splitSelected(song, selected.empty() ? std::set<ID>{} : std::set<ID>{selected}, at);
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
inline bool fits(const jaras::Track &track, const jaras::AudioClip &clip, double start) {
    if(start<0 || !std::isfinite(start)) return false;
    try { requireSpace(track,clip,start,start+clip.duration); return true; } catch(const std::runtime_error &) { return false; }
}
inline double constrainedStart(const jaras::Track &track, const jaras::AudioClip &clip, double proposed) {
    proposed=std::max(0.,proposed);
    if(!singleLane(track) || fits(track,clip,proposed)) return proposed;
    double best=clip.startTime, distance=std::numeric_limits<double>::infinity();
    auto consider=[&](double candidate) {if(fits(track,clip,candidate) && std::abs(candidate-proposed)<distance) {best=candidate;distance=std::abs(candidate-proposed);}};
    consider(0);
    for(const auto &other:track.clips) if(other.id!=clip.id && (!jaras::isTeleprompterRole(track.role) || projection(other)==projection(clip))) {
        consider(other.startTime-clip.duration); consider(other.startTime+other.duration);
    }
    return best;
}
inline std::pair<double,double> constrainedEdges(const jaras::Track &track,const jaras::AudioClip &clip,double start,double end) {
    if(!singleLane(track)) return {start,end};
    double left=0,right=std::numeric_limits<double>::infinity();
    for(const auto &other:track.clips) if(other.id!=clip.id && (!jaras::isTeleprompterRole(track.role) || projection(other)==projection(clip))) {
        if(other.startTime+other.duration<=clip.startTime+1e-7) left=std::max(left,other.startTime+other.duration);
        if(other.startTime>=clip.startTime+clip.duration-1e-7) right=std::min(right,other.startTime);
    }
    return {std::max(left,start),std::min(right,end)};
}
// Preview and commit share the same source interval, including left extension.
inline jaras::AudioClip resizedSource(jaras::AudioClip clip, double start, double end) {
    if (!std::isfinite(start) || !std::isfinite(end) || start < 0 || end - start < .01)
        return clip;
    if(clip.audioFile && !clip.loopLength) {
        const double actualStart=std::max(start,clip.startTime-clip.sourceOffset/clip.playbackRate);
        if(end-actualStart<.01)return clip;
        clip.sourceOffset=std::max(0.,clip.sourceOffset+(actualStart-clip.startTime)*clip.playbackRate);
        clip.startTime=actualStart;clip.duration=end-actualStart;
        return clip;
    }
    const double loopStart = clip.loopStart.value_or(clip.sourceOffset);
    const double loopLength = clip.loopLength.value_or(clip.duration * clip.playbackRate);
    if (!std::isfinite(loopLength) || loopLength <= 0)
        throw std::runtime_error("Duração da fonte inválida.");
    const double offset = clip.sourceOffset - loopStart +
                          (start - clip.startTime) * clip.playbackRate;
    clip.loopStart = loopStart;
    clip.loopLength = loopLength;
    clip.sourceOffset =
        loopStart +
        std::fmod(std::fmod(offset, loopLength) + loopLength, loopLength);

    clip.startTime = start;
    clip.duration = end - start;
    return clip;
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
                    clip.startTime = start;
                    clip.duration = end - start;
                    } else { clip = resizedSource(clip, start, end); }
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
