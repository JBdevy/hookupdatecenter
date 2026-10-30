#pragma once
#include <array>
#include <atomic>
#include <type_traits>

namespace catlive::audio {
// SPSC triple buffer for coalescible controls. Each side exclusively owns one
// slot; an atomic exchange transfers the middle slot. No loops, locks, heap
// operations or torn multi-field snapshots. Intermediate publications may be
// replaced; do not use for ordered transport or recording events.
template<class T>
class RealtimeLatestValue final {
    static_assert(std::is_trivially_copyable_v<T> && std::is_nothrow_copy_assignable_v<T>);
    static_assert(std::atomic<unsigned>::is_always_lock_free);
public:
    void publish(const T& value) noexcept {
        values_[producer_]=value;
        producer_=middle_.exchange(producer_|dirty,std::memory_order_acq_rel)&indexMask;
    }
    bool consume(T& value) noexcept {
        if(!(middle_.load(std::memory_order_acquire)&dirty))return false;
        consumer_=middle_.exchange(consumer_,std::memory_order_acq_rel)&indexMask;
        value=values_[consumer_];
        return true;
    }
private:
    static constexpr unsigned dirty=4,indexMask=3;
    std::array<T,3> values_{};
    alignas(64) unsigned producer_=0;
    alignas(64) unsigned consumer_=1;
    alignas(64) std::atomic<unsigned> middle_{2};
};
} // namespace catlive::audio
