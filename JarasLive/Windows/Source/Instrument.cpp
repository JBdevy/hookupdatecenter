#include "Instrument.h"
#define TSF_IMPLEMENTATION
#include "../../Core/ThirdParty/TinySoundFont/tsf.h"
namespace catlive {
#include "SoundFontRenderer.h"
struct Instrument::Impl {
    SoundFontRenderer sf;
    double rate = 48000;
    var parameters;
    bool drums = false;
};
Instrument::Instrument() : impl(std::make_unique<Impl>()) {}
Instrument::~Instrument() = default;
void Instrument::swap(Instrument& other)noexcept {impl.swap(other.impl);name.swapWith(other.name);}
std::unique_ptr<Instrument> Instrument::prepareSoundFont(const File& file)const {
    auto result=std::make_unique<Instrument>();
    result->prepare(impl->rate);
    result->configure(impl->parameters,impl->drums);
    result->loadSoundFont(file);
    return result;
}
void Instrument::prepare(double rate) {
    impl->rate = rate;
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
    // MIDI alone is not an instrument. Sound starts only after an explicit
    // SoundFont load (or an inserted external instrument in the FX chain).
    if (!impl->sf.font) return;
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
