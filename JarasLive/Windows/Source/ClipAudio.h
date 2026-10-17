#pragma once
#include "RegionPitch.h"
#include "ClipTempo.h"
#include "../ThirdParty/Signalsmith/signalsmith-stretch.h"
namespace catlive {
// Streaming clip pitch/rate/loop processing. Input lookahead removes the spectral
// algorithm's latency from the timeline; seeking and Sub Play have independent state.
class ClipAudio {
  public:
    ClipAudio(const jaras::Song &song, const jaras::Track &track, const jaras::AudioClip &clip,
              double rate) { configure(song, track, clip, rate); }
    void configure(const jaras::Song &song, const jaras::Track &track,
                   const jaras::AudioClip &clip, double rate) {
        offset = clip.sourceOffset; speed = clip.playbackRate; duration = clip.duration;
        start = clip.startTime;
        timing.emplace(clip, &song);
        loopStart = clip.loopStart.value_or(0); loopLength = clip.loopLength.value_or(0);
        segments.clear();
        std::vector<double> bounds{0, duration};
        for (const auto &span : timing->spans)
            if (span.start > start) bounds.push_back(span.start - start);
        for (const auto &part : song.parts) {
            for (double edge : {part.startTime, part.endTime})
                if (edge > clip.startTime && edge < clip.startTime + duration)
                    bounds.push_back(edge - clip.startTime);
        }
        std::sort(bounds.begin(), bounds.end());
        bounds.erase(std::unique(bounds.begin(), bounds.end()), bounds.end());
        for (size_t i = 0; i + 1 < bounds.size(); ++i) {
            const double region =
                clip.frozenMIDI.value_or(false) || clip.renderedTiming.value_or(false)
                    ? 0
                    : regionPitch::value(song, track,
                                         clip.startTime + (bounds[i] + bounds[i + 1]) * .5);
            segments.push_back({bounds[i], bounds[i + 1],
                                clip.pitchSemitones.value_or(0) + region -
                                12 * std::log2(timing->at(start + bounds[i])->rate)});
        }
        prepare(rate);
    }
    static bool needed(const jaras::Song &song, const jaras::Track &track,
                       const jaras::AudioClip &clip) {
        if (clip.loopLength.value_or(0) > 0 || std::abs(clip.playbackRate - 1) > 1e-9 ||
            clip.pitchSemitones.value_or(0) != 0)
            return true;
        const ClipTempo timing(clip, &song);
        for (const auto &span : timing.spans)
            if (std::abs(span.rate - 1) > 1e-9) return true;
        if (!clip.frozenMIDI.value_or(false) && !clip.renderedTiming.value_or(false))
            for (const auto &part : song.parts)
                if (part.pitchSemitones.value_or(0) != 0 && part.endTime > clip.startTime &&
                    part.startTime < clip.startTime + clip.duration &&
                    regionPitch::selected(song, track, part))
                    return true;
        return false;
    }
    void prepare(double rate) {
        sampleRate = rate;
        for (auto &head : heads) head.next = -1;
        // Rebuilding a track or reattaching the same device only invalidates
        // playback history. FFT plans/buffers depend on rate, not the track list.
        // Pure loops do not need a spectral processor at all.
        const bool spectral = std::any_of(segments.begin(), segments.end(),
                                         [](const auto &segment) { return std::abs(segment.pitch) >= 1e-8; });
        if (!spectral || preparedPitchRate == rate) return;
        for (auto &head : heads) {
            head.pitch.presetDefault(2, (float)rate);
            head.input.setSize(2, std::max(4096, head.pitch.outputSeekLength(1.f)));
            head.input.clear();
        }
        // The first render primes history with the actual source, independently
        // for each head; priming silent history here only did the work twice.
        preparedPitchRate = rate;
    }
    double sourcePosition(double local) const {
        const double source = timing ? timing->sourceAt(start + std::max(0., local))
                                     : offset + std::max(0., local) * speed;
        return loopLength > 0 && source >= loopStart
            ? loopStart + std::fmod(source - loopStart, loopLength) : source;
    }
    std::pair<double, double> readAheadRange(double local, double seconds) const {
        const auto begin = sourcePosition(local);
        const auto end = sourcePosition(std::min(duration, local + seconds));
        // A short source loop may wrap inside the first device block. Priming
        // only the final sample makes BufferingAudioReader discard its start.
        if (loopLength > 0 && (end < begin || loopLength <= seconds * speed))
            return {loopStart, loopStart + loopLength};
        return {begin, std::max(begin, end)};
    }
    bool render(AudioFormatReader &reader, AudioBuffer<float> &scratch, AudioBuffer<float> &output,
                int headIndex, double local, int count) {
        auto &head = heads[(size_t)headIndex];
        bool ok = true;
        int done = 0;
        while (done < count) {
            const double now = local + done / sampleRate;
            const Segment *segment = nullptr;
            for (const auto &s : segments)
                if (now >= s.start - 1e-8 && now < s.end - 1e-8) {
                    segment = &s;
                    break;
                }
            const double pitch = segment ? segment->pitch : 0;
            const int frames =
                segment ? std::min(
                              count - done,
                              std::max(1, (int)std::ceil((segment->end - now) * sampleRate - 1e-7)))
                        : count - done;
            if (std::abs(pitch) < 1e-8) {
                ok = read(reader, scratch, output, done, now, frames) && ok;
                head.next = -1;
            } else {
                if (std::abs(head.next - now) > .25 / sampleRate || head.semitones != pitch) {
                    head.pitch.setTransposeSemitones((float)pitch);
                    const int prime = head.pitch.outputSeekLength(1.f);
                    ok = read(reader, scratch, head.input, 0, now, prime) && ok;
                    head.pitch.outputSeek(head.input.getArrayOfReadPointers(), prime);
                    head.ahead = now + prime / sampleRate;
                    head.semitones = pitch;
                }
                ok = read(reader, scratch, head.input, 0, head.ahead, frames) && ok;
                float *outputs[]{output.getWritePointer(0, done), output.getWritePointer(1, done)};
                head.pitch.process(head.input.getArrayOfReadPointers(), frames, outputs, frames);
                head.ahead += frames / sampleRate;
                head.next = now + frames / sampleRate;
            }
            done += frames;
        }
        return ok;
    }

