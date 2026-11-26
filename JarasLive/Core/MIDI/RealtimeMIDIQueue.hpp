#pragma once
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace jaras {
// Multiple MIDI producers, one audio consumer. All storage is allocated with
// the owner. The consumer never waits for a producer that is still publishing;
// it retries on the next audio block. No callback-side ownership/destruction.
// Producer contention and capacity are bounded and reported, never spun on.
template<std::size_t Capacity = 2048> class RealtimeMIDIQueue {
    static_assert(Capacity > 1 && (Capacity & (Capacity - 1)) == 0);
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
public:
    static constexpr std::size_t capacity = Capacity;
    struct Event {
        double seconds = 0;
        std::uint64_t generation = 0;
        std::array<std::uint8_t, 3> data{};
        std::uint8_t size = 0;
    };
    RealtimeMIDIQueue() noexcept {
        for(std::size_t i=0;i<Capacity;++i) slots[i].sequence.store(i,std::memory_order_relaxed);
    }
    bool push(const std::uint8_t* data, std::size_t size, double seconds) noexcept {
        // CatLive's current live consumers support short MIDI messages only.
        // Longer messages, including SysEx, are rejected and counted explicitly.
        if(size==0 || size>3) { unsupported.fetch_add(1,std::memory_order_relaxed);return false; }
        const auto epoch=generation.load(std::memory_order_acquire);
        auto position=writePosition.load(std::memory_order_relaxed);
        for(unsigned attempt=0;attempt<32;++attempt) {
            auto &slot=slots[position & (Capacity-1)];
            const auto sequence=slot.sequence.load(std::memory_order_acquire);
            const auto difference=static_cast<std::int64_t>(sequence-position);
            if(difference==0) {
                if(writePosition.compare_exchange_weak(position,position+1,std::memory_order_relaxed)) {
                    Event event;event.seconds=seconds;event.generation=epoch;event.size=static_cast<std::uint8_t>(size);
                    for(std::size_t i=0;i<size;++i)event.data[i]=data[i];
                    slot.event=event;
                    slot.sequence.store(position+1,std::memory_order_release);
                    return true;
                }
            } else if(difference<0) break;
            else position=writePosition.load(std::memory_order_relaxed);
        }
        dropped.fetch_add(1,std::memory_order_relaxed);
        generation.fetch_add(1,std::memory_order_release);
        return false;
    }
    bool pop(Event &event) noexcept {
        auto &slot=slots[readPosition & (Capacity-1)];
        if(slot.sequence.load(std::memory_order_acquire)!=readPosition+1)return false;
        event=slot.event;
        slot.sequence.store(readPosition+Capacity,std::memory_order_release);
        ++readPosition;
        return true;
    }
    // Old queued notes must not replay after overflow or a device restart.
    void invalidate() noexcept { generation.fetch_add(1,std::memory_order_release); }
    // Consumer only, including reset while the audio consumer is stopped.
    // Producers may still publish; do not wait for an unfinished reservation or
    // follow a producer indefinitely as it refills the slots being discarded.
    std::size_t discardPending() noexcept {
        Event event;
        std::size_t count=0;
        while(count<Capacity && pop(event))++count;
        return count;
    }
    std::uint64_t epoch()const noexcept {return generation.load(std::memory_order_acquire);}
    std::uint64_t droppedCount()const noexcept {return dropped.load(std::memory_order_relaxed);}
    std::uint64_t unsupportedCount()const noexcept {return unsupported.load(std::memory_order_relaxed);}
private:
    struct Slot {std::atomic<std::uint64_t> sequence{};Event event;};
    std::array<Slot,Capacity> slots;
    alignas(64) std::atomic<std::uint64_t> writePosition{0};
    alignas(64) std::uint64_t readPosition=0;
    std::atomic<std::uint64_t> generation{0},dropped{0},unsupported{0};
};
}
