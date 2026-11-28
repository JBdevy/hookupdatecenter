#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>

namespace catlive::audio {
inline constexpr double meterReleaseSeconds = 3.;
inline float meterReleaseFactor(double elapsed, double scaleDB = 60.) noexcept {
    return static_cast<float>(std::pow(10., -scaleDB * std::max(0., elapsed) / (20. * meterReleaseSeconds)));
}
inline float releasedMeterLevel(float previous, float input, float factor, float floor = .001f) noexcept {
    const auto level = std::max(std::isfinite(input) ? input : 0.f, previous * factor);
    return level < floor ? 0.f : level;
}
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
// Full-wave rectifier used only by the VU display, independent of peak metering.
inline float meanMagnitude(const float *samples, int count) noexcept {
    if (count <= 0) return 0;
    float sum = 0;
    for (int i = 0; i < count; ++i) sum += std::abs(samples[i]);
    return sum / count;
}

class AnalogVU {
    double displacement = 0, velocity = 0, displayed = -20.;
public:
    float update(double mean, double elapsed) noexcept {
        if (std::isfinite(elapsed) && elapsed > 0) {
            const auto input = std::isfinite(mean) ? std::max(0., mean) : 0.;
            // 99% step response in 300 ms, 1.25% overshoot of the pointer.
            constexpr double damping = 10.981360858709374, frequency = 7.872832704200884;
            const auto phase = frequency * elapsed;
            const auto cosine = std::cos(phase), sine = std::sin(phase) / frequency;
            const auto decay = std::exp(-damping * elapsed), error = displacement - input;
            displacement = input + decay * (error * (cosine + damping * sine) + velocity * sine);
            velocity = decay * (velocity * (cosine - damping * sine)
                - error * (damping * damping + frequency * frequency) * sine);
        }
        // Mean absolute level of a sine whose peak is -18 dBFS.
        constexpr double reference = 0.08014568090841664;
        const auto target = std::clamp(20 * std::log10(std::max(.000001, displacement) / reference), -20., 3.);
        if (std::isfinite(elapsed) && elapsed > 0.)
            displayed = std::max(target, displayed - 20. / meterReleaseSeconds * elapsed);
        return float(std::round(displayed * 10.) / 10.);
    }
};
struct TrackMeterState {
    std::atomic<float> peak{0};
    std::atomic<float> vuMean{0};
    PeakHold held;
    std::array<std::atomic<float>, 2> levels{};
    std::atomic<float> fxInput{0}, fxOutput{0}, gainReduction{-1};
};
}
