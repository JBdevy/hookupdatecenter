#pragma once
#import <AVFoundation/AVFoundation.h>
#include "CatMIDISequence.hpp"
static inline std::vector<CatMIDINote> catMIDINotes(NSArray<NSDictionary*>* values) {
    std::vector<CatMIDINote> notes;notes.reserve(values.count);
    for(NSDictionary* n in values) notes.push_back({[n[@"start"] doubleValue],[n[@"end"] doubleValue],uint8_t([n[@"pitch"] intValue]),uint8_t([n[@"velocity"] intValue]),uint8_t([n[@"channel"] intValue]-1)});
    return notes;
}
static inline double catMIDIClock(const AudioTimeStamp* time,double rate) {
    return time->mFlags&kAudioTimeStampHostTimeValid ? [AVAudioTime secondsForHostTime:time->mHostTime] : time->mSampleTime/rate;
}
