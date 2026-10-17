#pragma once
namespace juce { class AudioFormatManager; }
namespace catlive {
// File MP3s use the shared gapless decoder before JUCE's remaining formats.
// Embedded streams retain JUCE support (e.g. the built-in click resource).
void registerAudioFormats(juce::AudioFormatManager&);
}
