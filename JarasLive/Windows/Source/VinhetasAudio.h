#pragma once
#include <juce_audio_formats/juce_audio_formats.h>
#include <array>
#include <atomic>
#include <vector>
#include <climits>
#include "../../Core/Audio/PadGateRelease.hpp"

namespace catlive {
/// Samples are decoded on a worker thread. The audio callback only drains
/// bounded commands and mixes preallocated voices; repeated triggers overlap.
class VinhetasAudio {
  public:
    struct Sample { juce::AudioBuffer<float> pcm; double rate = 44100; };
    enum class Kind { start, stop, volume, stopPad, panic };
    struct Command { Kind kind{}; uint64_t token = 0; int preset = 0, pad = 0; float gain = 1; const Sample *sample = nullptr; };
    static constexpr size_t capacity = 512;
    std::atomic<bool> learningMIDI{false};
    std::atomic<int> midiChannel{0}; // 0 = Omni, otherwise 1...16.
    void setMIDIMapping(int index,int status,int channel,int number) {
        midiMappings[(size_t)index].store(status?uint32_t((status<<16)|(channel<<8)|number):0,std::memory_order_release);
    }
    bool handlesMIDI(const juce::MidiMessage &message) const {
        if(!message.isNoteOnOrOff()&&!message.isController())return false;
        const int selected=midiChannel.load(std::memory_order_relaxed);
        if(selected!=0&&selected!=message.getChannel())return false;
        if(learningMIDI.load(std::memory_order_relaxed))return true;
        const auto *bytes=message.getRawData();const int status=message.isController()?0xb0:0x90;
        const uint32_t key=(status<<16)|bytes[1];
        for(const auto &mapping:midiMappings)if((mapping.load(std::memory_order_acquire)&0xffff00ffu)==key)return true;
        return false;
    }
    void setOutputAvailable(bool available) { outputAvailable.store(available, std::memory_order_release); }
    bool enqueue(Command command) {
        if (command.kind == Kind::start && !outputAvailable.load(std::memory_order_acquire)) return false;
        const auto w = write.load(std::memory_order_relaxed), r = read.load(std::memory_order_acquire);
        if (w - r == capacity) return false;
        // Publish the accepted voice before exposing its command to the callback.
        // A quick mouse release must not blank the pad between enqueue and render.
        if (command.kind == Kind::start && command.sample && command.preset >= 0 && command.preset < 6 && command.pad >= 0 && command.pad < 16)
            counts[size_t(command.preset * 16 + command.pad)].fetch_add(1, std::memory_order_relaxed);
        commands[w % capacity] = command; write.store(w + 1, std::memory_order_release); return true;
    }
    static std::shared_ptr<Sample> decode(const juce::File &file) {
        juce::AudioFormatManager formats; formats.registerBasicFormats();
        std::unique_ptr<juce::AudioFormatReader> reader(formats.createReaderFor(file));
        if (!reader || reader->lengthInSamples <= 0 || reader->lengthInSamples > INT_MAX) return nullptr;
        auto sample = std::make_shared<Sample>(); sample->rate = reader->sampleRate;
        sample->pcm.setSize(2, int(reader->lengthInSamples));
        if (!reader->read(&sample->pcm, 0, sample->pcm.getNumSamples(), 0, true, true)) return nullptr;
        if (reader->numChannels == 1) sample->pcm.copyFrom(1, 0, sample->pcm, 0, 0, sample->pcm.getNumSamples());
        return sample;
    }
    const Sample *retain(std::shared_ptr<Sample> sample) { auto result=sample.get(); samples.push_back(std::move(sample)); return result; }
    // Called by the render thread, or while its callback is detached/locked.
    void discard() {
        auto r = read.load(std::memory_order_relaxed); const auto w = write.load(std::memory_order_acquire);
        while (r != w) { apply(commands[r % capacity]); ++r; }
        read.store(r, std::memory_order_release);
        for (auto &voice : voices) finish(voice);
    }
    void render(juce::AudioBuffer<float> &destination, int count, double rate) {
        if (!outputAvailable.load(std::memory_order_acquire)) { discard(); return; }
        auto r = read.load(std::memory_order_relaxed); const auto w = write.load(std::memory_order_acquire);
        while (r != w) { apply(commands[r % capacity]); ++r; }
        read.store(r, std::memory_order_release);
        for (auto &voice : voices) {
            if (!voice.sample) continue;
            if (voice.releasing) voice.release.begin(rate);
            const auto &pcm = voice.sample->pcm;
            const double step = voice.sample->rate / rate;
            for (int frame = 0; frame < count; ++frame) {
                const int first = int(voice.position);
                if (first >= pcm.getNumSamples()) { finish(voice); break; }
                const int next = std::min(first + 1, pcm.getNumSamples() - 1);
                const float fraction = float(voice.position - first);
                const float gain = voice.gain * voice.release.next();
                for (int ch = 0; ch < std::min(2, destination.getNumChannels()); ++ch) {
                    const auto *data = pcm.getReadPointer(ch);
                    destination.addSample(ch, frame, (data[first] + (data[next] - data[first]) * fraction) * gain);
                }
                voice.position += step;
                if (voice.release.finished()) { finish(voice); break; }
            }
        }
    }
    bool active(int preset, int pad) const { return counts[size_t(preset * 16 + pad)].load(std::memory_order_relaxed) > 0; }
  private:
    struct Voice { const Sample *sample = nullptr; uint64_t token = 0; int preset = 0, pad = 0; double position = 0; float gain = 1; bool releasing = false; jaras::PadGateRelease release; };
    std::atomic<bool> outputAvailable{false};
    std::array<std::atomic<uint32_t>,22> midiMappings{};
    std::array<Command, capacity> commands{};
    std::atomic<size_t> read{0}, write{0};
    std::array<Voice, 128> voices{};
    std::array<std::atomic<int>, 96> counts{};
    std::vector<std::shared_ptr<Sample>> samples;
    void finish(Voice &voice) {
        if (voice.sample) counts[size_t(voice.preset * 16 + voice.pad)].fetch_sub(1, std::memory_order_relaxed);
        voice.sample = nullptr;
    }
    void apply(const Command &command) {
        if (command.preset < 0 || command.preset >= 6 || command.pad < 0 || command.pad >= 16) return;
        if (command.kind == Kind::stopPad) { for (auto &voice : voices) if (voice.preset == command.preset && voice.pad == command.pad) voice.releasing = true; return; }
        if (command.kind == Kind::panic) { for (auto &voice : voices) finish(voice); return; }
        if (command.kind == Kind::stop) { for (auto &voice : voices) if (voice.token == command.token) voice.releasing = true; return; }
        if (command.kind == Kind::volume) { for (auto &voice : voices) if (voice.preset == command.preset && voice.pad == command.pad) voice.gain = command.gain; return; }
        if (!command.sample) return;
        for (auto &voice : voices) if (!voice.sample) {
            voice = {command.sample, command.token, command.preset, command.pad, 0, command.gain};
            return;
        }
        counts[size_t(command.preset * 16 + command.pad)].fetch_sub(1, std::memory_order_relaxed);
    }
};
}
