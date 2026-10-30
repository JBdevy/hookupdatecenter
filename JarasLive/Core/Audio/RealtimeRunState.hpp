#pragma once
#include <atomic>
#include <cassert>
#include <thread>

namespace catlive::audio {
// Explicit start/stop lifecycle for a single callback. This is not a mechanism
// for suppressing audio while live graph edits occur. Control must stop, wait
// for the last callback, then prepare/restart. The callback never waits/retries.
class RealtimeRunState final {
public:
    static_assert(std::atomic<unsigned>::is_always_lock_free);
    bool running() const noexcept { return (state_.load(std::memory_order_acquire)&1u)!=0; }
    void stop() noexcept { state_.fetch_and(~1u,std::memory_order_acq_rel); }
    void waitStopped() const noexcept {
        assert(!running());
        while(state_.load(std::memory_order_acquire)&2u)std::this_thread::yield();
    }
    void start() noexcept {
        assert(state_.load()==0);
        state_.store(1,std::memory_order_release);
    }
    bool enter() noexcept {
        unsigned expected=1;
        return state_.compare_exchange_strong(expected,3,std::memory_order_acquire,std::memory_order_relaxed);
    }
    void leave() noexcept { state_.fetch_and(~2u,std::memory_order_release); }
private:
    std::atomic<unsigned> state_{0};
};
} // namespace catlive::audio
