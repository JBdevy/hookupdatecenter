#pragma once
#include "RegionPitch.h"
#include "../ThirdParty/Signalsmith/signalsmith-stretch.h"
namespace catlive {
// Streaming clip pitch/rate/loop processing. Input lookahead removes the spectral
// algorithm's latency from the timeline; seeking and Sub Play have independent state.
class ClipAudio {
  public:
    ClipAudio(const jaras::Song &song, const jaras::Track &track, const jaras::AudioClip &clip,
              double rate)
        : offset(clip.sourceOffset), speed(clip.playbackRate), duration(clip.duration),
          loopStart(clip.loopStart.value_or(0)), loopLength(clip.loopLength.value_or(0)) {
        std::vector<double> bounds{0, duration};
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
                                clip.pitchSemitones.value_or(0) + region - 12 * std::log2(speed)});
        }
        prepare(rate);
    }
    static bool needed(const jaras::Song &song, const jaras::Track &track,
                       const jaras::AudioClip &clip) {
        if (clip.loopLength || std::abs(clip.playbackRate - 1) > 1e-9 ||
            clip.pitchSemitones.value_or(0) != 0)
            return true;
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
        for (auto &head : heads) {
            head.pitch.presetDefault(2, (float)rate);
            head.input.setSize(2, std::max(4096, head.pitch.outputSeekLength(1.f)));
            head.input.clear();
            head.pitch.outputSeek(head.input.getArrayOfReadPointers(),
                                  head.pitch.outputSeekLength(1.f));
            head.next = -1;
        }
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
    double offset, speed, duration, loopStart, loopLength, sampleRate = 48000;
    bool read(AudioFormatReader &reader, AudioBuffer<float> &scratch, AudioBuffer<float> &output,
              int target, double local, int count) {
        bool ok = true;
        int done = 0;
        const double step = reader.sampleRate / sampleRate * speed;
        while (done < count) {
            const double now = local + done / sampleRate;
            if (now >= duration) {
                output.clear(target + done, count - done);
                break;
            }
            int frames = std::min(
                {512, count - done, std::max(1, (int)((scratch.getNumSamples() - 2) / step)),
                 std::max(1, (int)std::ceil((duration - now) * sampleRate - 1e-7))});
            double source = offset + now * speed;
            if (loopLength > 0 && source >= loopStart) {
                source = loopStart + std::fmod(source - loopStart, loopLength);
                frames =
                    std::min(frames, std::max(1, (int)std::ceil((loopStart + loopLength - source) /
                                                                    speed * sampleRate -
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
