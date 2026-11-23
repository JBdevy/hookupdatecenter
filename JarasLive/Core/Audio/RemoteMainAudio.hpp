#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <vector>

namespace jaras::audio {

// One render producer and one transport consumer. No socket operations,
// locks or allocation on the audio thread. PCM is signed stereo 16-bit LE.
class RemoteMainAudio {
public:
    static constexpr unsigned framesPerPacket = 2048;

    void setEnabled(bool enabled) {
        if (enabled == enabled_.load(std::memory_order_relaxed)) return;
        ++generation_;
        read_.store(written_.load(std::memory_order_acquire), std::memory_order_release);
        enabled_.store(enabled, std::memory_order_release);
    }

    void push(const float* left, const float* right, unsigned frames, unsigned rate) noexcept {
        if (!enabled_.load(std::memory_order_acquire) || !left || !right || rate < 8000 || rate > 192000) return;
        const auto generation = generation_.load(std::memory_order_relaxed);
        auto next = written_.load(std::memory_order_relaxed);
        while (frames && next - read_.load(std::memory_order_acquire) < slots_.size()) {
            if (generation != generation_.load(std::memory_order_relaxed)) return;
            auto &slot = slots_[next % slots_.size()];
            const auto count = std::min(frames, framesPerPacket);
            slot.rate = rate;
            slot.frames = count;
            slot.generation = generation;
            for (unsigned i = 0; i < count; ++i) {
                writeSample(slot.pcm.data() + i * 4, left[i]);
                writeSample(slot.pcm.data() + i * 4 + 2, right[i]);
            }
            written_.store(++next, std::memory_order_release);
            left += count;
            right += count;
            frames -= count;
        }
    }

    std::vector<std::uint8_t> pop() {
        auto next = read_.load(std::memory_order_relaxed);
        const auto end = written_.load(std::memory_order_acquire);
        while (next != end) {
            const auto &slot = slots_[next % slots_.size()];
            std::vector<std::uint8_t> payload;
            if (slot.generation == generation_.load(std::memory_order_relaxed)) {
                payload.reserve(4 + slot.frames * 4);
                for (unsigned i = 0; i < 4; ++i) payload.push_back(std::uint8_t(slot.rate >> (i * 8)));
                payload.insert(payload.end(), slot.pcm.begin(), slot.pcm.begin() + slot.frames * 4);
            }
            read_.store(++next, std::memory_order_release);
            if (!payload.empty()) return payload;
        }
        return {};
    }

private:
    struct Slot {
        unsigned rate = 0, frames = 0;
        std::uint32_t generation = 0;
        std::array<std::uint8_t, framesPerPacket * 4> pcm{};
    };
    std::array<Slot, 64> slots_{};
    std::atomic<bool> enabled_{false};
    std::atomic<std::uint32_t> generation_{0}, read_{0}, written_{0};

    static void writeSample(std::uint8_t* destination, float sample) noexcept {
        const auto bits = std::uint16_t(std::int16_t(std::clamp(std::isfinite(sample) ? sample : 0.f, -1.f, 1.f) * 32767.f));
        destination[0] = std::uint8_t(bits);
        destination[1] = std::uint8_t(bits >> 8);
    }
};

}
