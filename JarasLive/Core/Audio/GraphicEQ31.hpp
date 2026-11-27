#pragma once

#include "SmoothBiquad.hpp"

namespace jaras::audio {

inline constexpr std::array<double, 31> graphicEQFrequencies{
    20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
    800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000
};
inline constexpr std::size_t graphicEQParameterCount = graphicEQFrequencies.size() + 1;

class GraphicEQ31 {
public:
    void prepare(double sampleRate) noexcept {
        rate = std::max(1., sampleRate);
        outputCoefficient = -std::expm1(-1 / (rate * .005));
        for (auto& channel : filters)
            for (auto& filter : channel) filter.setSampleRate(rate);
        initialized = false;
        reset();
    }

    void reset() noexcept {
        for (auto& channel : filters)
            for (auto& filter : channel) filter.reset();
        output = targetOutput;
    }

    template <class Values>
    void process(float* left, float* right, unsigned frames, const Values& values) noexcept {
        for (std::size_t band = 0; band < gains.size(); ++band) {
            const double frequency = graphicEQFrequencies[band];
            const double gain = frequency < rate * .49 ? safeGain(values[band]) : 0;
            if (initialized && gains[band] == gain) continue;
            gains[band] = gain;
            const auto coefficients = peaking(frequency, gain);
            for (auto& channel : filters) {
                if (initialized) channel[band].setTarget(coefficients.data());
                else channel[band].setImmediate(coefficients.data());
            }
        }
        const double nextOutputGain = safeGain(values[gains.size()]);
        if (nextOutputGain != outputGain) {
            outputGain = nextOutputGain;
            targetOutput = std::pow(10., outputGain / 20.);
        }
        if (!initialized) output = targetOutput;
        initialized = true;

        auto filterChannel = [&](float* samples, auto& channel) {
            if (!samples) return;
            for (std::size_t band = 0; band < gains.size(); ++band) {
                auto& filter = channel[band];
                if (gains[band] == 0 && !filter.isSettling()) continue;
                for (unsigned frame = 0; frame < frames; ++frame)
                    samples[frame] = filter.processSample(samples[frame]);
            }
        };
        filterChannel(left, filters[0]);
        filterChannel(right, filters[1]);
        if (output == 1 && targetOutput == 1) return;
        for (unsigned frame = 0; frame < frames; ++frame) {
            output += (targetOutput - output) * outputCoefficient;
            left[frame] *= static_cast<float>(output);
            if (right) right[frame] *= static_cast<float>(output);
        }
        if (std::abs(output - targetOutput) < 1.e-9) output = targetOutput;
    }

private:
    static double safeGain(double gain) noexcept {
        return std::isfinite(gain) ? std::clamp(gain, -12., 12.) : 0;
    }

    std::array<double, 5> peaking(double frequency, double gain) const noexcept {
        if (gain == 0) return {1, 0, 0, 0, 0};
        constexpr double twoPi = 6.283185307179586;
        constexpr double oneThirdOctaveQ = 4.318473;
        const double angle = twoPi * frequency / rate;
        const double a = std::pow(10., gain / 40.);
        const double alpha = std::sin(angle) / (2 * oneThirdOctaveQ);
        const double middle = -2 * std::cos(angle);
        const double denominator = 1 + alpha / a;
        return {(1 + alpha * a) / denominator, middle / denominator,
                (1 - alpha * a) / denominator, middle / denominator, (1 - alpha / a) / denominator};
    }

    std::array<double, graphicEQFrequencies.size()> gains{};
    std::array<std::array<SmoothBiquad, graphicEQFrequencies.size()>, 2> filters;
    double rate = 48000, output = 1, targetOutput = 1, outputCoefficient = 1, outputGain = 0;
    bool initialized = false;
};

} // namespace jaras::audio
