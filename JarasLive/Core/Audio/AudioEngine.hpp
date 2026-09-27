#pragma once
#include <cstdint>
namespace jaras {
struct AudioFormat { double sampleRate = 48000; uint32_t maximumFrames = 512, outputChannels = 2; };
struct AudioBlock { float* const* outputs; uint32_t channels, frames; };
class AudioEngine {
public:
    virtual ~AudioEngine() = default;
    // Control thread: allocate, open files/devices and prepare buffers here.
    virtual void prepare(const AudioFormat&) = 0;
    virtual void start() = 0;
    virtual void stop() = 0;
    // Real-time thread: no locks, allocation, filesystem, UI, backend or networking.
    virtual void render(AudioBlock block) noexcept = 0;
};
}
