#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <complex>
#include <cstddef>
#include <cstdint>

namespace catlive::analysis {
inline constexpr std::size_t sampleCount = 2048, binCount = 384;
inline constexpr float minimumDB = -96.f, maximumDB = 12.f;
struct Frame {
    std::array<std::array<float, sampleCount>, 2> input{}, output{};
    double sampleRate = 48000;
    std::uint64_t serial = 0;
};

// One render producer, any number of editor readers. The callback never waits,
// allocates, or computes an FFT. No samples are copied while all editors close.
// Atomic samples make a concurrent rejected snapshot legal under the C++ model.
class Capture {
public:
    explicit Capture(double rate) : rate_(rate) {
        for (auto *side : {&input_, &output_})
            for (auto &channel : *side) for (auto &sample : channel) sample.store(0, std::memory_order_relaxed);
    }
    void addReader() noexcept { readers_.fetch_add(1, std::memory_order_relaxed); }
    void removeReader() noexcept { readers_.fetch_sub(1, std::memory_order_relaxed); }
    double sampleRate() const noexcept { return rate_; }
    std::uint64_t serial() const noexcept { return revision_.load(std::memory_order_acquire); }
    bool begin(const float *left, const float *right, int frames) noexcept {
        if (!left || frames <= 0 || readers_.load(std::memory_order_relaxed) == 0) return false;
        revision_.fetch_add(1, std::memory_order_acq_rel);
        pendingFrames_ = static_cast<unsigned>(frames);
        copy(input_, left, right, pendingFrames_);
        return true;
    }
    void finish(const float *left, const float *right) noexcept {
        copy(output_, left, right, pendingFrames_);
        write_ = (write_ + pendingFrames_) % sampleCount;
        publishedWrite_.store(write_, std::memory_order_relaxed);
        revision_.fetch_add(1, std::memory_order_release);
    }
    bool read(Frame &frame) const noexcept {
        for (int attempt = 0; attempt != 3; ++attempt) {
            const auto serial = revision_.load(std::memory_order_acquire);
            if (!serial || (serial & 1)) continue;
            const auto start = publishedWrite_.load(std::memory_order_relaxed);
            for (std::size_t channel = 0; channel != 2; ++channel)
                for (std::size_t n = 0; n != sampleCount; ++n) {
                    const auto index = (start + n) % sampleCount;
                    frame.input[channel][n] = input_[channel][index].load(std::memory_order_relaxed);
                    frame.output[channel][n] = output_[channel][index].load(std::memory_order_relaxed);
                }
            std::atomic_thread_fence(std::memory_order_acquire);
            if (revision_.load(std::memory_order_relaxed) == serial) {
                frame.serial = serial; frame.sampleRate = rate_; return true;
            }
        }
        return false;
    }
private:
    static_assert(std::atomic<float>::is_always_lock_free, "RTA samples must be lock-free");
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free, "RTA publication must be lock-free");
    using Ring = std::array<std::array<std::atomic<float>, sampleCount>, 2>;
    Ring input_{}, output_{};
    const double rate_;
    std::atomic<unsigned> readers_{0}, publishedWrite_{0};
    std::atomic<std::uint64_t> revision_{0};
    unsigned write_ = 0, pendingFrames_ = 0;
    void copy(Ring &ring, const float *left, const float *right, unsigned frames) noexcept {
        if (!right) right = left;
        const auto first = frames > sampleCount ? frames - static_cast<unsigned>(sampleCount) : 0;
        for (auto n = first; n < frames; ++n) {
            const auto index = (write_ + n) % sampleCount;
            ring[0][index].store(std::isfinite(left[n]) ? left[n] : 0.f, std::memory_order_relaxed);
            ring[1][index].store(std::isfinite(right[n]) ? right[n] : 0.f, std::memory_order_relaxed);
        }
    }
};

struct Spectrum {
    std::array<float, binCount> input{}, output{};
    Spectrum() { input.fill(minimumDB); output.fill(minimumDB); }
    static double frequency(std::size_t bin) { return 20 * std::pow(1000., double(bin) / double(binCount - 1)); }
};

