#pragma once
#include <atomic>
#include <cstdint>
#include <algorithm>

namespace catlive {
// Control-thread start is serialized with the device callback by AudioEngine.
// Cancel is atomic and can race a callback. A generation and remaining frames
// travel in one word so a stale callback cannot revive a cancelled/restarted fade.
class TransportFadeout final {
public:
    struct Block {
        uint64_t state = 0;
        uint32_t remaining = 0, total = 0;
        bool active = false;
        float gain(uint32_t frame = 0) const noexcept {
            if (!active) return 1;
            if (remaining <= frame + 1 || total < 2) return 0;
            return std::min(1.f, float(remaining - frame - 1) / float(total - 1));
        }
    };
    void start(uint32_t frames) noexcept {
        const auto old = state.load(std::memory_order_relaxed);
        total.store(std::max(2u, frames), std::memory_order_relaxed);
        state.store(nextGeneration(old) | std::max(2u, frames), std::memory_order_release);
    }
    void cancel() noexcept {
        auto old = state.load(std::memory_order_relaxed);
        while (!state.compare_exchange_weak(old, nextGeneration(old) | inactive,
                                             std::memory_order_release, std::memory_order_relaxed)) {}
    }
    Block block() const noexcept {
        const auto value = state.load(std::memory_order_acquire);
        const auto left = static_cast<uint32_t>(value);
        return {value, left, total.load(std::memory_order_relaxed), left != inactive};
    }
    void advance(const Block &before, uint32_t frames) noexcept {
        if (!before.active || before.remaining == 0) return;
        auto expected = before.state;
        const auto left = before.remaining > frames ? before.remaining - frames : 0;
        state.compare_exchange_strong(expected, (before.state & generationMask) | left,
                                      std::memory_order_release, std::memory_order_relaxed);
    }
private:
    static constexpr uint64_t generationMask = 0xffffffff00000000ULL;
    static constexpr uint32_t inactive = 0xffffffffU;
    static uint64_t nextGeneration(uint64_t previous) noexcept {
        return (previous + (1ULL << 32)) & generationMask;
    }
    static_assert(std::atomic<uint64_t>::is_always_lock_free, "Fade state must be lock-free");
    std::atomic<uint64_t> state{inactive};
    std::atomic<uint32_t> total{0};
};
} // namespace catlive
