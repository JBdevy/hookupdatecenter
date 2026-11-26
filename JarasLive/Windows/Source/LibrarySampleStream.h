#pragma once
#include "RealtimeBufferedReader.h"

namespace catlive {
class LibrarySampleStream final {
  public:
    static std::shared_ptr<LibrarySampleStream> open(const File &file) {
        AudioFormatManager formats;
        formats.registerBasicFormats();
        std::unique_ptr<AudioFormatReader> source(formats.createReaderFor(file));
        if (!source || source->lengthInSamples <= 0 || source->numChannels == 0 ||
            !std::isfinite(source->sampleRate) || source->sampleRate <= 0)
            throw std::runtime_error("Could not read the sample audio.");
        auto stream = std::shared_ptr<LibrarySampleStream>(new LibrarySampleStream(std::move(source)));
        stream->reader.setReadTimeout(1500);
        const bool ready = stream->reader.readSamples(nullptr, 0, 0, 0,
            int(std::min<int64>(bufferFrames, stream->reader.lengthInSamples)));
        stream->reader.setReadTimeout(0);
        if (!ready) throw std::runtime_error("Could not read the sample audio.");
        return stream;
    }

    // The render thread only reads prepared pages. A cache miss keeps the
    // cursor at the first unread frame so slower disks cannot drop audio.
    bool mix(AudioBuffer<float> &output, int frames, double rate, float gain) {
        const auto length = reader.lengthInSamples;
        const double step = reader.sampleRate / rate;
        if (!std::isfinite(step) || step <= 0) return true;
        const auto channels = std::min(2, output.getNumChannels());
        const int blockLimit = int(std::clamp(std::floor((bufferFrames - 2) / step), 1., double(bufferFrames)));
        int* targets[] {reinterpret_cast<int*>(buffer.getWritePointer(0)),
                        reinterpret_cast<int*>(buffer.getWritePointer(1))};
        for (int done = 0; done < frames && position < length;) {
            const int count = int(std::min(double(std::min(blockLimit, frames - done)), std::ceil((length - position) / step)));
            const auto first = int64(position);
            const auto last = int64(position + (count - 1) * step);
            const auto needed = int(std::min(length - first, last - first + 2));
            if (!reader.readSamples(targets, inputChannels, 0, first, needed)) return false;
            for (int ch = 0; ch < channels; ++ch) {
                const auto *pcm = buffer.getReadPointer(std::min(ch, inputChannels - 1));
                auto *destination = output.getWritePointer(ch, done);
                auto read = position - first;
                for (int frame = 0; frame < count; ++frame, read += step) {
                    const auto a = std::min(int(read), needed - 1);
                    const auto b = std::min(a + 1, needed - 1);
                    destination[frame] += (pcm[a] + (pcm[b] - pcm[a]) * float(read - a)) * gain;
                }
            }
            position += count * step;
            done += count;
        }
        return position >= length;
    }

  private:
    static constexpr int bufferFrames = 4096;
    TimeSliceThread worker{"CatLive library sample read-ahead"};
    const int inputChannels;
    RealtimeBufferedReader reader;
    AudioBuffer<float> buffer{2, bufferFrames};
    double position = 0;

    explicit LibrarySampleStream(std::unique_ptr<AudioFormatReader> source)
        : inputChannels(std::min(2u, source->numChannels)), reader(source.release(), worker, 65536) {
        worker.startThread(Thread::Priority::high);
    }
};
}
