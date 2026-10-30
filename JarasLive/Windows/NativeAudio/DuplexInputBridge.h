#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>

namespace catlive::native::audio {
// One capture producer and one render consumer. Device clocks are independent:
// the output clock owns the graph; this prepared, band-limited ring follows it.
// Construction/reset/destruction require both device callbacks to be stopped.
class DuplexInputBridge final {
public:
    struct Configuration {
        unsigned channels = 0, maximumCaptureFrames = 0, maximumRenderFrames = 0;
        unsigned capturePeriodFrames = 0, renderPeriodFrames = 0;
        double captureRate = 0, renderRate = 0;
    };
    struct Result { unsigned frames = 0; bool waiting = false, discontinuity = false; };
    struct Statistics { std::uint64_t captured, rendered, overflows, underruns, discontinuities; double ratio; };
    explicit DuplexInputBridge(Configuration c) : config(c) {
        if (!c.channels || c.channels > 128 || !c.maximumCaptureFrames || c.maximumCaptureFrames > 65536 ||
            !c.maximumRenderFrames || c.maximumRenderFrames > 65536 ||
            !c.capturePeriodFrames || c.capturePeriodFrames > c.maximumCaptureFrames ||
            !c.renderPeriodFrames || c.renderPeriodFrames > c.maximumRenderFrames ||
            !std::isfinite(c.captureRate) || !std::isfinite(c.renderRate) ||
            c.captureRate < 8000 || c.captureRate > 384000 || c.renderRate < 8000 || c.renderRate > 384000)
            throw std::invalid_argument("Invalid native duplex input dimensions");
        nominalRatio = c.captureRate / c.renderRate;
        // Reserve a complete worst-case render block plus capture jitter and
        // sinc lookahead. An underrun is explicit; old input is never repeated.
        target = unsigned(std::ceil(std::max(double(c.capturePeriodFrames) * 2,
            double(c.maximumRenderFrames) * nominalRatio))) + taps;
        capacity = 1;
        while (capacity < target * 4u + c.maximumCaptureFrames) capacity <<= 1u;
        if (std::uint64_t(capacity) * c.channels > 32u * 1024u * 1024u)
            throw std::invalid_argument("Native duplex input storage exceeds prepared limits");
        mask = capacity - 1;
        samples.resize(std::size_t(capacity) * c.channels);
        coefficients.resize((phases + 1) * taps);
        const double cutoff = .95 * std::min(1., 1. / (nominalRatio * 1.001));
        constexpr double pi = 3.14159265358979323846;
        for (unsigned phase = 0; phase <= phases; ++phase) {
            double sum = 0;
            for (unsigned tap = 0; tap < taps; ++tap) {
                const double distance = double(tap) - (half - 1) - double(phase) / phases;
                const double x = pi * cutoff * distance;
                const double window = std::abs(distance) >= half ? 0. :
                    .42 + .5 * std::cos(pi * distance / half) + .08 * std::cos(2 * pi * distance / half);
                const double value = cutoff * (std::abs(x) < 1.e-12 ? 1. : std::sin(x) / x) * window;
                coefficients[std::size_t(phase) * taps + tap] = float(value); sum += value;
            }
            for (unsigned tap = 0; tap < taps; ++tap) coefficients[std::size_t(phase) * taps + tap] /= float(sum);
        }
        reset();
    }
    void reset() noexcept {
        read.store(0); write.store(0); gap.store(0); seenGap = 0;
        position = 0; fraction = 0; primed = false; filteredError = 0; correction = 0;
        captured.store(0); rendered.store(0); overflows.store(0); underruns.store(0); gaps.store(0);
        currentRatio.store(nominalRatio);
    }
    bool push(const float* const* input, unsigned frames, bool discontinuity = false) noexcept {
        if (!frames) return true;
        const auto end = write.load(std::memory_order_relaxed);
        const auto begin = read.load(std::memory_order_acquire);
        if (frames > config.maximumCaptureFrames || end - begin > capacity || frames > capacity - (end - begin)) {
            overflows.fetch_add(1, std::memory_order_relaxed); gap.fetch_add(1, std::memory_order_release); return false;
        }
        for (unsigned channel = 0; channel < config.channels; ++channel) {
            auto* plane = samples.data() + std::size_t(channel) * capacity;
            const auto* source = input ? input[channel] : nullptr;
            const unsigned start = unsigned(end) & mask, first = std::min(frames, capacity - start);
            if (source) {
                std::copy_n(source, first, plane + start); std::copy_n(source + first, frames - first, plane);
            } else {
                std::fill_n(plane + start, first, 0.f); std::fill_n(plane, frames - first, 0.f);
            }
        }
        if (discontinuity) { gaps.fetch_add(1, std::memory_order_relaxed); gap.fetch_add(1, std::memory_order_release); }
        write.store(end + frames, std::memory_order_release);
        captured.fetch_add(frames, std::memory_order_relaxed);
        return true;
    }
    Result pull(float* const* output, unsigned frames) noexcept {
        Result result;
        if (!output || frames > config.maximumRenderFrames) { result.discontinuity = true; return result; }
        for (unsigned channel = 0; channel < config.channels; ++channel) if (output[channel]) std::fill_n(output[channel], frames, 0.f);
        auto end = write.load(std::memory_order_acquire);
        const auto generation = gap.load(std::memory_order_acquire);
        if (generation != seenGap) {
            seenGap = generation; primed = false; filteredError = correction = 0;
            read.store(end, std::memory_order_release); result.discontinuity = true;
        }
        const auto begin = read.load(std::memory_order_relaxed);
        if (!primed) {
            if (end - begin < target) { result.waiting = true; return result; }
            position = end - target + half - 1; fraction = 0; primed = true;
        }
        // Slow occupancy feedback rejects packet-sized jitter. Limit frequency
        // correction to 500 ppm and slew it over time to avoid pitch steps.
        const double dt = double(frames) / config.renderRate;
        const double error = double(end - position) - (target - half + 1);
        filteredError += (error - filteredError) * std::min(1., dt / 2.);
        const double desired = std::clamp(filteredError / (config.captureRate * 5.), -.0005, .0005);
        correction += std::clamp(desired - correction, -dt * .0001, dt * .0001);
        const double ratio = nominalRatio * (1. + correction);
        currentRatio.store(ratio, std::memory_order_relaxed);
        for (unsigned frame = 0; frame < frames; ++frame) {
            if (position + half >= end) {
                underruns.fetch_add(1, std::memory_order_relaxed);
                result.discontinuity = true; result.waiting = true;
                primed = false; filteredError = correction = 0;
                read.store(end, std::memory_order_release); break;
            }
            const double phasePosition = fraction * phases;
            const unsigned phase = std::min(phases - 1, unsigned(phasePosition));
            const float mix = float(phasePosition - phase);
            const auto* a = coefficients.data() + std::size_t(phase) * taps;
            const auto* b = a + taps;
            const auto start = position - (half - 1);
            for (unsigned channel = 0; channel < config.channels; ++channel) if (output[channel]) {
                const auto* plane = samples.data() + std::size_t(channel) * capacity;
                float value = 0;
                for (unsigned tap = 0; tap < taps; ++tap)
                    value += plane[unsigned(start + tap) & mask] * (a[tap] + mix * (b[tap] - a[tap]));
                output[channel][frame] = std::isfinite(value) ? value : 0.f;
            }
            fraction += ratio;
            const auto advance = std::uint64_t(fraction);
            fraction -= double(advance); position += advance;
            ++result.frames;
        }
        if (primed) read.store(position - (half - 1), std::memory_order_release);
        rendered.fetch_add(result.frames, std::memory_order_relaxed);
        return result;
    }
    unsigned preparedLatencyFrames() const noexcept { return target - half + 1; }
    unsigned capacityFrames() const noexcept { return capacity; }
    Statistics statistics() const noexcept {
        return {captured.load(),rendered.load(),overflows.load(),underruns.load(),gaps.load(),currentRatio.load()};
    }
private:
    static constexpr unsigned taps = 64, half = taps / 2, phases = 1024;
    Configuration config;
    unsigned capacity = 0, mask = 0, target = 0;
    double nominalRatio = 1, fraction = 0, filteredError = 0, correction = 0;
    std::uint64_t position = 0, seenGap = 0;
    bool primed = false;
    std::vector<float> samples, coefficients;
    alignas(64) std::atomic<std::uint64_t> read{0};
    alignas(64) std::atomic<std::uint64_t> write{0}, gap{0};
    std::atomic<std::uint64_t> captured{0}, rendered{0}, overflows{0}, underruns{0}, gaps{0};
    std::atomic<double> currentRatio{1};
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
    static_assert(std::atomic<double>::is_always_lock_free);
};
} // namespace catlive::native::audio
