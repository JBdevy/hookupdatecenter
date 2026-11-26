#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <string_view>
#include <vector>

#include "../Transport/PluginTransport.hpp"

namespace jaras::audio {

enum class CreativeEffect { chorus = 1, phaser, amp, divisionGate, softClipper };

struct CreativeParameter {
    const char* key;
    const char* name;
    double initial, minimum, maximum, increment;
    const char* suffix;
};

struct CreativeEffectInfo {
    CreativeEffect kind;
    std::string_view name;
    const char* field;
    const char* enabledField;
    std::array<CreativeParameter, 4> parameters;
};

inline constexpr CreativeEffectInfo creativeEffects[] = {
    {CreativeEffect::chorus, "Chorus", "chorus", "chorusEnabled", {{
        {"rate", "Rate", .8, .05, 8, .01, " Hz"},
        {"depth", "Depth", 3, 0, 10, .1, " ms"},
        {"mix", "Mix", 40, 0, 100, 1, " %"}, {}}}},
    {CreativeEffect::phaser, "Phaser", "phaser", "phaserEnabled", {{
        {"rate", "Rate", .4, .05, 8, .01, " Hz"},
        {"depth", "Depth", 70, 0, 100, 1, " %"},
        {"feedback", "Feedback", 27, 0, 85, 1, " %"},
        {"mix", "Mix", 50, 0, 100, 1, " %"}}}},
    {CreativeEffect::amp, "Amp", "amp", "ampEnabled", {{
        {"drive", "Drive", 12, 0, 36, .1, " dB"},
        {"tone", "Tone", 55, 0, 100, 1, " %"},
        {"output", "Output", -6, -24, 12, .1, " dB"},
        {"mix", "Mix", 100, 0, 100, 1, " %"}}}},
    {CreativeEffect::divisionGate, "Gate Divisor", "divisionGate", "divisionGateEnabled", {{
        {"division", "Division", 16, 2, 32, 1, ""},
        {"depth", "Depth", 100, 0, 100, 1, " %"},
        {"smoothing", "Smoothing", 4, .2, 30, .1, " ms"},
        {"steps", "Steps", 0x5b5b, 0, 65535, 1, ""}}}},
    {CreativeEffect::softClipper, "Soft Clipper", "softClipper", "softClipperEnabled", {{
        {"drive", "Drive", 0, 0, 24, .1, " dB"},
        {"ceiling", "Ceiling", -.1, -24, 0, .1, " dB"},
        {"softness", "Softness", 40, 1, 100, 1, " %"}, {}}}}
};

inline const CreativeEffectInfo* creativeEffect(std::string_view name) noexcept {
    for (const auto& effect : creativeEffects)
        if (effect.name == name) return &effect;
    return nullptr;
}

class CreativeEffectDSP {
public:
    explicit CreativeEffectDSP(CreativeEffect kind) : kind(kind) {}
    void prepare(double sampleRate) {
        rate = sampleRate;
        if (kind == CreativeEffect::chorus)
            for (auto& channel : channels) channel.delay.assign(static_cast<size_t>(rate * .04) + 2, 0);
        reset();
    }

    float gainReductionDB() const noexcept { return lastReductionDB; }
    void reset() noexcept {
        lastReductionDB = 0;
        writeIndex = 0;
        phase = 0;
        envelope = 1;
        for (auto& channel : channels) {
            std::fill(channel.delay.begin(), channel.delay.end(), 0.f);
            channel.filters.fill(0);
            channel.previous = 0;
        }
    }

