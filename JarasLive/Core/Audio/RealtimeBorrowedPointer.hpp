#pragma once
#include <atomic>
#include <cassert>
#include <thread>

namespace catlive::audio {
// Control owns the object; a single audio callback borrows it for one block.
// Withdrawal waits on CONTROL for an already admitted reader, never on audio.
// A withdrawn optional service (e.g. recording) does not stop the audio graph.
// Seq-cst pairs publication and reader admission across distinct atomics.
template<class T> class RealtimeBorrowedPointer final {
public:
    class Lease final {
    public:
        explicit Lease(RealtimeBorrowedPointer& slot) noexcept : slot_(slot) {
            const bool overlapping=slot_.reading_.exchange(true);
            assert(!overlapping);(void)overlapping;
            value_=slot_.published_.load();
        }
        ~Lease(){slot_.reading_.store(false);}
        Lease(const Lease&)=delete;
        Lease& operator=(const Lease&)=delete;
        T* get() const noexcept{return value_;}
    private:
        RealtimeBorrowedPointer& slot_;
        T* value_=nullptr;
    };
    Lease read() noexcept{return Lease(*this);}
    // Serialized control only. Reuse/replace only after withdrawAndWait().
    void publish(T* value) noexcept {
        assert(value && published_.load()==nullptr);
        published_.store(value);
    }
    void withdrawAndWait() noexcept {
        published_.store(nullptr);
        while(reading_.load())std::this_thread::yield();
    }
private:
    static_assert(std::atomic<T*>::is_always_lock_free);
    static_assert(std::atomic<bool>::is_always_lock_free);
    std::atomic<T*> published_{nullptr};
    std::atomic<bool> reading_{false};
};
} // namespace catlive::audio
