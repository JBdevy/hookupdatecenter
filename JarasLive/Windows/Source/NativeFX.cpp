#include "../../Core/Audio/SmoothBiquad.hpp"
#include "../../Core/Audio/CreativeEffects.hpp"
#include "NativeFX.h"
#include <cassert>
#include "Automation.h"
#include "CatDynamicsAssets.h"
#include "Include/CatDynamicsDSP.hpp"
#include "SharedClipAudio.h"
#include "FXPresets.h"
#include "DrummerPadAssets.h"
#include "CatSynthState.h"
namespace catlive {
namespace {
catlive::dsp::TriggerParameters readTriggerParameters(const var &settings) {
    const auto p = get(settings, "trigger"); catlive::dsp::TriggerParameters parameters;
    parameters.threshold = num(p, "threshold", -30); parameters.retrigger = num(p, "retrigger", .08);
    parameters.gain = num(p, "gain", 0); parameters.mix = num(p, "mix", 100);
    parameters.attack = num(p, "attack", 0); parameters.decay = num(p, "decay", .1);
    parameters.sustain = num(p, "sustain", 1); parameters.release = num(p, "release", .02);
    return parameters;
}
catlive::dsp::GateParameters readGateParameters(const var &settings) {
    const auto p = get(settings, "gate"); catlive::dsp::GateParameters parameters;
    parameters.threshold = num(p, "threshold", -40); parameters.attack = num(p, "attack", .001);
    parameters.decay = num(p, "decay", .02); parameters.hold = num(p, "hold", .05);
    parameters.release = num(p, "release", .1); parameters.highPass = num(p, "highPass", 20);
    parameters.lowPass = num(p, "lowPass", 20000); parameters.filterOutput = flag(p, "filterOutput");
    return parameters;
}
}
struct NativeFX::Effect {
    std::shared_ptr<jaras::audio::DrummerPad> drums;
    std::shared_ptr<jaras::audio::CatSynth> synth;
    StringArray drumFiles;
    std::unique_ptr<jaras::audio::CreativeEffectDSP> creative;
    catlive::dsp::Trigger trigger;
    catlive::dsp::Gate gate;
    catlive::dsp::TriggerParameters triggerParameters;
    catlive::dsp::GateParameters gateParameters;
    String sampleIdentity;
    std::array<std::atomic<float>, 3> dynamicsPeaks{};
    void recordPeak(size_t index, float value) noexcept {
        auto &peak = dynamicsPeaks[index];
        float previous = peak.load(std::memory_order_relaxed);
        while (previous < value && !peak.compare_exchange_weak(previous, value, std::memory_order_relaxed)) {}
    }
    ParameterPreview parameters;
    unsigned eqActive = 0;
    std::shared_ptr<analysis::Capture> eqAnalysis;
    double sampleRate = 48000;
    String kind;
    String key, externalConfiguration, pluginID;
    bool bypassed = false, retiredStem=false;
    std::shared_ptr<native::vst3::Processor> plugin;
    std::shared_ptr<const native::vst3::ARATimeline> araTimeline;
    std::shared_ptr<native::stem::Processor> stem;
    native::stem::Mix stemMix;
    std::array<native::vst3::MIDIEvent,4096> midi{};
    std::vector<jaras::audio::SmoothBiquad> eq[2];
    juce::dsp::Compressor<float> compressor;
    float limiterCeiling = 1, limiterRelease = 0, limiterGain = 1;
    Reverb reverb;
    std::unique_ptr<signalsmith::stretch::SignalsmithStretch<float>> pitch;
    AudioBuffer<float> pitchInput;
    std::unique_ptr<AudioBuffer<float>> wet;
    juce::dsp::IIR::Filter<float> highpass[2], lowpass[2];
    AudioBuffer<float> delay;
    int delayPosition = 0, delaySamples = 1;
    float feedback = 0, mix = 0, makeup = 1;
};
NativeFX::NativeFX() = default;
NativeFX::~NativeFX() = default;
void NativeFX::swap(NativeFX &other)noexcept {
    effects.swap(other.effects);
    std::swap(hasDynamicsMeter, other.hasDynamicsMeter);
    std::swap(reductionDB, other.reductionDB);
    unsupported.swapWith(other.unsupported);
}
NativeFX::DynamicsPreview NativeFX::dynamicsPreview(const var &settings) {
    const auto trigger = readTriggerParameters(settings); const auto gate = readGateParameters(settings);
    return {{trigger.threshold,trigger.retrigger,trigger.gain,trigger.mix,trigger.attack,trigger.decay,trigger.sustain,trigger.release},
            {gate.threshold,gate.attack,gate.decay,gate.hold,gate.release,gate.highPass,gate.lowPass},gate.filterOutput};
}
void NativeFX::previewDynamics(const String &key, const DynamicsPreview &snapshot) noexcept {
    for (auto &effect : effects) if (effect->key == key) {
        if (effect->kind == "CatLive Trigger") {
            const auto &v = snapshot.trigger;
            effect->triggerParameters = {v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7]}; effect->trigger.setParameters(effect->triggerParameters);
        } else if (effect->kind == "Cat Gate") {
            const auto &v = snapshot.gate;
            effect->gateParameters = {v[0],v[1],v[2],v[3],v[4],v[5],v[6],snapshot.filterOutput}; effect->gate.setParameters(effect->gateParameters);
        }
    }
}

