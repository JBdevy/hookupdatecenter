#include "Instrument.h"
#define TSF_IMPLEMENTATION
#include "../../Core/ThirdParty/TinySoundFont/tsf.h"
namespace catlive {
#include "SoundFontRenderer.h"
namespace {
struct PianoSound final : SynthesiserSound {
    bool appliesToNote(int) override { return true; }
    bool appliesToChannel(int) override { return true; }
};
struct PianoVoice final : SynthesiserVoice {
    double phase = 0, step = 0, age = 0;
    float level = 0;
    ADSR envelope;
    bool canPlaySound(SynthesiserSound *sound) override {
        return dynamic_cast<PianoSound *>(sound) != nullptr;
    }
    void startNote(int note, float velocity, SynthesiserSound *, int) override {
        phase = age = 0;
        level = velocity * .12f;
        step =
            MathConstants<double>::twoPi * MidiMessage::getMidiNoteInHertz(note) / getSampleRate();
        envelope.setSampleRate(getSampleRate());
        envelope.setParameters({.003f, .4f, .12f, .35f});
        envelope.noteOn();
    }
    void stopNote(float, bool tail) override {
        envelope.noteOff();
        if (!tail) {
            envelope.reset();
            clearCurrentNote();
        }
    }
    void pitchWheelMoved(int) override {}
    void controllerMoved(int, int) override {}
    void renderNextBlock(AudioBuffer<float> &output, int start, int count) override {
        // Synthesiser calls every voice, including unused voices. Active release
        // tails retain their note until the envelope finishes below.
        if (!isVoiceActive())
            return;
        for (int n = 0; n < count; ++n) {
            float sample =
                (float)(std::sin(phase) + .33 * std::sin(2 * phase) * std::exp(-age * 3) +
                        .1 * std::sin(3 * phase) * std::exp(-age * 5)) *
                level * envelope.getNextSample();
            phase += step;
            age += 1 / getSampleRate();
            for (int ch = 0; ch < output.getNumChannels(); ++ch)
                output.addSample(ch, start + n, sample);
        }
        if (!envelope.isActive())
            clearCurrentNote();
    }
};
} // namespace
struct Instrument::Impl {
    Synthesiser synth;
    SoundFontRenderer sf;
    double rate = 48000;
    var parameters;
    bool drums = false;
};
Instrument::Instrument() : impl(std::make_unique<Impl>()) {
    for (int i = 0; i < 24; ++i)
        impl->synth.addVoice(new PianoVoice());
    impl->synth.addSound(new PianoSound());
    impl->synth.setNoteStealingEnabled(true);
    prepare(48000);
}
Instrument::~Instrument() = default;
void Instrument::prepare(double rate) {
    impl->rate = rate;
    impl->synth.setCurrentPlaybackSampleRate(rate);
    if (impl->sf.font)
        tsf_set_output(impl->sf.font, TSF_STEREO_INTERLEAVED, (int)rate, 0);
}
void Instrument::loadSoundFont(const File &file) {
    MemoryBlock data;
    if (file.getSize() > 512LL * 1024 * 1024 || !file.loadFileAsData(data))
        throw std::runtime_error("Unable to read SoundFont.");
    auto *font = tsf_load_memory(data.getData(), (int)data.getSize());
    if (!font || tsf_get_presetcount(font) == 0) {
        if (font)
            tsf_close(font);
        throw std::runtime_error("Invalid SoundFont file.");
    }
    if (!tsf_set_max_voices(font, 128)) {
        tsf_close(font);
        throw std::runtime_error("Could not allocate instrument voices.");
    }
    for (int ch = 0; ch < 16; ++ch)
        if (!tsf_channel_set_presetindex(font, ch, 0)) {
            tsf_close(font);
            throw std::runtime_error("Could not allocate MIDI channels.");
        }
    tsf_set_output(font, TSF_STEREO_INTERLEAVED, (int)impl->rate, 0);
    if (impl->sf.font)
        tsf_close(impl->sf.font);
    impl->sf.font = font;
    name = file.getFileNameWithoutExtension();
    configure(impl->parameters, impl->drums);
}
std::unique_ptr<Instrument> Instrument::copy() const {
    auto result = std::make_unique<Instrument>();
    result->prepare(impl->rate);
    result->name = name;
    if (impl->sf.font) {
        auto *font = tsf_copy(impl->sf.font);
        if (!font)
            throw std::runtime_error("Could not share the instrument bank.");
        result->impl->sf.font = font;
        if (!tsf_set_max_voices(font, 128))
            throw std::runtime_error("Could not allocate instrument voices.");
        for (int ch = 0; ch < 16; ++ch)
            if (!tsf_channel_set_presetindex(font, ch, 0))
                throw std::runtime_error("Could not allocate MIDI channels.");
    }
    result->configure(impl->parameters, impl->drums);
    return result;
}
void Instrument::configure(const var &parameters, bool drums) {
    impl->parameters = parameters.clone();
    impl->drums = drums;
    auto &sf = impl->sf;
    auto controllers = get(parameters, "controllers"), velocity = get(parameters, "velocity"),
         cutoff = get(parameters, "cutoff");
    sf.gain = Decibels::decibelsToGain((float)jlimit(-24., 12., num(parameters, "gain")) +
                                       (float)jlimit(-96., 0., num(controllers, "volume")));
    sf.attack = (float)jlimit(0., 10., num(parameters, "attack"));
    sf.hold = (float)jlimit(0., 10., num(parameters, "hold", 10));
    sf.decay = (float)jlimit(.001, 10., num(parameters, "decay", 10));
    sf.sustain = (float)jlimit(0., 1., num(parameters, "sustain", 1));
    sf.release = (float)jlimit(.001, 20., num(parameters, "release", drums ? 20 : .3));
    sf.drums = drums;
    sf.monophonic = flag(controllers, "monophonic");
    const auto curve = str(velocity, "curve", "medium");
    sf.velocityCurve = curve == "soft" ? 0 : curve == "hard" ? 2 : 1;
    sf.modulationEnabled = flag(controllers, "modulation");
    sf.pitchVibratoEnabled = flag(controllers, "pitchBend");
    sf.cutoff = (float)jlimit(20., 20000., num(cutoff, "frequency", 20000));
    sf.velocityMinimum = (float)jlimit(20., 20000., num(velocity, "cutoffMinimum", 20000));
    sf.filterAttack = (float)jlimit(0., 10., num(cutoff, "attack"));
    sf.filterHold = (float)jlimit(0., 10., num(cutoff, "hold"));
    sf.filterDecay = (float)jlimit(.001, 10., num(cutoff, "decay", .3));
    sf.filterSustain = (float)jlimit(0., 1., num(cutoff, "sustain", 1));
    sf.filterRelease = (float)jlimit(.001, 20., num(cutoff, "release", .3));
    sf.filterDepth = (float)jlimit(0., 10., num(cutoff, "depth"));
}
void Instrument::stop() {
    impl->synth.allNotesOff(0, false);
    auto &sf = impl->sf;
    if (sf.font) {
        for (int i = 0; i < sf.font->voiceNum; ++i)
            sf.font->voices[i].playingPreset = -1;
        for (int ch = 0; ch < 16; ++ch)
            tsf_channel_midi_control(sf.font, ch, 64, 0);
    }
    sf.held.fill(0);
    sf.pressed.fill(false);
    sf.pedal.fill(false);
    sf.monoKey = -1;
    sf.filters.fill({});
    sf.smoothGain = 0;
}
void Instrument::render(AudioBuffer<float> &output, const MidiBuffer &midi, int samples,
                        int outputStart) {
    if (!impl->sf.font) {
        AudioBuffer<float> view(output.getArrayOfWritePointers(), output.getNumChannels(),
                                outputStart, samples);
        impl->synth.renderNextBlock(view, midi, 0, samples);
        return;
    }
    auto &sf = impl->sf;
    sf.envelope();
    const bool mono = sf.monophonic.load();
    if (mono != sf.previousMono) {
        stop();
        sf.previousMono = mono;
    }
    auto audio = [&](int start, int count) {
        float buffer[128];
        for (int offset = 0; offset < count;) {
            const int frames = std::min(64, count - offset);
            sf.controllersForBlock((unsigned)frames);
            sf.filtersForBlock((unsigned)frames);
            tsf_render_float(sf.font, buffer, frames, 0);
            const auto target = sf.gain.load();
            for (int n = 0; n < frames; ++n) {
                sf.smoothGain += (target - sf.smoothGain) * .005f;
                output.addSample(0, outputStart + start + offset + n,
                                 buffer[n * 2] * sf.smoothGain);
                if (output.getNumChannels() > 1)
                    output.addSample(1, outputStart + start + offset + n,
                                     buffer[n * 2 + 1] * sf.smoothGain);
            }
            offset += frames;
        }
    };
    int offset = 0;
    for (const auto &event : midi) {
        const int time = jlimit(offset, samples, event.samplePosition);
        audio(offset, time - offset);
        const auto message = event.getMessage();
        const int channel = message.getChannel() - 1;
        if (channel < 0 || channel > 15) {
            offset = time;
            continue;
        }
        if (message.isNoteOn())
            sf.noteOn(channel, message.getNoteNumber(), message.getVelocity());
        else if (message.isNoteOff())
            sf.noteOff(channel, message.getNoteNumber());
        else if (message.isController()) {
            const auto control = message.getControllerNumber(),
                       value = message.getControllerValue();
            if (control == 1)
                sf.modulationValues[(size_t)channel] = value / 127.f;
            else {
                tsf_channel_midi_control(sf.font, channel, control, value);
                if (control == 64) {
                    sf.pedal[(size_t)channel] = value >= 64;
                    if (!sf.pedal[(size_t)channel]) {
                        for (int key = 0; key < 128; ++key)
                            if (!sf.pressed[(size_t)(channel * 128 + key)])
                                sf.held[(size_t)(channel * 128 + key)] = 0;
                        if (sf.monoKey >= 0 && sf.monoKey / 128 == channel &&
                            !sf.held[(size_t)sf.monoKey])
                            sf.noteOff(channel, sf.monoKey % 128);
                    }
                } else if (control == 120 || control == 123) {
                    for (int key = 0; key < 128; ++key) {
                        sf.held[(size_t)(channel * 128 + key)] = 0;
                        sf.pressed[(size_t)(channel * 128 + key)] = false;
                    }
                    if (sf.monoKey >= 0 && sf.monoKey / 128 == channel)
                        sf.monoKey = -1;
                }
            }
        } else if (message.isPitchWheel())
            sf.bendValues[(size_t)channel] =
                jlimit(-1.f, 1.f, (message.getPitchWheelValue() - 8192) / 8192.f);
        offset = time;
    }
    audio(offset, samples - offset);
}
} // namespace catlive
