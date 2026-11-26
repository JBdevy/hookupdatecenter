#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>
#include <cmath>
#include <algorithm>
#include <atomic>
#if defined(__x86_64__)
#include <xmmintrin.h>
#endif

namespace jaras {
// Every supported Apple slice must use native atomics in its audio callback.
// Fail at build time instead of silently introducing a runtime locking helper.
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<unsigned>::is_always_lock_free);
static_assert(std::atomic<bool>::is_always_lock_free);

// Cover source nodes as well as effects: a source may also be rendered directly
// by a mixer. Nested units leave the existing mode alone; the outermost guard
// restores the host's floating-point environment after the block.
struct ScopedAudioDenormals {
#if defined(__aarch64__)
    uint64_t previous=0;
    bool changed=false;
    ScopedAudioDenormals() {
        asm volatile("mrs %0, fpcr" : "=r"(previous));
        const auto next=previous | (uint64_t(1)<<24);
        changed=next!=previous;
        if(changed) asm volatile("msr fpcr, %0" :: "r"(next));
    }
    ~ScopedAudioDenormals() {
        uint64_t current=0;
        asm volatile("mrs %0, fpcr" : "=r"(current));
        if(current!=previous) asm volatile("msr fpcr, %0" :: "r"(previous));
    }
#elif defined(__x86_64__)
    unsigned previous=_mm_getcsr();
    bool changed=(previous & 0x8040)!=0x8040;
    ScopedAudioDenormals() { if(changed) _mm_setcsr(previous | 0x8040); }
    // A hosted processor may change the mode even when this guard inherited
    // FTZ/DAZ. Restore the whole caller control word on both entry paths.
    ~ScopedAudioDenormals() { if(_mm_getcsr()!=previous) _mm_setcsr(previous); }
#endif
    ScopedAudioDenormals(const ScopedAudioDenormals&)=delete;
    ScopedAudioDenormals& operator=(const ScopedAudioDenormals&)=delete;
};

// The manually clocked graph never owns a RemoteIO unit. Carry the physical
// callback's host clock through native processors without locks or allocations.
struct RealtimeClock {
    uint64_t host = 0;
    double sample = 0, rate = 0, ticksPerSecond = 0;
};
inline thread_local RealtimeClock realtimeClock;
inline AudioTimeStamp physicalRenderTime(const AudioTimeStamp& original, double rate) {
    auto result = original;
    const auto& clock = realtimeClock;
    if (clock.host && clock.rate > 0) {
        // A freshly reset format converter can issue its first source pull
        // without a valid sample or host timestamp. RemoteIO still supplies a
        // valid physical deadline: never treat that preroll pull as immediate
        // playback and consume a block before the queued song starts.
        const double delta = rate > 0 && (original.mFlags & kAudioTimeStampSampleTimeValid)
            ? original.mSampleTime / rate - clock.sample / clock.rate : 0;
        result.mHostTime = uint64_t(std::max(0., double(clock.host) + delta * clock.ticksPerSecond));
        result.mFlags |= kAudioTimeStampHostTimeValid;
    }
    return result;
}
}