// Portable fixed-size FFT; no dependency on the UI toolkit. Called by an open
// editor at 20 Hz, never by an audio callback. Match the Mac log-frequency bins,
// stereo power sum, two Gaussian passes and 72 dB/s falling peak display.
class Analyzer {
public:
    Analyzer() {
        constexpr double pi = 3.14159265358979323846;
        for (std::size_t n = 0; n < sampleCount; ++n) {
            window_[n] = float(.5 - .5 * std::cos(2 * pi * double(n) / double(sampleCount)));
            unsigned reversed = 0, value = static_cast<unsigned>(n);
            for (unsigned bit = 0; bit < 11; ++bit) { reversed = (reversed << 1) | (value & 1); value >>= 1; }
            reversed_[n] = reversed;
        }
        for (std::size_t n = 0; n < sampleCount / 2; ++n)
            twiddles_[n] = std::polar(1.f, float(-2 * pi * double(n) / double(sampleCount)));
    }
    Spectrum analyze(const Frame *frames, std::size_t count, double elapsed = .05) {
        std::array<float, binCount> input{}, output{};
        for (std::size_t i = 0; i < count; ++i) {
            accumulate(frames[i].input, frames[i].sampleRate, input);
            accumulate(frames[i].output, frames[i].sampleRate, output);
        }
        const auto fall = float(std::clamp(std::isfinite(elapsed) ? elapsed : 0., 0., .25) * 72);
        for (std::size_t i = 0; i < binCount; ++i) {
            auto update = [fall](float power, float previous) {
                const auto db = std::clamp(10.f * std::log10(std::max(1.e-12f, power)), minimumDB, maximumDB);
                return db >= previous ? db : std::max(db, previous - fall);
            };
            current_.input[i] = update(input[i], current_.input[i]);
            current_.output[i] = update(output[i], current_.output[i]);
        }
        auto display = current_; smooth(display.input); smooth(display.output); return display;
    }
    void reset() { current_ = Spectrum{}; }
private:
    Spectrum current_;
    std::array<float, sampleCount> window_{};
    std::array<unsigned, sampleCount> reversed_{};
    std::array<std::complex<float>, sampleCount> work_{};
    std::array<std::complex<float>, sampleCount / 2> twiddles_{};
    void accumulate(const std::array<std::array<float, sampleCount>, 2> &channels, double rate,
                    std::array<float, binCount> &levels) {
        if (!std::isfinite(rate) || rate < 8000) return;
        for (const auto &channel : channels) {
            for (std::size_t n = 0; n < sampleCount; ++n) work_[reversed_[n]] = {channel[n] * window_[n], 0};
            for (std::size_t width = 2; width <= sampleCount; width *= 2) {
                const auto half = width / 2, step = sampleCount / width;
                for (std::size_t start = 0; start < sampleCount; start += width)
                    for (std::size_t n = 0; n < half; ++n) {
                        const auto a = work_[start + n], b = work_[start + n + half] * twiddles_[n * step];
                        work_[start + n] = a + b; work_[start + n + half] = a - b;
                    }
            }
            for (std::size_t bin = 0; bin < binCount; ++bin) {
                const auto frequency = Spectrum::frequency(bin);
                if (frequency >= rate / 2) continue;
                const auto position = std::clamp(frequency * double(sampleCount) / rate, 1., double(sampleCount / 2 - 1));
                const auto lower = static_cast<std::size_t>(position), upper = std::min(sampleCount / 2 - 1, lower + 1);
                const float fraction = float(position - double(lower));
                const auto a = std::norm(work_[lower]), b = std::norm(work_[upper]);
                const auto power = (a + (b - a) * fraction) * (8.f / float(sampleCount * sampleCount));
                if (std::isfinite(power)) levels[bin] += std::max(0.f, power);
            }
        }
    }
    static void smooth(std::array<float, binCount> &levels) {
        constexpr std::array<float, 7> weights{1, 6, 15, 20, 15, 6, 1};
        for (int pass = 0; pass != 2; ++pass) {
            const auto previous = levels;
            for (int n = 0; n < int(binCount); ++n) {
                float sum = 0;
                for (int offset = 0; offset != 7; ++offset)
                    sum += previous[std::size_t(std::clamp(n + offset - 3, 0, int(binCount) - 1))] * weights[std::size_t(offset)];
                levels[std::size_t(n)] = sum / 64;
            }
        }
    }
};
}
