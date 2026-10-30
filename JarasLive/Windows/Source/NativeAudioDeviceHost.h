#pragma once
#include <JuceHeader.h>
#include <memory>

namespace catlive {
// The existing settings UI keeps its device-control API. Native builds bypass
// AudioDeviceManager's callback/mixing lock: only its non-realtime control and
// MIDI services remain. These helpers also support isolated legacy test hosts.
std::shared_ptr<juce::AudioDeviceManager> makeAudioDeviceHost();
void addRealtimeAudioCallback(juce::AudioDeviceManager&, juce::AudioIODeviceCallback*);
void removeRealtimeAudioCallback(juce::AudioDeviceManager&, juce::AudioIODeviceCallback*);
double audioDeviceCpuUsage(const juce::AudioDeviceManager&);
bool usesNativeAudioDeviceHost(const juce::AudioDeviceManager&) noexcept;
}
