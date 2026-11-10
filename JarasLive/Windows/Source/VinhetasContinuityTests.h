#pragma once
#include "VinhetasAudio.h"
#include <stdexcept>
#include <cmath>

namespace catlive::vinhetasContinuityTests {
// Also compiled on macOS against the same pinned JUCE version, so the actual
// Windows pad mixer is exercised even when a Windows device is unavailable.
inline void run() {
    const auto require = [](bool ok) { if (!ok) throw std::runtime_error("Pad PCM continuity regression"); };
    for (double rate : {44100., 48000., 96000.}) {
        VinhetasAudio audio; audio.setOutputAvailable(true);
        auto sustained = std::make_shared<VinhetasAudio::Sample>();
        sustained->rate = rate; sustained->pcm.setSize(2, int(rate * 5));
        for (int ch = 0; ch < 2; ++ch)
            juce::FloatVectorOperations::fill(sustained->pcm.getWritePointer(ch), .025f, sustained->pcm.getNumSamples());
        auto shortSample = std::make_shared<VinhetasAudio::Sample>();
        shortSample->rate = rate == 44100 ? 48000 : 44100;
        shortSample->pcm.setSize(2, 887);
        for (int ch = 0; ch < 2; ++ch)
            juce::FloatVectorOperations::fill(shortSample->pcm.getWritePointer(ch), .001f, 887);
        const auto *longPCM = audio.retain(sustained), *shortPCM = audio.retain(shortSample);
        require(audio.enqueue({VinhetasAudio::Kind::start, 1, 0, 0, 1, longPCM}));
        juce::AudioBuffer<float> output(2, 2048);
        for (int press = 0; press < 96; ++press) {
            require(audio.enqueue({VinhetasAudio::Kind::start, uint64_t(press + 2), 0, 1, 1, shortPCM}));
            double position = 0;
            for (int count : {128, 37, 251, 64, 512, 128, 1024}) {
                output.clear(); audio.render(output, count, rate);
                for (int f = 0; f < count; ++f) {
                    const float expected = .025f + (position < 887 ? .001f : 0);
                    for (int ch = 0; ch < 2; ++ch) require(std::abs(output.getSample(ch, f) - expected) < .00001f);
                    position += shortSample->rate / rate;
                }
            }
            require(audio.active(0, 0) && !audio.active(0, 1));
        }
        require(audio.enqueue({VinhetasAudio::Kind::panic}));
        output.clear(); audio.render(output, 128, rate);
        require(output.getMagnitude(0, 128) == 0 && !audio.active(0, 0));
        // Capacity never steals an earlier sounding voice; the extra trigger
        // is discarded and the activity counter still represents live voices.
        for (uint64_t i = 0; i < 129; ++i) require(audio.enqueue({VinhetasAudio::Kind::start, i + 1000, 0, 0, .01f, longPCM}));
        output.clear(); audio.render(output, 128, rate);
        require(std::abs(output.getSample(0, 0) - 128 * .025f * .01f) < .00001f);
        audio.discard(); require(!audio.active(0, 0));
    }
}
}
