#pragma once
#include <array>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

namespace catlive::audio {
// Control threads reserve storage before a voice starts. Render threads only
// lease it. A cached successor is weak: a stopped voice cannot retain an entire
// chain of old audio. Generations reject recycled slots, including ABA races.
template<class State, uint32_t Capacity = 4096> class SharedRenderPool {
    struct Slot {
        template<class... Args> explicit Slot(Args&&... args) : state(std::forward<Args>(args)...) {}
        State state;
        std::atomic<uint64_t> life{0}, successor{0};
        std::atomic<uint32_t> freeNext{0};
        uint32_t index = 0;
    };
    static constexpr uint64_t refMask = 0xffffffffULL;
    std::array<std::atomic<Slot *>, Capacity> slots{};
    // Low 32 bits contain index+1; high bits are an ABA counter.
    std::atomic<uint64_t> freeHead{0};
    std::mutex reservation;
    std::vector<std::unique_ptr<Slot>> storage;
    void recycle(Slot *slot) {
        auto head = freeHead.load(std::memory_order_relaxed);
        do { slot->freeNext.store(uint32_t(head), std::memory_order_relaxed); }
        while (!freeHead.compare_exchange_weak(head, ((head + (1ULL << 32)) & ~refMask) | (slot->index + 1),
                                               std::memory_order_release, std::memory_order_relaxed));
    }
    void release(Slot *slot) {
        if (uint32_t(slot->life.fetch_sub(1, std::memory_order_acq_rel)) == 1) recycle(slot);
    }
public:
    class Lease {
        friend class SharedRenderPool;
        SharedRenderPool *pool = nullptr;
        Slot *slot = nullptr;
        uint64_t token = 0;
        Lease(SharedRenderPool *p, Slot *s, uint64_t t) : pool(p), slot(s), token(t) {}
    public:
        Lease() = default;
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;
        Lease(Lease&& other) noexcept { *this = std::move(other); }
        Lease& operator=(Lease&& other) noexcept {
            if (this != &other) {
                reset(); pool = other.pool; slot = other.slot; token = other.token;
                other.slot = nullptr;
            }
            return *this;
        }
        ~Lease() { reset(); }
        void reset() { if (slot) pool->release(slot); slot = nullptr; }
        explicit operator bool() const { return slot != nullptr; }
        State *operator->() { return &slot->state; }
        const State *operator->() const { return &slot->state; }
        State &operator*() { return slot->state; }
        uint64_t handle() const { return token; }
        Lease cachedSuccessor() const { return slot ? pool->retain(slot->successor.load(std::memory_order_acquire)) : Lease{}; }
        void publishSuccessor(const Lease &next) { slot->successor.store(next.handle(), std::memory_order_release); }
    };
    template<class... Args> bool reserve(uint32_t count, Args&&... args) {
        std::lock_guard<std::mutex> lock(reservation);
        if (storage.size() + count > Capacity) return false;
        for (uint32_t i = 0; i < count; ++i) {
            auto value = std::make_unique<Slot>(args...);
            auto *slot = value.get(); slot->index = uint32_t(storage.size());
            storage.push_back(std::move(value));
            slots[slot->index].store(slot, std::memory_order_release);
            recycle(slot);
        }
        return true;
    }
    Lease acquire() {
        auto head = freeHead.load(std::memory_order_acquire);
        while (uint32_t(head)) {
            auto *slot = slots[uint32_t(head) - 1].load(std::memory_order_acquire);
            const uint64_t next = ((head + (1ULL << 32)) & ~refMask) | slot->freeNext.load(std::memory_order_relaxed);
            if (!freeHead.compare_exchange_weak(head, next, std::memory_order_acq_rel, std::memory_order_acquire)) continue;
            const auto generation = (slot->life.load(std::memory_order_relaxed) & ~refMask) + (1ULL << 32);
            slot->successor.store(0, std::memory_order_relaxed);
            slot->life.store(generation | 1, std::memory_order_release);
            return {this, slot, generation | (slot->index + 1)};
        }
        return {};
    }
    Lease retain(uint64_t handle) {
        const auto index = uint32_t(handle);
        if (!index || index > Capacity) return {};
        auto *slot = slots[index - 1].load(std::memory_order_acquire);
        if (!slot) return {};
        auto life = slot->life.load(std::memory_order_acquire);
        while ((life & ~refMask) == (handle & ~refMask) && uint32_t(life) > 0) {
            if (slot->life.compare_exchange_weak(life, life + 1, std::memory_order_acquire, std::memory_order_relaxed))
                return {this, slot, handle};
        }
        return {};
    }
    // Unique histories can advance in place. Invalidate all weak readers before
    // touching the DSP, so they cannot observe a partially changed state.
    bool makeExclusive(Lease &lease) {
        auto expected = (lease.token & ~refMask) | 1;
        const auto next = ((expected + (1ULL << 32)) & ~refMask) | 1;
        if (!lease.slot->life.compare_exchange_strong(expected, next, std::memory_order_acq_rel)) return false;
        lease.token = (next & ~refMask) | (lease.slot->index + 1);
        lease.slot->successor.store(0, std::memory_order_release);
        return true;
    }
};
} // namespace catlive::audio
