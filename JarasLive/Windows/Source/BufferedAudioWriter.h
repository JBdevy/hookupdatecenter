#pragma once
#include "Common.h"
#include "../../Core/Audio/RealtimePCMQueue.hpp"
#include <array>

namespace catlive {
// The device callback only copies PCM into preallocated memory. The disk thread
// polls independently, avoiding one OS wakeup per track per audio callback.
// Lifetime: detach the producer first; destruction joins this disk client and
// drains its remaining PCM before destroying/finalizing the underlying writer.
class BufferedAudioWriter final : private TimeSliceClient {
public:
    BufferedAudioWriter(std::unique_ptr<AudioFormatWriter> writer, TimeSliceThread& thread,
                        std::size_t capacity = 131072)
        : writer_(std::move(writer)), thread_(thread),
          queue_(writer_ ? writer_->getNumChannels() : 0, capacity) {
        thread_.addTimeSliceClient(this);
    }
    ~BufferedAudioWriter() override { finish(); }
    bool write(const float* const* data, int frames) noexcept {
        return frames >= 0 && !finished_.load(std::memory_order_relaxed) && !failed_.load(std::memory_order_relaxed) &&
               queue_.push(data, std::size_t(frames));
    }
    bool failed() const noexcept { return failed_.load(std::memory_order_relaxed); }
    // Control only, after capture detaches. Also finalizes InputWriter tails and
    // container headers here, so callers can inspect failure before disposal.
    void finish() noexcept {
        if (!writer_) return;
        finished_.store(true, std::memory_order_relaxed);
        thread_.removeTimeSliceClient(this);
        while (drain()) {}
        try { writer_->flush(); } catch (...) { failed_.store(true); }
        writer_.reset();
    }
private:
    int useTimeSlice() override { return drain() ? 0 : 5; }
    bool drain() noexcept {
        std::array<const float*, 129> planes{};
        const auto count = queue_.peek(planes.data(), 4096);
        if (count == 0) return false;
        if (!failed()) {
            try {
                if (!writer_->writeFromFloatArrays(planes.data(), int(queue_.channels()), int(count)))
                    failed_.store(true, std::memory_order_relaxed);
            } catch (...) { failed_.store(true, std::memory_order_relaxed); }
        }
        queue_.consume(count);
        return true;
    }
    std::unique_ptr<AudioFormatWriter> writer_;
    TimeSliceThread& thread_;
    audio::RealtimePCMQueue queue_;
    std::atomic<bool> failed_{false};
    std::atomic<bool> finished_{false};
};
} // namespace catlive
