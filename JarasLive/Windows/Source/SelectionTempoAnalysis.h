#pragma once
#include "ClipTempo.h"
#include "ProjectCodec.h"
#include "SelectionTempoPulse.h"

namespace catlive::selectionTempo {
// Copy only intersecting timing and media references. The project, waveforms,
// audio engine and decoder graph stay on their existing ownership paths.
inline std::vector<Lane> plan(const jaras::Song& song, Range range) {
    std::vector<Lane> lanes;
    jaras::TempoEditMap::PlaybackRates rates(song);
    for (const auto& track : song.tracks) {
        if (jaras::isTeleprompterRole(track.role) || track.role.id == "chords" || track.role.id == "timecode" ||
            track.role.id == "programChange" || track.role.id == "video") continue;
        const auto name = text(track.name).trim();
        Lane lane{track.role.id == "click" || track.role.id == "generatedClick" ||
                  name.equalsIgnoreCase("Click") || name.equalsIgnoreCase("Metronome"), {}};
        for (const auto& clip : track.clips) {
            const auto& file = clip.audioFile ? clip.audioFile : track.audioFile;
            if (!file || file->path.empty() || (clip.text && !clip.audioFile) || (clip.midi && !clip.frozenMIDI.value_or(false)) ||
                clip.startTime >= range.second || clip.startTime + clip.duration <= range.first) continue;
            ClipTempo timing(clip, &song, &rates);
            for (const auto& span : timing.spans) {
                const double a = std::max(range.first, span.start), b = std::min(range.second, span.end);
                if (a < b && std::isfinite(span.rate) && span.rate > 0)
                    lane.spans.push_back({file->path,a,b,timing.sourceAt(a),span.rate,
                                          clip.loopStart.value_or(0),clip.loopLength.value_or(0)});
            }
        }
        if (!lane.spans.empty()) lanes.push_back(std::move(lane));
    }
    return lanes;
}

inline void addAudio(AudioFormatReader& reader, const Span& span, Range range,
                     std::vector<double>& energy, const std::atomic<bool>& cancel) {
    constexpr int readSize = 8192;
    if (reader.sampleRate <= 0 || reader.numChannels == 0 || reader.lengthInSamples <= 0) return;
    AudioBuffer<float> block(int(reader.numChannels), readSize);
    int64 first = -1;
    int count = 0;
    accumulate(span,range,reader.sampleRate,reader.lengthInSamples,energy,cancel,[&](int64 frame) -> double {
        if (first < 0 || frame < first || frame >= first + count) {
            first = frame;
            count = int(std::min<int64>(readSize,reader.lengthInSamples-first));
            if (!reader.read(&block,0,count,first,true,true)) return -1;
        }
        double sum = 0;
        for (int ch = 0; ch < block.getNumChannels(); ++ch) {
            const double sample = block.getSample(ch,int(frame-first));
            if (std::isfinite(sample)) sum += sample * sample;
        }
        return sum / block.getNumChannels();
    });
}

inline std::optional<double> analyse(const std::vector<Lane>& lanes, const File& directory,
                                     const std::atomic<bool>& cancel, std::atomic<double>& progress) {
    AudioFormatManager formats;
    registerAudioFormats(formats);
    size_t completed = 0;
    for (bool click : {true,false}) {
        std::vector<Estimate> votes;
        for (const auto& lane : lanes) {
            if (lane.click != click) continue;
            const auto samples = windows(lane);
            for (size_t i = 0; i < samples.size(); ++i) {
                const auto range = samples[i];
                std::vector<double> energy(size_t(std::ceil((range.second-range.first)*envelopeHz)),0);
                for (const auto& span : lane.spans) {
                    if (cancel.load()) return {};
                    if (span.start >= range.second || span.end <= range.first) continue;
                    const auto path = ProjectCodec::resolveMedia(directory,span.path);
                    if (!path.existsAsFile()) continue;
                    std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(path));
                    if (reader) addAudio(*reader,span,range,energy,cancel);
                }
                if (auto value = estimate(energy)) votes.push_back(*value);
                progress.store((completed + double(i+1)/samples.size()) / lanes.size());
            }
            ++completed;
        }
        if (auto value = dominant(votes)) { progress.store(1); return value; }
    }
    progress.store(1);
    return {};
}
}