NativeFX::ParameterPreview NativeFX::parameterPreview(const String &kind, const var &value, double sampleRate) {
    ParameterPreview result; result.sampleRate=sampleRate; auto &v = result.values;
    using C = juce::dsp::IIR::Coefficients<float>;
    auto coefficients = [](const C::Ptr &source, auto &target) { std::copy_n(source->getRawCoefficients(), 5, target.begin()); };
    if (kind == "EQ") {
        result.kind = ParameterPreview::equalizer; result.channels = fxpresets::channels(value, kind);
        for (const auto &band : list(get(value, "bands"))) {
            if (!flag(band, "enabled", true)) continue;
            const float frequency = (float)jlimit(20., std::min(20000., sampleRate * .45), num(band, "frequency", 1000));
            const float q = (float)jlimit(.1, 18., num(band, "q", .707));
            const float gain = Decibels::decibelsToGain((float)jlimit(-24., 24., num(band, "gain")));
            const auto type = str(band, "type", "bell");
            const bool cut = type == "lowCut" || type == "highCut";
            const int order = cut ? jlimit(1, 32, (int)num(band, "slope", 12) / 6) : 2;
            for (int stage = 0; stage < std::max(1, order / 2) && result.eqCount < result.eq.size(); ++stage) {
                C::Ptr c;
                if (cut && order == 1) {
                    const double k = std::tan(MathConstants<double>::pi * frequency / sampleRate);
                    const float b0 = (float)((type == "lowCut" ? 1 : k) / (1 + k));
                    c = new C(b0, type == "lowCut" ? -b0 : b0, 0, 1, (float)((k - 1) / (k + 1)), 0);
                } else if (cut) {
                    const float stageQ = (float)(1 / (2 * std::sin(MathConstants<double>::pi * (2 * stage + 1) / (2 * order))));
                    c = type == "lowCut" ? C::makeHighPass(sampleRate, frequency, stageQ) : C::makeLowPass(sampleRate, frequency, stageQ);
                } else c = type == "lowShelf" ? C::makeLowShelf(sampleRate, frequency, q, gain)
                         : type == "highShelf" ? C::makeHighShelf(sampleRate, frequency, q, gain)
                         : C::makePeakFilter(sampleRate, frequency, q, gain);
                coefficients(c, result.eq[result.eqCount++]);
            }
        }
    } else if (kind == "Compressor") {
        result.kind = ParameterPreview::compressor; result.channels = fxpresets::channels(value, kind);
        v[0]=(float)jlimit(-60.,0.,num(value,"threshold",-20)); v[1]=(float)jlimit(1.,20.,num(value,"ratio",4));
        v[2]=(float)jlimit(.1,200.,num(value,"attack",.005)*1000); v[3]=(float)jlimit(10.,3000.,num(value,"release",.1)*1000);
        v[4]=Decibels::decibelsToGain((float)jlimit(-12.,24.,num(value,"makeup")));
    } else if (kind == "Delay") {
        result.kind = ParameterPreview::delay; result.channels = fxpresets::channels(value, kind);
        v[0]=(float)std::round(jlimit(.01,2.,num(value,"delayTime",.25))*sampleRate);
        v[1]=(float)jlimit(0.,.9,num(value,"feedback",25)/100); v[2]=(float)jlimit(0.,1.,num(value,"delayMix",20)/100);
    } else if (kind == "Reverb") {
        result.kind = ParameterPreview::reverb; result.channels = fxpresets::channels(value, kind);
        v[0]=(float)jlimit(.05,.98,num(value,"reverbDecay",2)/25+.2+num(value,"reverbRoom",1)*.15);
        v[1]=(float)jlimit(0.,1.,num(value,"reverbMix",20)/100);
        coefficients(C::makeHighPass(sampleRate,(float)jlimit(20.,2000.,num(value,"reverbLowCut",80))),result.highPass);
        coefficients(C::makeLowPass(sampleRate,(float)jlimit(2000.,std::min(20000.,sampleRate*.45),num(value,"reverbHighCut",12000))),result.lowPass);
    } else if (kind == "Limiter") {
        result.kind = ParameterPreview::limiter; const auto p=get(value,"limiter");
        v[0]=Decibels::decibelsToGain((float)jlimit(-24.,0.,num(p,"ceiling",-.1)));
        v[1]=(float)std::exp(-1/(sampleRate*jlimit(.01,3.,num(p,"release",.1))));
        v[2]=Decibels::decibelsToGain((float)jlimit(-24.,24.,num(p,"inputGain")));
    } else if (kind == "Pitch") {
        result.kind = ParameterPreview::pitch;
        if (flag(value, "pitchEnabled")) {
            v[0] = (float)jlimit(-12., 12., num(value, "pitchSemitones"));
            v[1] = (float)jlimit(-12., 12., num(value, "pitchFormant"));
        }
    } else if (const auto *spec = jaras::audio::creativeEffect(utf8(kind))) {
        result.kind = ParameterPreview::creative;
        const auto group = get(value, Identifier(spec->field));
        for (size_t i = 0; i < spec->parameters.size() && spec->parameters[i].key; ++i) {
            const auto &p = spec->parameters[i];
            v[i] = (float)num(group, Identifier(p.key), p.initial);
        }
    }
    return result;
}
void NativeFX::previewParameters(const String &key, const ParameterPreview &parameters) noexcept {
    for (auto &effect : effects) if (effect->key == key && effect->parameters.kind == parameters.kind && effect->sampleRate == parameters.sampleRate) {
        auto &e=*effect; const auto &v=parameters.values;
        switch(parameters.kind) {
        case ParameterPreview::equalizer:
            for (int ch=0;ch<2;++ch) for (unsigned i=0;i<parameters.eqCount && i<e.eq[ch].size();++i) {
                if (i>=e.eqActive) e.eq[ch][i].setImmediate(parameters.eq[i].data());
                else e.eq[ch][i].setTarget(parameters.eq[i].data());
            }
            e.eqActive=parameters.eqCount;break;
        case ParameterPreview::compressor:
            e.compressor.setThreshold(v[0]);e.compressor.setRatio(v[1]);e.compressor.setAttack(v[2]);e.compressor.setRelease(v[3]);e.makeup=v[4];break;
        case ParameterPreview::delay:e.delaySamples=(int)v[0];e.feedback=v[1];e.mix=v[2];break;
        case ParameterPreview::reverb: {
            Reverb::Parameters p;p.roomSize=v[0];p.damping=.5f;p.wetLevel=1;p.dryLevel=0;p.width=1;
            e.reverb.setParameters(p);e.mix=v[1];
            for(int ch=0;ch<2;++ch) {
                std::copy(parameters.highPass.begin(),parameters.highPass.end(),e.highpass[ch].coefficients->getRawCoefficients());
                std::copy(parameters.lowPass.begin(),parameters.lowPass.end(),e.lowpass[ch].coefficients->getRawCoefficients());
            }
            break;
        }
        case ParameterPreview::limiter:e.limiterCeiling=v[0];e.limiterRelease=v[1];e.makeup=v[2];break;
        case ParameterPreview::pitch:
            if (e.pitch) {
                e.pitch->setTransposeSemitones(v[0]);
                e.pitch->setFormantSemitones(v[1]);
            }
            break;
        case ParameterPreview::creative:
        case ParameterPreview::none:break;
        }
        e.parameters=parameters;
    }
}

