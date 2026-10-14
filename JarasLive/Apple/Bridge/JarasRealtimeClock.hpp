#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>
#include <cmath>
#include <algorithm>

namespace jaras {
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
    if (clock.host && clock.rate > 0 && rate > 0 && (original.mFlags & kAudioTimeStampSampleTimeValid)) {
        const double delta = original.mSampleTime / rate - clock.sample / clock.rate;
        result.mHostTime = uint64_t(std::max(0., double(clock.host) + delta * clock.ticksPerSecond));
        result.mFlags |= kAudioTimeStampHostTimeValid;
    }
    return result;
}
}
