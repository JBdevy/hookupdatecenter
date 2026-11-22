#pragma once
#import <AVFoundation/AVFoundation.h>
#include "CatMIDISequence.hpp"
#include "JarasRealtimeClock.hpp"
static inline std::vector<CatMIDINote> catMIDINotes(NSArray<NSDictionary*>* values) {
    std::vector<CatMIDINote> notes;notes.reserve(values.count);
    for(NSDictionary* n in values) notes.push_back({[n[@"start"] doubleValue],[n[@"end"] doubleValue],uint8_t([n[@"pitch"] intValue]),uint8_t([n[@"velocity"] intValue]),uint8_t([n[@"channel"] intValue]-1),
        (uint64_t([n[@"sourceID0"] unsignedIntValue])<<32)|[n[@"sourceID1"] unsignedIntValue],
        (uint64_t([n[@"sourceID2"] unsignedIntValue])<<32)|[n[@"sourceID3"] unsignedIntValue],uint8_t(n[@"headMask"] ? [n[@"headMask"] unsignedIntValue] : 3)});
    return notes;
}
static inline double catMIDIClock(const AudioTimeStamp* time,double rate) {
    const auto physical = jaras::physicalRenderTime(*time, rate);
    return physical.mFlags & kAudioTimeStampHostTimeValid
        ? [AVAudioTime secondsForHostTime:physical.mHostTime] : physical.mSampleTime / rate;
}

static inline void catRenderMIDISequence(CatMIDISequence& sequence, const AudioTimeStamp* time, double rate, unsigned frames) {
    const auto sample = time->mFlags & kAudioTimeStampSampleTimeValid ? time->mSampleTime : NAN;
    sequence.render(catMIDIClock(time, rate), rate, frames, sample);
}
