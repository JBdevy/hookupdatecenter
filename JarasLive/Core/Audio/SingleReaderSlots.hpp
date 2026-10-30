#pragma once
#include <array>
#include <atomic>
#include <cassert>
#include <cstddef>
#include <deque>
#include <memory>
#include <stdexcept>

namespace catlive::audio {
// Serialized producer owns immutable payloads. Exactly one reader may hold a
// lease. The lease pins every pointer it observes, even across slot replacement.
// No shared_ptr refcounts, locks, allocation, destruction or retry on the reader.
// Producer publication and the reader announcement use seq_cst deliberately:
// a reader that could observe an old slot must announce before the producer's
// post-publication quiescence check. Acq/rel on separate atomics is insufficient.
template<class T, std::size_t Count>
class SingleReaderSlots final {
    static_assert(Count > 0);
    static_assert(std::atomic<const T*>::is_always_lock_free);
    static_assert(std::atomic<bool>::is_always_lock_free);
public:
    SingleReaderSlots() { for(auto& slot: published_)slot.store(nullptr); }
    SingleReaderSlots(const SingleReaderSlots&)=delete;
    SingleReaderSlots& operator=(const SingleReaderSlots&)=delete;
    class Lease final {
    public:
        explicit Lease(SingleReaderSlots& slots) noexcept : slots_(slots) {
            const bool overlapping=slots_.reading_.exchange(true);
            assert(!overlapping); (void)overlapping;
        }
        ~Lease() { slots_.reading_.store(false); }
        Lease(const Lease&)=delete;
        Lease& operator=(const Lease&)=delete;
        const T* get(std::size_t slot) const noexcept {
            assert(slot<Count); return slots_.published_[slot].load();
        }
    private:
        SingleReaderSlots& slots_;
    };
    Lease read() noexcept { return Lease(*this); }
    // Producer only; callers must not retain pointers across publication.
    const T* producerView(std::size_t slot) const noexcept { return owners_[slot].get(); }
    void publish(std::size_t slot,std::unique_ptr<T> value) {
        if(slot>=Count)throw std::out_of_range("Audio page slot");
        // Allocate retirement storage before making a new pointer visible.
        // On allocation failure every old published pointer remains owned.
        if(owners_[slot])retired_.emplace_back();
        if(owners_[slot])retired_.back()=std::move(owners_[slot]);
        owners_[slot]=std::move(value);
        published_[slot].store(owners_[slot].get());
        collectRetired();
    }
    void collectRetired() { if(!reading_.load())retired_.clear(); }
    std::size_t retiredCount() const noexcept { return retired_.size(); }
    // Destruction requires reader stopped/joined, as well as producer quiescence.
private:
    std::array<std::unique_ptr<T>,Count> owners_;
    std::array<std::atomic<const T*>,Count> published_;
    std::deque<std::unique_ptr<T>> retired_;
    std::atomic<bool> reading_{false};
};
} // namespace catlive::audio
