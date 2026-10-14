#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <vector>

namespace jaras {
// The DSP already places every sample in its selected physical channel.
// RemoteIO must preserve those indices instead of deriving a speaker layout.
inline OSStatus configureDiscreteOutputMap(AudioUnit unit, UInt32 channels,
    decltype(&AudioUnitSetProperty) setProperty = AudioUnitSetProperty) {
    if (!unit || channels == 0 || channels > 1024) return kAudio_ParamError;
    std::vector<SInt32> mapping(channels);
    for (UInt32 channel = 0; channel < channels; ++channel) mapping[channel] = static_cast<SInt32>(channel);
    return setProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Global, 0,
                       mapping.data(), static_cast<UInt32>(mapping.size() * sizeof(SInt32)));
}
}
