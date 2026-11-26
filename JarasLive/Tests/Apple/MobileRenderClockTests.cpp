#include "../../Apple/Bridge/JarasRealtimeClock.hpp"
#include <cassert>
#include <iostream>

int main() {
    AudioTimeStamp input{};
    input.mSampleTime = 96000;
    input.mHostTime = 7; // Undefined/stale fields in a converter's first pull.
    jaras::realtimeClock = {24000000, 44100, 44100, 24000000};
    const auto warmup = jaras::physicalRenderTime(input, 48000);
    assert(warmup.mFlags & kAudioTimeStampHostTimeValid);
    assert(warmup.mHostTime == 24000000);
    const uint64_t queuedDeadline = 26400000;
    assert(warmup.mHostTime < queuedDeadline); // Warmup cannot consume queued PCM.

    input.mFlags = kAudioTimeStampSampleTimeValid;
    const auto valid = jaras::physicalRenderTime(input, 48000);
    assert(valid.mHostTime == 48000000); // Valid converter lookahead is retained.
    input.mFlags = kAudioTimeStampHostTimeValid;
    const auto stale = jaras::physicalRenderTime(input, 48000);
    assert(stale.mHostTime == 24000000); // RemoteIO owns the physical clock.

    jaras::realtimeClock = {};
    const auto hardware = jaras::physicalRenderTime(input, 48000);
    assert(hardware.mFlags == input.mFlags && hardware.mHostTime == input.mHostTime);
    input.mFlags = 0;
    assert(jaras::physicalRenderTime(input, 48000).mFlags == 0);
    std::cout << "MOBILE_RENDER_CLOCK_INVALID_CONVERTER_TIMESTAMP_USES_PHYSICAL_DEADLINE_OK\n";
}