    void process(float* left, float* right, unsigned frames,
                 const std::array<double, 4>& values, const PluginTransport& transport) noexcept {
        if (!left) return;
        const auto& specs = creativeEffects[static_cast<int>(kind) - 1].parameters;
        auto settings = values;
        for (size_t i = 0; i < settings.size() && specs[i].key; ++i)
            settings[i] = std::clamp(std::isfinite(settings[i]) ? settings[i] : specs[i].initial, specs[i].minimum, specs[i].maximum);
        if (kind == CreativeEffect::softClipper) {
            const double gain = std::pow(10., settings[0] / 20.);
            const double ceiling = std::pow(10., settings[1] / 20.);
            const double knee = ceiling * settings[2] / 100.;
            const double onset = ceiling - knee;
            double minimumGain = 1;
            for (float* samples : {left, right}) {
                if (!samples) continue;
                for (unsigned i = 0; i < frames; ++i) {
                    const double driven = samples[i] * gain;
                    const double magnitude = std::abs(driven);
                    if (magnitude <= onset) { samples[i] = static_cast<float>(driven); continue; }
                    const double shaped = onset + knee * std::tanh((magnitude - onset) / knee);
                    samples[i] = static_cast<float>(std::copysign(shaped, driven));
                    minimumGain = std::min(minimumGain, shaped / magnitude);
                }
            }
            lastReductionDB = static_cast<float>(-20. * std::log10(std::max(1.e-6, minimumGain)));
            return;
        }
        if (kind == CreativeEffect::divisionGate) {
            processGate(left, right, frames, settings, transport);
            return;
        }

        float* inputs[]{left, right};
        constexpr double tau = 6.283185307179586;
        const double mix = .01 * (kind == CreativeEffect::chorus ? settings[2] : settings[3]);
        const double gain = std::pow(10., settings[0] / 20.);
        const double output = std::pow(10., settings[2] / 20.);
        const double tone = -std::expm1(-tau * (650. * std::pow(9., settings[1] / 100.)) / rate);
        const double highPass = -std::expm1(-tau * 75. / rate);
        for (unsigned n = 0; n < frames; ++n) {
            for (unsigned ch = 0; ch < 2 && inputs[ch]; ++ch) {
                auto& state = channels[ch];
                const float dry = inputs[ch][n];
                double wet = dry;
                if (kind == CreativeEffect::chorus && !state.delay.empty()) {
                    const double offset = (15 + settings[1] * std::sin(tau * (phase + ch * .25))) * rate * .001;
                    const auto whole = static_cast<size_t>(offset);
                    const auto size = state.delay.size();
                    const auto read = (writeIndex + size - whole) % size;
                    const auto before = (read + size - 1) % size;
                    wet = state.delay[read] + (state.delay[before] - state.delay[read]) * (offset - whole);
                    state.delay[writeIndex] = dry;
                } else if (kind == CreativeEffect::phaser) {
                    const double lfo = std::sin(tau * (phase + ch * .25));
                    const double hz = std::min(rate * .2, 850. * std::exp(lfo * settings[1] * .023));
                    const double tangent = std::tan(hz * tau * .5 / rate);
                    const double coefficient = (1 - tangent) / (1 + tangent);
                    wet = dry + state.previous * settings[2] * .01;
                    for (double& filter : state.filters) {
                        const double allPass = filter - coefficient * wet;
                        filter = wet + coefficient * allPass;
                        wet = allPass;
                    }
                    state.previous = wet;
                } else if (kind == CreativeEffect::amp) {
                    state.filters[0] += highPass * (dry - state.filters[0]);
                    const double driven = gain * (dry - state.filters[0]);
                    const double clipped = driven / std::sqrt(1. + driven * driven);
                    state.filters[1] += tone * (clipped - state.filters[1]);
                    wet = state.filters[1] * output;
                }
                inputs[ch][n] = static_cast<float>(dry + mix * (wet - dry));
            }
            if (kind == CreativeEffect::chorus && !channels[0].delay.empty())
                writeIndex = (writeIndex + 1) % channels[0].delay.size();
            if (kind != CreativeEffect::amp) {
                phase += settings[0] / rate;
                if (phase >= 1) phase -= 1;
            }
        }
    }

private:
    float lastReductionDB = 0;
    struct Channel {
        std::vector<float> delay;
        std::array<double, 6> filters{};
        double previous = 0;
    };
    const CreativeEffect kind;
    std::array<Channel, 2> channels;
    size_t writeIndex = 0;
    double rate = 48000, phase = 0, envelope = 1;

    void processGate(float* left, float* right, unsigned frames,
                     const std::array<double, 4>& settings, const PluginTransport& transport) noexcept {
        const double division = std::round(settings[0]) / 4.;
        const double start = transport.quarterNotes * division;
        const double increment = transport.tempo * division / (60. * rate);
        const double smoothing = std::min(1., 1. / (rate * settings[2] * .001));
        const auto pattern = static_cast<unsigned>(std::round(settings[3]));
        for (unsigned n = 0; n < frames; ++n) {
            const double step = std::floor(start + n * increment + 1.e-9);
            const unsigned index = static_cast<unsigned>(std::fmod(std::abs(step), 16.));
            const bool open = !transport.playing || ((pattern >> (step < 0 ? (16 - index) % 16 : index)) & 1u);
            const double target = open ? 1. : 1. - settings[1] / 100.;
            envelope = target > envelope ? std::min(target, envelope + smoothing) : std::max(target, envelope - smoothing);
            left[n] *= static_cast<float>(envelope);
            if (right) right[n] *= static_cast<float>(envelope);
        }
    }
};

}