void NativeFX::adoptDynamicsState(NativeFX &previous) noexcept {
    for (auto &next : effects) for (auto &old : previous.effects) {
        if (next->key != old->key || next->kind != old->kind || next->sampleRate != old->sampleRate) continue;
        if (next->parameters.kind != ParameterPreview::none && next->parameters.kind == old->parameters.kind) {
            const auto parameters=next->parameters;
            // Keep the admitted filter/delay/reverb histories and analyzer. The
            // unused prepared object is retired by the caller outside its lock.
            std::swap(next, old); previewParameters(next->key, parameters);
        } else if (next->kind == "CatLive Trigger" && next->sampleIdentity == old->sampleIdentity && old->trigger.hasSample()) {
            std::swap(next->trigger, old->trigger); next->trigger.setParameters(next->triggerParameters);
        } else if (next->kind == "Cat Gate") {
            std::swap(next->gate, old->gate); next->gate.setParameters(next->gateParameters);
        }
    }
}
std::shared_ptr<jaras::audio::DrummerPad> NativeFX::drummerVoice(const String &key) const {
    for (const auto &effect : effects) if (effect->key == key) return effect->drums;
    return {};
}
std::shared_ptr<jaras::audio::CatSynth> NativeFX::synthVoice(const String &key) const {
    for (const auto &effect : effects) if (effect->key == key) return effect->synth;
    return {};
}
static std::shared_ptr<const jaras::audio::DrumSample> loadDrumPCM(const File &file) {
    static std::mutex mutex;
    static std::map<String, std::weak_ptr<const jaras::audio::DrumSample>> cache;
    const String identity = file.getFullPathName() + "|" + String(file.getLastModificationTime().toMilliseconds());
    { std::lock_guard<std::mutex> guard(mutex); if (auto found = cache[identity].lock()) return found; }
    AudioFormatManager formats; registerAudioFormats(formats);
    auto reader = std::unique_ptr<AudioFormatReader>(formats.createReaderFor(file));
    if (!reader || reader->sampleRate <= 0 || reader->sampleRate > 384000 || reader->lengthInSamples <= 0 ||
        reader->lengthInSamples > 60.01 * reader->sampleRate || !reader->numChannels) return {};
    const int frames = int(reader->lengthInSamples);
    AudioBuffer<float> decoded(2, frames);
    if (!reader->read(&decoded, 0, frames, 0, true, true)) return {};
    auto pcm = std::make_shared<jaras::audio::DrumSample>();
    pcm->rate = reader->sampleRate;
    pcm->left.assign(decoded.getReadPointer(0), decoded.getReadPointer(0)+frames);
    if (reader->numChannels > 1) pcm->right.assign(decoded.getReadPointer(1), decoded.getReadPointer(1)+frames);
    { std::lock_guard<std::mutex> guard(mutex); cache[identity] = pcm; }
    return pcm;
}
void NativeFX::prepare(const var &settings, double sampleRate, const NativeFX *previous,bool offline,bool prewarm,
                       const Dispatcher &pluginDispatcher, const File &mediaDirectory,
                       std::shared_ptr<const native::vst3::ARATimeline> araTimeline) {
    effects.clear();
    unsupported.clear();
    hasDynamicsMeter = false;
    reductionDB = -1.f;
    auto append = [&](String kind, const String &key, const var &value) {
        if (kind == "CatSynth") {
            if (!flag(value, "catSynthEnabled")) return;
            auto e = std::make_unique<Effect>();
            e->kind = kind; e->key = key; e->sampleRate = sampleRate;
            if (previous) for (const auto &old : previous->effects)
                if (old->key == key && old->synth && old->sampleRate == sampleRate) e->synth = old->synth;
            if (!e->synth) e->synth = std::make_shared<jaras::audio::CatSynth>(sampleRate);
            e->synth->configure(synthState::patch(get(value, "catSynth")));
            effects.push_back(std::move(e));
            return;
        }
        if (const auto count = drummer::count(kind)) {
            if (!flag(value, drummer::enabledField(count))) return;
            const auto kit = drummer::kit(value, count);
            auto e = std::make_unique<Effect>();
            e->kind = kind; e->key = key; e->sampleRate = sampleRate;
            for (const auto &pad : list(get(kit, "pads"))) e->drumFiles.add(str(pad,"sample"));
            if (previous) for (const auto &old : previous->effects)
                if (old->key == key && old->drums && old->sampleRate == sampleRate && old->drumFiles == e->drumFiles) e->drums = old->drums;
            if (!e->drums) {
                e->drums = std::make_shared<jaras::audio::DrummerPad>(unsigned(count), sampleRate);
                for (int i=0; i<count; ++i) if (e->drumFiles[i].isNotEmpty()) {
                    const auto sample = loadDrumPCM(drummer::resolve(e->drumFiles[i]));
                    if (!sample) unsupported.addIfNotAlreadyThere(kind + ": " + e->drumFiles[i]);
                    e->drums->setSample(unsigned(i), sample);
                }
            }
            drummer::configure(*e->drums, kit);
            effects.push_back(std::move(e)); return;
        }
        if (kind == "Compressor" || kind == "Limiter" || kind == "Soft Clipper") hasDynamicsMeter = true;
        if (const auto *spec = jaras::audio::creativeEffect(utf8(kind))) {
            if (!flag(value, Identifier(spec->enabledField))) return;
            auto e = std::make_unique<Effect>();
            e->kind = kind; e->key = key; e->sampleRate = sampleRate;
            e->creative = std::make_unique<jaras::audio::CreativeEffectDSP>(spec->kind);
            e->creative->prepare(sampleRate);
            e->parameters = parameterPreview(kind, value, sampleRate);
            effects.push_back(std::move(e));
            return;
        }
        if (kind == "CatLive Trigger" || kind == "Cat Gate") {
            if (!flag(value, kind == "CatLive Trigger" ? Identifier("triggerEnabled") : Identifier("gateEnabled"))) return;
            auto e = std::make_unique<Effect>(); e->kind = kind; e->key = key; e->sampleRate = sampleRate;
            if (kind == "CatLive Trigger") {
                const auto p = get(value, "trigger");
                const auto parameters = readTriggerParameters(value);
                e->triggerParameters = parameters; e->trigger.setParameters(parameters);
                const auto path = str(p, "samplePath");
                if (path.isNotEmpty()) {
                    try {
                        auto file = ProjectCodec::resolveMedia(mediaDirectory, utf8(path));
                        e->sampleIdentity = file.getFullPathName() + ":" + String(file.getSize()) + ":" + String(file.getLastModificationTime().toMilliseconds());
                        const bool reuse = previous && std::any_of(previous->effects.begin(), previous->effects.end(), [&](const auto &old) {
                            return old->kind == kind && old->key == key && old->sampleRate == sampleRate && old->sampleIdentity == e->sampleIdentity && old->trigger.hasSample();
                        });
                        if (!reuse) {
                        AudioFormatManager formats; registerAudioFormats(formats);
                        auto reader = dynamicsAssets::reader(file, formats);
                        const int frames = (int)reader->lengthInSamples;
                        AudioBuffer<float> decoded(2, frames);
                        if (!reader->read(&decoded, 0, frames, 0, true, true)) throw std::runtime_error("Could not read the trigger sample.");
                        std::vector<float> left(decoded.getReadPointer(0), decoded.getReadPointer(0) + frames);
                        const auto *right = decoded.getReadPointer(reader->numChannels > 1 ? 1 : 0);
                        e->trigger.setSample(std::move(left), std::vector<float>(right, right + frames), reader->sampleRate);
                        }
                    } catch (const std::exception &error) {
                        // Missing FX media must not prevent playback or recording.
                        unsupported.addIfNotAlreadyThere(kind + ": " + path + " - " + String::fromUTF8(error.what()));
                    }
                }
            } else {
                const auto parameters = readGateParameters(value);
                e->gateParameters = parameters; e->gate.setParameters(parameters);
            }
            effects.push_back(std::move(e)); return;
        }
        // Read older projects without starting the removed realtime separator.
        if (kind == native::stem::effectName || kind == "Arpeggiator") return;
        String enabledKey = kind == "EQ"           ? "eqEnabled"
                            : kind == "Compressor" ? "compressorEnabled"
                            : kind == "Delay"      ? "delayEnabled"
                            : kind == "Reverb"     ? "reverbEnabled"
                            : kind == "Limiter"    ? "limiterEnabled"
                                                   : String();
        if (enabledKey.isNotEmpty() && !flag(value, Identifier(enabledKey)))
            return;
        if (kind == "Instruments" && flag(value, "instrumentBypassed"))
            return;
        if(kind=="Instruments")return; // The MIDI voice bank belongs to the audio bus.
        if (kind != "EQ" && kind != "Compressor" && kind != "Delay" && kind != "Reverb" &&
            kind != "Limiter" && kind != "Pitch") {
            unsupported.addIfNotAlreadyThere(kind);
            return;
        }
        auto e = std::make_unique<Effect>();
        e->kind = kind; e->key = key; e->sampleRate = sampleRate;
        e->parameters = parameterPreview(kind, value, sampleRate);
        if (kind == "EQ" && !offline) e->eqAnalysis = std::make_shared<analysis::Capture>(sampleRate);
        juce::dsp::ProcessSpec spec{sampleRate, 4096, 2};
        if (kind == "Pitch") {
            e->pitch = std::make_unique<signalsmith::stretch::SignalsmithStretch<float>>(0);
            e->pitch->presetDefault(2, (float)sampleRate);
            e->pitch->setNeutralWarmup(true);
            e->pitch->setTransposeSemitones(e->parameters.values[0]);
            e->pitch->setFormantSemitones(e->parameters.values[1]);
            e->pitchInput.setSize(2, 4096);
        }
        if (kind == "EQ")
            for (auto band : list(get(value, "bands"))) {
                if (!flag(band, "enabled", true))
                    continue;
                auto frequency =
                    jlimit(20.0, std::min(20000.0, sampleRate * .45), num(band, "frequency", 1000));
                auto q = jlimit(.1, 18.0, num(band, "q", .707));
                auto gain = Decibels::decibelsToGain(jlimit(-24.0, 24.0, num(band, "gain")));
                auto type = str(band, "type", "bell");
                juce::dsp::IIR::Coefficients<float>::Ptr coefficients;
                if (type == "lowCut")
                    coefficients = juce::dsp::IIR::Coefficients<float>::makeHighPass(
                        sampleRate, (float)frequency, (float)q);
                else if (type == "highCut")
                    coefficients = juce::dsp::IIR::Coefficients<float>::makeLowPass(
                        sampleRate, (float)frequency, (float)q);
                else if (type == "lowShelf")
                    coefficients = juce::dsp::IIR::Coefficients<float>::makeLowShelf(
                        sampleRate, (float)frequency, (float)q, (float)gain);
                else if (type == "highShelf")
                    coefficients = juce::dsp::IIR::Coefficients<float>::makeHighShelf(
                        sampleRate, (float)frequency, (float)q, (float)gain);
                else
                    coefficients = juce::dsp::IIR::Coefficients<float>::makePeakFilter(
                        sampleRate, (float)frequency, (float)q, (float)gain);
                const bool cut = type == "lowCut" || type == "highCut";
                int order = jlimit(1, 32, (int)num(band, "slope", 12) / 6),
                    stages = cut ? std::max(1, order / 2) : 1;
                for (int ch = 0; ch < 2; ++ch)
                    for (int stage = 0; stage < stages; ++stage) {
                        auto stageCoefficients = coefficients;
                        if (cut && order == 1) {
                            double k = std::tan(MathConstants<double>::pi * frequency / sampleRate),
                                   b0 = (type == "lowCut" ? 1 : k) / (1 + k);
                            stageCoefficients = new juce::dsp::IIR::Coefficients<float>(
                                (float)b0, (float)(type == "lowCut" ? -b0 : b0), 0, 1,
                                (float)((k - 1) / (k + 1)), 0);
                        } else if (cut) {
                            float butterworthQ =
                                (float)(1 / (2 * std::sin(MathConstants<double>::pi *
                                                          (2 * stage + 1) / (2 * order))));
                            stageCoefficients =
                                type == "lowCut" ? juce::dsp::IIR::Coefficients<float>::makeHighPass(
                                                       sampleRate, (float)frequency, butterworthQ)
                                                 : juce::dsp::IIR::Coefficients<float>::makeLowPass(
                                                       sampleRate, (float)frequency, butterworthQ);
                        }
                        e->eq[ch].emplace_back(stageCoefficients->getRawCoefficients(),sampleRate);
                    }
            }
        if (kind == "EQ") {
            e->eqActive = (unsigned)e->eq[0].size();
            for (auto &channel : e->eq) while (channel.size() < ParameterPreview::maximumEQStages) {
                channel.emplace_back(); channel.back().setSampleRate(sampleRate);
            }
        }
        if (kind == "Compressor") {
            e->compressor.prepare(spec);
            e->compressor.setThreshold((float)jlimit(-60.0, 0.0, num(value, "threshold", -20)));
            e->compressor.setRatio((float)jlimit(1.0, 20.0, num(value, "ratio", 4)));
            e->compressor.setAttack((float)jlimit(.1, 200.0, num(value, "attack", .005) * 1000));
            e->compressor.setRelease((float)jlimit(10.0, 3000.0, num(value, "release", .1) * 1000));
            e->makeup = Decibels::decibelsToGain((float)jlimit(-12.0, 24.0, num(value, "makeup")));
        }
        if (kind == "Limiter") {
            auto limiter = get(value, "limiter");
            e->limiterCeiling = Decibels::decibelsToGain((float)jlimit(-24.0, 0.0, num(limiter, "ceiling", -.1)));
            e->limiterRelease = (float)std::exp(-1.0 / (sampleRate * jlimit(.01, 3.0, num(limiter, "release", .1))));
            e->makeup =
                Decibels::decibelsToGain((float)jlimit(-24.0, 24.0, num(limiter, "inputGain")));
        }
        if (kind == "Delay") {
            e->delaySamples =
                (int)std::round(jlimit(.01, 2.0, num(value, "delayTime", .25)) * sampleRate);
            e->delay.setSize(2, (int)std::ceil(sampleRate * 2) + 1);
            e->delay.clear();
            e->feedback = (float)jlimit(0.0, .9, num(value, "feedback", 25) / 100);
            e->mix = (float)jlimit(0.0, 1.0, num(value, "delayMix", 20) / 100);
        }
        if (kind == "Reverb") {
            e->wet = std::make_unique<AudioBuffer<float>>(2, 4096);
            e->reverb.setSampleRate(sampleRate);
            Reverb::Parameters params;
            params.roomSize = (float)jlimit(.05, .98,
                                            num(value, "reverbDecay", 2) / 25 + .2 +
                                                num(value, "reverbRoom", 1) * .15);
            params.damping = .5f;
            params.wetLevel = 1;
            params.dryLevel = 0;
            params.width = 1;
            e->mix = (float)jlimit(0.0, 1.0, num(value, "reverbMix", 20) / 100);
            e->reverb.setParameters(params);
            for (int ch = 0; ch < 2; ++ch) {
                e->highpass[ch].coefficients = juce::dsp::IIR::Coefficients<float>::makeHighPass(
                    sampleRate, (float)jlimit(20.0, 2000.0, num(value, "reverbLowCut", 80)));
                e->lowpass[ch].coefficients = juce::dsp::IIR::Coefficients<float>::makeLowPass(
                    sampleRate, (float)jlimit(2000.0, std::min(20000.0, sampleRate * .45),
                                              num(value, "reverbHighCut", 12000)));
            }
        }
        effects.push_back(std::move(e));
    };
    const auto inserted = list(get(settings, "inserted"));
    for (auto raw : inserted) {
        auto key = raw.toString();
        if (key.startsWith("External:")) {
            try {
            for (auto plugin : list(get(settings,"externalPlugins"))) if (key=="External:"+str(plugin,"id")) {
                // Keep opaque states editable/undoable when a project arrives
                // from a computer where this plug-in was installed elsewhere.
                if(!File(str(plugin,"path")).exists()) {
                    if(offline)throw std::runtime_error(utf8(str(plugin,"name",key)+": plugin VST3 ausente"));
                    unsupported.addIfNotAlreadyThere(str(plugin,"name",key)+": plugin VST3 ausente");
                    break;
                }
                auto e=std::make_unique<Effect>();e->kind="External";e->key=key;e->pluginID=str(plugin,"id");e->bypassed=flag(plugin,"bypassed");
                if (!inserted.isEmpty() && raw == inserted[0]) e->araTimeline = araTimeline;
                auto configuration=plugin.clone();configuration.getDynamicObject()->removeProperty("bypassed");
                e->externalConfiguration=JSON::toString(configuration,true);
                if(previous)for(const auto &old:previous->effects)
                    if(old->key==key&&old->externalConfiguration==e->externalConfiguration&&old->araTimeline==e->araTimeline)e->plugin=old->plugin;
                if(!e->plugin) {
                    native::vst3::Description description;
                    description.path=std::filesystem::u8path(utf8(str(plugin,"path")));
                    description.classID=utf8(str(plugin,"classID"));description.name=utf8(str(plugin,"name"));description.category=utf8(str(plugin,"category"));
                    native::vst3::State state;
                    auto decode=[&](const char *field,std::vector<uint8_t> &bytes){
                        MemoryOutputStream stream;
                        const auto encoded=str(plugin,field);
                        if(encoded.isNotEmpty()&&!Base64::convertFromBase64(stream,encoded))throw std::runtime_error("Estado VST3 inválido.");
                        auto *data=static_cast<const uint8_t*>(stream.getData());
                        if(stream.getDataSize())bytes.assign(data,data+stream.getDataSize());
                    };
                    decode("componentState",state.component);decode("controllerState",state.controller);
                    if (e->araTimeline) decode("araState",state.ara);
                    // A queued constructor may finish after its load was
                    // cancelled. Own its result independently of this Effect.
                    auto result=std::make_shared<std::shared_ptr<native::vst3::Processor>>();
                    const auto *manager=MessageManager::getInstanceWithoutCreating();
                    const bool affine=bool(pluginDispatcher)||(manager&&manager->isThisTheMessageThread());
                    auto create=[result,description=std::move(description),state=std::move(state),sampleRate,affine,timeline=e->araTimeline] {
                        auto *processor=new native::vst3::Processor(description,state,sampleRate,4096,timeline.get());
                        *result=std::shared_ptr<native::vst3::Processor>(processor,[affine](auto *value) {
                            auto *manager=MessageManager::getInstanceWithoutCreating();
                            if(affine&&manager&&!manager->isThisTheMessageThread()) {
                                // Controller termination (including native child
                                // windows) follows construction's UI affinity.
                                if(MessageManager::callAsync([value]{delete value;}))return;
                            }
                            delete value;
                        });
                    };
                    if(pluginDispatcher)pluginDispatcher(std::move(create));else create();
                    e->plugin=std::move(*result);
                }
                effects.push_back(std::move(e));
                break;
            }
            }catch(const PreparationCancelled &){throw;}
            catch(const std::exception &e){if(previous || offline)throw;unsupported.addIfNotAlreadyThere(key+": "+String::fromUTF8(e.what()));}
            continue;
        }
        auto value = settings;
        auto kind = key;
        for (auto instance : list(get(settings, "instances")))
            if ("Native:" + str(instance, "id") == key ||
                "Instance:" + str(instance, "id") == key) {
                kind = str(instance, "kind");
                value = get(instance, "settings");
                break;
            }
        append(kind, key, value);
    }
}
std::shared_ptr<analysis::Capture> NativeFX::eqAnalysis(const String &key) const {
    for (const auto &effect : effects) if (effect->key == key) return effect->eqAnalysis;
    return {};
}
std::shared_ptr<native::vst3::Processor> NativeFX::external(const String &key) const {
    for(const auto &effect:effects)if(effect->key==key)return effect->plugin;
    return {};
}
void NativeFX::captureExternalState(var &settings) const {
    for(auto plugin:list(get(settings,"externalPlugins"))) {
        auto processor=external("External:"+str(plugin,"id"));if(!processor)continue;
        const auto state=processor->state();
        put(plugin,"componentState",Base64::toBase64(state.component.data(),state.component.size()));
        put(plugin,"controllerState",Base64::toBase64(state.controller.data(),state.controller.size()));
        if (!state.ara.empty()) put(plugin,"araState",Base64::toBase64(state.ara.data(),state.ara.size()));
        auto configuration=plugin.clone();configuration.getDynamicObject()->removeProperty("bypassed");
        for(const auto &effect:effects)if(effect->plugin==processor)effect->externalConfiguration=JSON::toString(configuration,true);
    }
}
unsigned NativeFX::latencyFrames() const {
    unsigned value = 0;
    for (const auto &effect : effects) {
        if (effect->stem) value += effect->stem->availableLatency();
        if (effect->pitch) value += unsigned(effect->pitch->inputLatency() + effect->pitch->outputLatency());
    }
    return value;
}
unsigned NativeFX::readyLatencyFrames(bool releaseRemoved) const {
    unsigned value=0;
    for (const auto &effect : effects) {
        if (effect->stem && !(releaseRemoved && effect->retiredStem))
            value += effect->stem->pending() ? effect->stem->latency() : effect->stem->availableLatency();
        if (effect->pitch) value += unsigned(effect->pitch->inputLatency() + effect->pitch->outputLatency());
    }
    return value;
}
void NativeFX::collectReadyStemActivations(std::vector<std::shared_ptr<native::stem::Processor>> &pending) const {
    for(const auto &e:effects)if(e->stem&&!e->retiredStem&&e->stem->pending()&&
        std::find(pending.begin(),pending.end(),e->stem)==pending.end())pending.push_back(e->stem);
}
void NativeFX::activateStemLatency(bool force){for(auto &e:effects)if(e->stem)e->stem->activate(force);}
bool NativeFX::pendingStemChange()const {for(auto &e:effects)if(e->stem&&(e->retiredStem||e->stem->pending()))return true;return false;}
void NativeFX::holdRemovedStems(const NativeFX &previous){
    for(size_t index=0;index<previous.effects.size();index++){
        const auto &old=previous.effects[index];
        if(!old->stem||!old->stem->availableLatency()||std::any_of(effects.begin(),effects.end(),[&](const auto &e){return e->key==old->key;}))continue;
        auto e=std::make_unique<Effect>();e->kind=old->kind;e->key=old->key;e->stem=old->stem;e->stemMix=old->stemMix;e->stemMix.enabled=false;e->retiredStem=true;
        e->stem->configure(e->stemMix);effects.insert(effects.begin()+std::min(index,effects.size()),std::move(e));
    }
}
void NativeFX::releaseRemovedStems(){effects.erase(std::remove_if(effects.begin(),effects.end(),[](const auto &e){return e->retiredStem;}),effects.end());}
void NativeFX::prepareRetirement(NativeFX& destination) const {
    destination.effects.reserve(destination.effects.size()+effects.size());
}
void NativeFX::retireRemovedStems(NativeFX& destination) noexcept {
    assert(destination.effects.capacity()-destination.effects.size()>=effects.size());
    size_t retained=0;
    for(size_t index=0;index<effects.size();++index) {
        if(effects[index]->retiredStem)destination.effects.push_back(std::move(effects[index]));
        else {
            if(retained!=index)effects[retained]=std::move(effects[index]);
            ++retained;
        }
    }
    // Every discarded tail slot is moved-from: shrinking deletes no effect.
    effects.resize(retained);
}
void NativeFX::shareStems(const NativeFX &source){for(auto &e:effects)if(e->stem)for(const auto &other:source.effects)if(e->key==other->key&&other->stem)e->stem=other->stem;}
bool NativeFX::hasActiveStem()const {for(const auto &e:effects)if(e->stem&&e->stem->availableLatency())return true;return false;}
void NativeFX::resetStems(){for(auto &e:effects)if(e->stem)e->stem->reset();}
native::stem::Status NativeFX::stemStatus(const String &key)const {for(const auto &e:effects)if(e->key==key&&e->stem)return e->stem->status();return {};}
void NativeFX::previewStemMix(const String &key,const native::stem::Mix &mix){for(auto &e:effects)if(e->key==key&&e->stem)e->stem->configure(mix);}
void NativeFX::waitForStems(){for(auto &e:effects)if(e->stem&&e->stemMix.enabled)e->stem->waitReady();}
void NativeFX::checkStemErrors()const {for(const auto &e:effects)if(e->stem&&e->stemMix.enabled){const auto s=e->stem->status();if(s.state=="fault")throw std::runtime_error(s.error);}}
bool NativeFX::hasExternal() const {for(const auto &effect:effects)if(effect->plugin)return true;return false;}
bool NativeFX::hasARA() const {
    return std::any_of(effects.begin(),effects.end(),[](const auto &effect){return effect->plugin&&effect->plugin->hasARA();});
}
void NativeFX::applyAutomation(const AutomationProgram &program, double time) {
    if (effects.empty()) return;
    for (const auto &curve : program.curves) if (curve.target == AutomationCurve::externalFX)
        for (const auto &effect : effects) if (effect->plugin && !effect->bypassed &&
            effect->pluginID == curve.plugin)
            effect->plugin->automate(curve.parameter, curve.value(time));
}
std::array<float, 3> NativeFX::takeDynamicsLevels(const String &key) const {
    for (const auto &effect : effects) if (effect->key == key) {
        auto &p = effect->dynamicsPeaks;
        return {p[0].exchange(0), p[1].exchange(0), p[2].exchange(0)};
    }
    return {};
}
void NativeFX::processIdleEditors(int samples,double seconds,bool playing,const jaras::PluginTempoMap *tempoMap) {
    if (effects.empty()) return;
    const auto transport = tempoMap ? tempoMap->at(seconds,playing) : jaras::PluginTempoMap{}.at(seconds,playing);
    for(auto &effect:effects)if(effect->plugin)effect->plugin->processEditorSilence(samples,transport);
}
void NativeFX::process(AudioBuffer<float> &buffer, int samples,double seconds,bool playing,const MidiBuffer *midi,double stemSeconds,const jaras::PluginTempoMap *tempoMap,bool renderARA) {
    reductionDB = hasDynamicsMeter ? 0.f : -1.f;
    if (effects.empty()) return;
    ScopedNoDenormals noDenormals;
    for (auto &e : effects) {
        if (e->synth) {
            auto *left = buffer.getWritePointer(0);
            auto *right = buffer.getNumChannels() > 1 ? buffer.getWritePointer(1) : nullptr;
            int cursor = 0;
            e->synth->beginBlock();
            if (midi) for (const auto event : *midi) {
                const auto at = jlimit(cursor, samples, event.samplePosition);
                if (at > cursor) e->synth->render(left+cursor, right ? right+cursor : nullptr, unsigned(at-cursor));
                cursor = at;
                if (event.numBytes >= 3) e->synth->midi(event.data[0], event.data[1], event.data[2]);
            }
            if (samples > cursor) e->synth->render(left+cursor, right ? right+cursor : nullptr, unsigned(samples-cursor));
            continue;
        }
        if (e->drums) {
            auto *left = buffer.getWritePointer(0);
            auto *right = buffer.getNumChannels() > 1 ? buffer.getWritePointer(1) : nullptr;
            int cursor = 0;
            if (midi) for (const auto event : *midi) {
                const auto at = jlimit(cursor, samples, event.samplePosition);
                if (at > cursor) e->drums->render(left+cursor, right ? right+cursor : nullptr, unsigned(at-cursor));
                cursor = at;
                if (event.numBytes >= 3 && (event.data[0] & 0xf0) == 0x90) e->drums->midi(event.data[1], event.data[2]);
                if (event.numBytes >= 3 && (event.data[0] & 0xf0) == 0xb0 && (event.data[1] == 120 || event.data[1] == 123)) e->drums->silence();
            }
            if (samples > cursor) e->drums->render(left+cursor, right ? right+cursor : nullptr, unsigned(samples-cursor));
            continue;
        }
        if (e->creative) {
            const auto transport = tempoMap ? tempoMap->at(seconds, playing) : jaras::PluginTempoMap{}.at(seconds, playing);
            const auto &v = e->parameters.values;
            e->creative->process(buffer.getWritePointer(0), buffer.getNumChannels() > 1 ? buffer.getWritePointer(1) : nullptr,
                unsigned(samples), v, transport);
            if (e->kind == "Soft Clipper") reductionDB = std::max(reductionDB, e->creative->gainReductionDB());
            continue;
        }
        const auto channels = e->parameters.channels;
        if (e->kind == "CatLive Trigger")
            e->trigger.process(buffer.getWritePointer(0), buffer.getNumChannels() > 1 ? buffer.getWritePointer(1) : nullptr, samples, e->sampleRate);
        if (e->kind == "Cat Gate") {
            for (int ch = 0; ch < std::min(2, buffer.getNumChannels()); ++ch)
                e->recordPeak(size_t(ch), buffer.getMagnitude(ch, 0, samples));
            e->gate.process(buffer.getWritePointer(0), buffer.getNumChannels() > 1 ? buffer.getWritePointer(1) : nullptr, samples, e->sampleRate);
        }
        if(e->stem) { e->stem->process(buffer.getWritePointer(0),buffer.getWritePointer(1),unsigned(samples),std::isfinite(stemSeconds)?stemSeconds:seconds,playing); }
        if(e->plugin&&!e->bypassed) {
            const auto transport = tempoMap ? tempoMap->at(seconds,playing) : jaras::PluginTempoMap{}.at(seconds,playing);
            int count=0;
            if(midi)for(const auto metadata:*midi)if(metadata.numBytes<=3&&count<(int)e->midi.size()){
                auto &event=e->midi[(size_t)count++];event.offset=metadata.samplePosition;event.status=metadata.data[0];
                event.data1=metadata.numBytes>1?metadata.data[1]:0;event.data2=metadata.numBytes>2?metadata.data[2]:0;
            }
            e->plugin->process(buffer.getWritePointer(0),buffer.getWritePointer(1),samples,transport,e->midi.data(),count,renderARA);
        }
        if (e->plugin) {
            const auto reduction = e->plugin->gainReduction();
            if (reduction >= 0) reductionDB = std::max(reductionDB, e->bypassed ? 0.f : reduction);
        }
        if (e->pitch) {
            for (int ch = 0; ch < 2; ++ch)
                e->pitchInput.copyFrom(ch, 0, buffer, ch, 0, samples);
            e->pitch->process(e->pitchInput.getArrayOfReadPointers(), samples,
                              buffer.getArrayOfWritePointers(), samples);
        }
        if (e->kind == "EQ") {
            const bool capturing = e->eqAnalysis && e->eqAnalysis->begin(buffer.getReadPointer(0), buffer.getReadPointer(1), samples);
            for (int ch = 0; ch < 2; ++ch) {
                if (!(channels & (1u << ch))) continue;
                auto *data = buffer.getWritePointer(ch);
                for (unsigned index=0; index<e->eqActive; ++index)
                    for (int n = 0; n < samples; ++n)
                        data[n] = e->eq[ch][index].processSample(data[n]);
            }
            if (capturing) e->eqAnalysis->finish(buffer.getReadPointer(0), buffer.getReadPointer(1));
        }
        if (e->kind == "Compressor" || e->kind == "Limiter") {
            if (e->kind == "Compressor") {
                float minimumGain = 1.f;
                for (int ch = 0; ch < 2; ++ch) {
                    e->recordPeak(size_t(ch), buffer.getMagnitude(ch, 0, samples));
                    if (!(channels & (1u << ch))) continue;
                    auto *data = buffer.getWritePointer(ch);
                    for (int n = 0; n < samples; ++n) {
                        const float dry = data[n];
                        const float compressed = e->compressor.processSample(ch, dry);
                        if (std::abs(dry) > 1.e-6f)
                            minimumGain = std::min(minimumGain, std::abs(compressed / dry));
                        data[n] = compressed * e->makeup;
                    }
                }
                const float reduction = -Decibels::gainToDecibels(minimumGain, -120.f);
                e->recordPeak(2, reduction);
                reductionDB = std::max(reductionDB, reduction);
            } else {
                // Match the Mac's linked, zero-lookahead sample-peak ceiling.
                // JUCE's limiter normalizes to 0 dB after its threshold stage;
                // using threshold as a ceiling therefore amplified quiet audio.
                float minimumGain = e->makeup;
                auto *left = buffer.getWritePointer(0), *right = buffer.getWritePointer(1);
                for (int n = 0; n < samples; ++n) {
                    const float peak = std::max(std::abs(left[n]), std::abs(right[n])) * e->makeup;
                    const float target = e->makeup * std::min(1.f, e->limiterCeiling / std::max(1.e-20f, peak));
                    e->limiterGain = target < e->limiterGain ? target : target + (e->limiterGain - target) * e->limiterRelease;
                    minimumGain = std::min(minimumGain, e->limiterGain);
                    left[n] *= e->limiterGain; right[n] *= e->limiterGain;
                }
                reductionDB = std::max(reductionDB, -Decibels::gainToDecibels(minimumGain / e->makeup, -120.f));
            }
        }
        if (e->kind == "Reverb") {
            for (int ch = 0; ch < 2; ++ch) {
                if (channels & (1u << ch)) e->wet->copyFrom(ch, 0, buffer, ch, 0, samples);
                else e->wet->clear(ch, 0, samples);
            }
            e->reverb.processStereo(e->wet->getWritePointer(0), e->wet->getWritePointer(1),
                                    samples);
            for (int ch = 0; ch < 2; ++ch) {
                if (!(channels & (1u << ch))) continue;
                auto *wet = e->wet->getWritePointer(ch);
                auto *dry = buffer.getWritePointer(ch);
                for (int n = 0; n < samples; ++n)
                    dry[n] = dry[n] * (1 - e->mix) +
                             e->lowpass[ch].processSample(e->highpass[ch].processSample(wet[n])) *
                                 e->mix;
            }
        }
        if (e->kind == "Delay")
            for (int n = 0; n < samples; ++n) {
                for (int ch = 0; ch < 2; ++ch) {
                    if (!(channels & (1u << ch))) {
                        e->delay.setSample(ch, e->delayPosition, 0);
                        continue;
                    }
                    auto input = buffer.getSample(ch, n),
                         delayed = e->delay.getSample(ch, (e->delayPosition + e->delay.getNumSamples() - e->delaySamples) % e->delay.getNumSamples());
                    e->delay.setSample(ch, e->delayPosition, input + delayed * e->feedback);
                    buffer.setSample(ch, n, input * (1 - e->mix) + delayed * e->mix);
                }
                e->delayPosition = (e->delayPosition + 1) % e->delay.getNumSamples();
            }
    }
}
} // namespace catlive
