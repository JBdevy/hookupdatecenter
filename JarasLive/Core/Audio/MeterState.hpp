#pragma once
#include <array>
#include <atomic>
#include <cmath>

namespace catlive::audio {
// Independent of the renderer, DSP graph and device backend. The control
// thread owns lifetime; the audio callback only accesses the atomic payload.
static_assert(std::atomic<float>::is_always_lock_free,
              "Meter publication requires lock-free float atomics");
class PeakHold {
    std::atomic<float> maximum{0};
public:
    void record(float amplitude) noexcept {
        if (!std::isfinite(amplitude) || amplitude < std::pow(10.f, -24.f / 20)) return;
        auto previous = maximum.load(std::memory_order_relaxed);
        while (amplitude > previous && !maximum.compare_exchange_weak(
                   previous, amplitude, std::memory_order_relaxed)) {}
    }
    float amplitude() const noexcept { return maximum.load(std::memory_order_relaxed); }
    void clear() noexcept { maximum.store(0, std::memory_order_relaxed); }
};
struct TrackMeterState {
    std::atomic<float> peak{0};
    PeakHold held;
    std::array<std::atomic<float>, 2> levels{};
    std::atomic<float> fxInput{0}, fxOutput{0};
};
}
