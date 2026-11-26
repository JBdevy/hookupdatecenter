#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>

namespace jaras::audio {
// Preallocated output history: Stop must not synthesize a DC decay from one
// sample, allocate, read a file or prepare DSP on the callback/UI thread.
class StopTransition {
    static constexpr unsigned channels = 128, capacity = 1024;
    using History = std::array<std::array<float, capacity>, channels>;
    std::unique_ptr<History> history = std::make_unique<History>();
    unsigned write = 0, count = 0, origin = 0, available = 0, length = 0, position = 0;
public:
    void begin(double rate) noexcept {
        length = std::clamp(unsigned(std::max(1., std::isfinite(rate) ? rate * .002 : 96.)), 1u, capacity);
        position = 0; origin = write; available = count;
    }
    void cancel() noexcept { position = length; }
    void process(float *const *output, unsigned channelCount, unsigned frames) noexcept {
        for (unsigned channel = 0; channel < std::min(channels, channelCount); ++channel) {
            auto *samples = output[channel];
            if (!samples) continue;
            for (unsigned frame = 0; frame < frames; ++frame) {
                const unsigned age = position + frame;
                if (age < length) {
                    const float mix = float(age + 1) / length;
                    const float tail = age < available ? (*history)[channel][(origin + capacity - 1 - age) % capacity] : 0;
                    samples[frame] = tail * (1 - mix) * (1 - mix) + samples[frame] * (1 - (1 - mix) * (1 - mix));
                }
            }
        }
        // Read the complete transition before replacing any history slot.
        for (unsigned channel = 0; channel < std::min(channels, channelCount); ++channel)
            for (unsigned frame = frames - std::min(frames, capacity); frame < frames; ++frame)
                (*history)[channel][(write + frame) % capacity] = output[channel] ? output[channel][frame] : 0;
        write = (write + frames) % capacity; count = std::min(capacity, count + frames);
        position = std::min(length, position + frames);
    }
};
}