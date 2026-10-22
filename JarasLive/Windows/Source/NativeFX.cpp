#include "NativeFX.h"
#include "Automation.h"
#include "../ThirdParty/Signalsmith/signalsmith-stretch.h"
namespace catlive {
struct NativeFX::Effect {
    String kind;
    String key, externalConfiguration, pluginID;
    bool bypassed = false, retiredStem=false;
    std::shared_ptr<native::vst3::Processor> plugin;
    std::shared_ptr<native::stem::Processor> stem;
    native::stem::Mix stemMix;
    std::array<native::vst3::MIDIEvent,4096> midi{};
    std::vector<std::unique_ptr<dsp::IIR::Filter<float>>> eq[2];
    dsp::Compressor<float> compressor;
    float limiterCeiling = 1, limiterRelease = 0, limiterGain = 1;
    Reverb reverb;
    std::unique_ptr<signalsmith::stretch::SignalsmithStretch<float>> pitch;
    AudioBuffer<float> pitchInput;
    std::unique_ptr<AudioBuffer<float>> wet;
    dsp::IIR::Filter<float> highpass[2], lowpass[2];
    AudioBuffer<float> delay;
    int delayPosition = 0, delaySamples = 1;
    float feedback = 0, mix = 0, makeup = 1;
};
NativeFX::NativeFX() = default;
NativeFX::~NativeFX() = default;
void NativeFX::swap(NativeFX &other)noexcept {
    effects.swap(other.effects);
    unsupported.swapWith(other.unsupported);
}
void NativeFX::prepare(const var &settings, double sampleRate, const NativeFX *previous,bool offline,bool prewarm,
                       const Dispatcher &pluginDispatcher) {
    effects.clear();
    unsupported.clear();
    auto append = [&](String kind, const String &key, const var &value) {
        if(kind==native::stem::effectName) {
            if(!get(value,"stemMix").isObject())return; // legacy offline-only Mac project
            auto e=std::make_unique<Effect>();e->kind=kind;e->key=key;
            e->stemMix.enabled=flag(value,"stemSeparatorEnabled");
            const auto sources=list(get(get(value,"stemMix"),"sources"));
            if(sources.size()!=5)throw std::runtime_error("CatStem requer cinco stems.");
            for(int i=0;i<5;i++) {
                e->stemMix.gains[(size_t)i]=(float)jlimit(0.,4.,num(sources[i],"gain",1));
                if(flag(sources[i],"mute"))e->stemMix.muteMask|=1u<<i;
                if(flag(sources[i],"solo"))e->stemMix.soloMask|=1u<<i;
            }
            if(previous)for(const auto &old:previous->effects)
                if(old->key==key&&old->stem&&old->stem->sampleRate()==unsigned(sampleRate)&&old->stem->isOffline()==offline&&(!e->stemMix.enabled||old->stem->status().state!="fault"))e->stem=old->stem;
            if(!e->stem)e->stem=std::make_shared<native::stem::Processor>(native::stem::Paths::bundled(),unsigned(sampleRate),offline,prewarm&&e->stemMix.enabled);
            e->stem->configure(e->stemMix);
            effects.push_back(std::move(e));return;
        }
        String enabledKey = kind == "EQ"           ? "eqEnabled"
                            : kind == "Compressor" ? "compressorEnabled"
                            : kind == "Delay"      ? "delayEnabled"
                            : kind == "Reverb"     ? "reverbEnabled"
                            : kind == "Limiter"    ? "limiterEnabled"
                            : kind == "Pitch"      ? "pitchEnabled"
                                                   : String();
        if (enabledKey.isNotEmpty() && !flag(value, Identifier(enabledKey)))
            return;
        if (kind == "Pitch" && num(value, "pitchSemitones") == 0)
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
        e->kind = kind;
        dsp::ProcessSpec spec{sampleRate, 4096, 2};
        if (kind == "Pitch") {
            e->pitch = std::make_unique<signalsmith::stretch::SignalsmithStretch<float>>(0);
            e->pitch->presetDefault(2, (float)sampleRate);
            e->pitch->setTransposeSemitones(jlimit(-12., 12., num(value, "pitchSemitones")));
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
                dsp::IIR::Coefficients<float>::Ptr coefficients;
                if (type == "lowCut")
                    coefficients = dsp::IIR::Coefficients<float>::makeHighPass(
                        sampleRate, (float)frequency, (float)q);
                else if (type == "highCut")
                    coefficients = dsp::IIR::Coefficients<float>::makeLowPass(
                        sampleRate, (float)frequency, (float)q);
                else if (type == "lowShelf")
                    coefficients = dsp::IIR::Coefficients<float>::makeLowShelf(
                        sampleRate, (float)frequency, (float)q, (float)gain);
                else if (type == "highShelf")
                    coefficients = dsp::IIR::Coefficients<float>::makeHighShelf(
                        sampleRate, (float)frequency, (float)q, (float)gain);
                else
                    coefficients = dsp::IIR::Coefficients<float>::makePeakFilter(
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
                            stageCoefficients = new dsp::IIR::Coefficients<float>(
                                (float)b0, (float)(type == "lowCut" ? -b0 : b0), 0, 1,
                                (float)((k - 1) / (k + 1)), 0);
                        } else if (cut) {
                            float butterworthQ =
                                (float)(1 / (2 * std::sin(MathConstants<double>::pi *
                                                          (2 * stage + 1) / (2 * order))));
                            stageCoefficients =
                                type == "lowCut" ? dsp::IIR::Coefficients<float>::makeHighPass(
                                                       sampleRate, (float)frequency, butterworthQ)
                                                 : dsp::IIR::Coefficients<float>::makeLowPass(
                                                       sampleRate, (float)frequency, butterworthQ);
                        }
                        auto filter = std::make_unique<dsp::IIR::Filter<float>>(stageCoefficients);
                        filter->reset();
                        e->eq[ch].push_back(std::move(filter));
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
            e->delay.setSize(2, e->delaySamples + 1);
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
                e->highpass[ch].coefficients = dsp::IIR::Coefficients<float>::makeHighPass(
                    sampleRate, (float)jlimit(20.0, 2000.0, num(value, "reverbLowCut", 80)));
                e->lowpass[ch].coefficients = dsp::IIR::Coefficients<float>::makeLowPass(
                    sampleRate, (float)jlimit(2000.0, std::min(20000.0, sampleRate * .45),
                                              num(value, "reverbHighCut", 12000)));
            }
        }
        effects.push_back(std::move(e));
    };
    for (auto raw : list(get(settings, "inserted"))) {
        auto key = raw.toString();
        if (key.startsWith("External:")) {
            try {
            for (auto plugin : list(get(settings,"externalPlugins"))) if (key=="External:"+str(plugin,"id")) {
                // Keep opaque states editable/undoable when a project arrives
                // from a computer where this plug-in was installed elsewhere.
                if(!File(str(plugin,"path")).exists()) {
                    unsupported.addIfNotAlreadyThere(str(plugin,"name",key)+": plugin VST3 ausente");
                    break;
                }
                auto e=std::make_unique<Effect>();e->kind="External";e->key=key;e->pluginID=str(plugin,"id");e->bypassed=flag(plugin,"bypassed");
                auto configuration=plugin.clone();configuration.getDynamicObject()->removeProperty("bypassed");
                e->externalConfiguration=JSON::toString(configuration,true);
                if(previous)for(const auto &old:previous->effects)
                    if(old->key==key&&old->externalConfiguration==e->externalConfiguration)e->plugin=old->plugin;
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
                    // A queued constructor may finish after its load was
                    // cancelled. Own its result independently of this Effect.
                    auto result=std::make_shared<std::shared_ptr<native::vst3::Processor>>();
                    const auto *manager=MessageManager::getInstanceWithoutCreating();
                    const bool affine=bool(pluginDispatcher)||(manager&&manager->isThisTheMessageThread());
                    auto create=[result,description=std::move(description),state=std::move(state),sampleRate,affine] {
                        auto *processor=new native::vst3::Processor(description,state,sampleRate,4096);
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
            catch(const std::exception &e){if(previous)throw;unsupported.addIfNotAlreadyThere(key+": "+String::fromUTF8(e.what()));}
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
        auto configuration=plugin.clone();configuration.getDynamicObject()->removeProperty("bypassed");
        for(const auto &effect:effects)if(effect->plugin==processor)effect->externalConfiguration=JSON::toString(configuration,true);
    }
}
unsigned NativeFX::latencyFrames() const {unsigned value=0;for(const auto &e:effects)if(e->stem)value+=e->stem->availableLatency();return value;}
unsigned NativeFX::readyLatencyFrames(bool releaseRemoved) const {
    unsigned value=0;
    for(const auto &e:effects)if(e->stem&&!(releaseRemoved&&e->retiredStem))
        value+=e->stem->pending()?e->stem->latency():e->stem->availableLatency();
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
void NativeFX::shareStems(const NativeFX &source){for(auto &e:effects)if(e->stem)for(const auto &other:source.effects)if(e->key==other->key&&other->stem)e->stem=other->stem;}
bool NativeFX::hasActiveStem()const {for(const auto &e:effects)if(e->stem&&e->stem->availableLatency())return true;return false;}
void NativeFX::resetStems(){for(auto &e:effects)if(e->stem)e->stem->reset();}
native::stem::Status NativeFX::stemStatus(const String &key)const {for(const auto &e:effects)if(e->key==key&&e->stem)return e->stem->status();return {};}
void NativeFX::previewStemMix(const String &key,const native::stem::Mix &mix){for(auto &e:effects)if(e->key==key&&e->stem)e->stem->configure(mix);}
void NativeFX::waitForStems(){for(auto &e:effects)if(e->stem&&e->stemMix.enabled)e->stem->waitReady();}
void NativeFX::checkStemErrors()const {for(const auto &e:effects)if(e->stem&&e->stemMix.enabled){const auto s=e->stem->status();if(s.state=="fault")throw std::runtime_error(s.error);}}
bool NativeFX::hasExternal() const {for(const auto &effect:effects)if(effect->plugin)return true;return false;}
void NativeFX::applyAutomation(const AutomationProgram &program, double time) {
    for (const auto &curve : program.curves) if (curve.target == AutomationCurve::externalFX)
        for (const auto &effect : effects) if (effect->plugin && !effect->bypassed &&
            effect->pluginID == curve.plugin)
            effect->plugin->automate(curve.parameter, curve.value(time));
}
void NativeFX::process(AudioBuffer<float> &buffer, int samples,double seconds,bool playing,const MidiBuffer *midi,double stemSeconds) {
    ScopedNoDenormals noDenormals;
    for (auto &e : effects) {
        if(e->stem) { e->stem->process(buffer.getWritePointer(0),buffer.getWritePointer(1),unsigned(samples),std::isfinite(stemSeconds)?stemSeconds:seconds,playing); }
        if(e->plugin&&!e->bypassed) {
            native::vst3::Transport transport;transport.seconds=seconds;transport.quarterNotes=seconds*2;transport.playing=playing;
            int count=0;
            if(midi)for(const auto metadata:*midi)if(metadata.numBytes<=3&&count<(int)e->midi.size()){
                auto &event=e->midi[(size_t)count++];event.offset=metadata.samplePosition;event.status=metadata.data[0];
                event.data1=metadata.numBytes>1?metadata.data[1]:0;event.data2=metadata.numBytes>2?metadata.data[2]:0;
            }
            e->plugin->process(buffer.getWritePointer(0),buffer.getWritePointer(1),samples,transport,e->midi.data(),count);
        }
        if (e->kind == "Pitch") {
            for (int ch = 0; ch < 2; ++ch)
                e->pitchInput.copyFrom(ch, 0, buffer, ch, 0, samples);
            e->pitch->process(e->pitchInput.getArrayOfReadPointers(), samples,
                              buffer.getArrayOfWritePointers(), samples);
        }
        if (e->kind == "EQ")
            for (int ch = 0; ch < 2; ++ch) {
                auto *data = buffer.getWritePointer(ch);
                for (auto &filter : e->eq[ch])
                    for (int n = 0; n < samples; ++n)
                        data[n] = filter->processSample(data[n]);
            }
        if (e->kind == "Compressor" || e->kind == "Limiter") {
            dsp::AudioBlock<float> block(buffer);
            auto sub = block.getSubBlock(0, (size_t)samples);
            dsp::ProcessContextReplacing<float> context(sub);
            if (e->kind == "Compressor") {
                e->compressor.process(context);
                buffer.applyGain(0, samples, e->makeup);
            } else {
                // Match the Mac's linked, zero-lookahead sample-peak ceiling.
                // JUCE's limiter normalizes to 0 dB after its threshold stage;
                // using threshold as a ceiling therefore amplified quiet audio.
                auto *left = buffer.getWritePointer(0), *right = buffer.getWritePointer(1);
                for (int n = 0; n < samples; ++n) {
                    const float peak = std::max(std::abs(left[n]), std::abs(right[n])) * e->makeup;
                    const float target = e->makeup * std::min(1.f, e->limiterCeiling / std::max(1.e-20f, peak));
                    e->limiterGain = target < e->limiterGain ? target : target + (e->limiterGain - target) * e->limiterRelease;
                    left[n] *= e->limiterGain; right[n] *= e->limiterGain;
                }
            }
        }
        if (e->kind == "Reverb") {
            for (int ch = 0; ch < 2; ++ch)
                e->wet->copyFrom(ch, 0, buffer, ch, 0, samples);
            e->reverb.processStereo(e->wet->getWritePointer(0), e->wet->getWritePointer(1),
                                    samples);
            for (int ch = 0; ch < 2; ++ch) {
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
                    auto input = buffer.getSample(ch, n),
                         delayed = e->delay.getSample(ch, e->delayPosition);
                    e->delay.setSample(ch, e->delayPosition, input + delayed * e->feedback);
                    buffer.setSample(ch, n, input * (1 - e->mix) + delayed * e->mix);
                }
                e->delayPosition = (e->delayPosition + 1) % e->delaySamples;
            }
    }
}
} // namespace catlive
