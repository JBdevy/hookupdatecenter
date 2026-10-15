#include "NativeFX.h"
#include "../ThirdParty/Signalsmith/signalsmith-stretch.h"
namespace catlive {
struct NativeFX::Effect {
    String kind;
    std::vector<std::unique_ptr<dsp::IIR::Filter<float>>> eq[2];
    dsp::Compressor<float> compressor;
    dsp::Limiter<float> limiter;
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
void NativeFX::prepare(const var &settings, double sampleRate) {
    effects.clear();
    unsupported.clear();
    auto append = [&](String kind, const var &value) {
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
            e->limiter.prepare(spec);
            e->limiter.setThreshold((float)jlimit(-24.0, 0.0, num(limiter, "ceiling", -.1)));
            e->limiter.setRelease((float)jlimit(10.0, 3000.0, num(limiter, "release", .1) * 1000));
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
        auto value = settings;
        auto kind = key;
        for (auto instance : list(get(settings, "instances")))
            if ("Native:" + str(instance, "id") == key ||
                "Instance:" + str(instance, "id") == key) {
                kind = str(instance, "kind");
                value = get(instance, "settings");
                break;
            }
        append(kind, value);
    }
}
void NativeFX::process(AudioBuffer<float> &buffer, int samples) {
    ScopedNoDenormals noDenormals;
    for (auto &e : effects) {
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
                buffer.applyGain(0, samples, e->makeup);
                e->limiter.process(context);
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