  private:
    struct Segment {
        double start, end, pitch;
    };
    struct Head {
        signalsmith::stretch::SignalsmithStretch<float> pitch{0};
        AudioBuffer<float> input;
        double next = -1, ahead = 0, semitones = 0;
    };
    std::array<Head, 2> heads;
    std::vector<Segment> segments;
    std::optional<ClipTempo> timing;
    double start = 0, offset = 0, speed = 1, duration = 0, loopStart = 0, loopLength = 0,
           sampleRate = 48000, preparedPitchRate = 0;
    bool read(AudioFormatReader &reader, AudioBuffer<float> &scratch, AudioBuffer<float> &output,
              int target, double local, int count) {
        bool ok = true;
        int done = 0;
        while (done < count) {
            const double now = local + done / sampleRate;
            if (now >= duration) {
                output.clear(target + done, count - done);
                break;
            }
            const auto *span = timing ? timing->at(start + now) : nullptr;
            const double rate = span ? span->rate : speed;
            const double step = reader.sampleRate / sampleRate * rate;
            const double boundary = span ? std::min(duration, span->end - start) : duration;
            int frames = std::min(
                {512, count - done, std::max(1, (int)((scratch.getNumSamples() - 2) / step)),
                 std::max(1, (int)std::ceil((boundary - now) * sampleRate - 1e-7))});
            double source = timing ? timing->sourceAt(start + now) : offset + now * speed;
            if (loopLength > 0 && source >= loopStart) {
                source = loopStart + std::fmod(source - loopStart, loopLength);
                frames =
                    std::min(frames, std::max(1, (int)std::ceil((loopStart + loopLength - source) /
                                                                    rate * sampleRate -
                                                                1e-7)));
            }
            const double frame = source * reader.sampleRate;
            const int64 first = (int64)std::floor(frame);
            const int needed = (int)std::ceil(frames * step) + 2;
            if (needed > scratch.getNumSamples()) {
                output.clear(target + done, frames);
                ok = false;
                done += frames;
                continue;
            }
            scratch.clear(0, needed);
            if (!reader.read(&scratch, 0, needed, first, true, true))
                ok = false;
            for (int ch = 0; ch < 2; ++ch) {
                auto *dest = output.getWritePointer(ch, target + done);
                const auto *data = scratch.getReadPointer(reader.numChannels > 1 ? ch : 0);
                for (int n = 0; n < frames; ++n) {
                    const double position = frame - first + n * step;
                    const int index = (int)position;
                    dest[n] =
                        data[index] + (float)(position - index) * (data[index + 1] - data[index]);
                }
            }
            done += frames;
        }
        return ok;
    }
};
} // namespace catlive
