#pragma once
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>

namespace catlive::audio {
// One realtime producer, one disk consumer. Storage is fixed before capture.
// A publication contains all channels of a complete block; a full queue rejects
// the whole block. No notification/syscall, allocation or retry on either side.
// Destroy only after the producer has stopped and the consumer has joined.
class RealtimePCMQueue final {
public:
    RealtimePCMQueue(std::size_t channels, std::size_t capacity)
        : channels_(channels), capacity_(capacity), mask_(capacity - 1),
          samples_(checkedSize(channels, capacity), 0.f) {}
    RealtimePCMQueue(const RealtimePCMQueue&) = delete;
    RealtimePCMQueue& operator=(const RealtimePCMQueue&) = delete;

    bool push(const float* const* data, std::size_t frames) noexcept {
        if (frames == 0) return true;
        const auto write = written_.load(std::memory_order_relaxed);
        const auto read = read_.load(std::memory_order_acquire);
        if (frames > capacity_ || write - read > capacity_ - frames) return false;
        const auto offset = std::size_t(write) & mask_;
        const auto first = std::min(frames, capacity_ - offset);
        for (std::size_t channel = 0; channel < channels_; ++channel) {
            auto* destination = samples_.data() + channel * capacity_;
            const auto* source = data ? data[channel] : nullptr;
            if (source) {
                std::copy_n(source, first, destination + offset);
                std::copy_n(source + first, frames - first, destination);
            } else {
                std::fill_n(destination + offset, first, 0.f);
                std::fill_n(destination, frames - first, 0.f);
            }
        }
        written_.store(write + frames, std::memory_order_release);
        return true;
    }
    // Consumer-only. Returned planes remain valid until consume(). A wrap is
    // exposed as two separate reads, so no extra copy or scratch is required.
    std::size_t peek(const float** planes, std::size_t maximum) const noexcept {
        const auto read = read_.load(std::memory_order_relaxed);
        const auto write = written_.load(std::memory_order_acquire);
        const auto offset = std::size_t(read) & mask_;
        const auto count = std::min({std::size_t(write - read), capacity_ - offset, maximum});
        for (std::size_t channel = 0; channel < channels_; ++channel)
            planes[channel] = samples_.data() + channel * capacity_ + offset;
        return count;
    }
    void consume(std::size_t frames) noexcept {
        const auto read = read_.load(std::memory_order_relaxed);
        assert(frames <= written_.load(std::memory_order_acquire) - read);
        read_.store(read + frames, std::memory_order_release);
    }
    std::size_t channels() const noexcept { return channels_; }
private:
    static std::size_t checkedSize(std::size_t channels, std::size_t capacity) {
        if (channels == 0 || channels > 128 || capacity < 2 || (capacity & (capacity - 1)) != 0 ||
            capacity > std::numeric_limits<std::size_t>::max() / channels)
            throw std::invalid_argument("Invalid preallocated PCM queue dimensions");
        return channels * capacity;
    }
    const std::size_t channels_, capacity_, mask_;
    std::vector<float> samples_;
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free, "PCM counters must be lock-free");
    alignas(64) std::atomic<std::uint64_t> written_{0};
    alignas(64) std::atomic<std::uint64_t> read_{0};
};
} // namespace catlive::audio
