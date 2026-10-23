#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <utility>
#include <vector>

// Shared by the native Apple and Windows hosts. The host owns publication of
// parameters/sample changes: setSample is control-thread only; process, reset,
// and setParameters neither allocate nor lock. One instance is one audio stream.
namespace catlive::dsp {
namespace dynamics_detail {
inline double bounded(double value, double low, double high, double fallback) noexcept {
    return std::isfinite(value) ? std::clamp(value, low, high) : fallback;
}
inline double rate(double value) noexcept {
    return std::isfinite(value) && value >= 1.0 ? value : 48000.0;
}
inline double amplitude(double db) noexcept { return std::pow(10.0, db / 20.0); }
inline double finiteSample(float value) noexcept { return std::isfinite(value) ? value : 0.0; }
inline float output(double value) noexcept {
    // Keep valid floating-point headroom; only reject non-finite/overflow values.
    return std::isfinite(value) ? static_cast<float>(std::clamp(value, -1.0e12, 1.0e12)) : 0.0f;
}
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    void reset() noexcept { z1 = z2 = 0; }
    void configure(double frequency, double sampleRate, bool highPass) noexcept {
        constexpr double pi = 3.14159265358979323846;
        const double omega = 2.0 * pi * std::clamp(frequency, 0.001, sampleRate * 0.49) / sampleRate;
        const double cosine = std::cos(omega);
        const double alpha = std::sin(omega) / std::sqrt(2.0);
        const double inverse = 1.0 / (1.0 + alpha);
        b0 = (highPass ? 1.0 + cosine : 1.0 - cosine) * 0.5 * inverse;
        b1 = (highPass ? -(1.0 + cosine) : 1.0 - cosine) * inverse;
        b2 = b0;
        a1 = -2.0 * cosine * inverse;
        a2 = (1.0 - alpha) * inverse;
    }
    double process(double sample) noexcept {
        const double result = b0 * sample + z1;
        z1 = b1 * sample - a1 * result + z2;
        z2 = b2 * sample - a2 * result;
        if (std::abs(z1) < 1.0e-24) z1 = 0;
        if (std::abs(z2) < 1.0e-24) z2 = 0;
        return result;
    }
};
} // namespace dynamics_detail

struct TriggerParameters {
    double threshold = -30; // dBFS, stereo-linked input detector
    double retrigger = 0.08; // seconds, minimum spacing between distinct attacks
    double gain = 0; // dB, sample output
    double mix = 100; // Legacy document/automation field; active Trigger is sample-only.
    double attack = 0, decay = 0.1, sustain = 1, release = 0.02; // seconds; sustain 0...1
};

class Trigger {
public:
    static constexpr std::size_t maximumVoices = 16;

    void setParameters(const TriggerParameters& value) noexcept {
        using dynamics_detail::bounded;
        parameters_.threshold = bounded(value.threshold, -100, 0, -30);
        parameters_.retrigger = bounded(value.retrigger, 0, 10, 0.08);
        parameters_.gain = bounded(value.gain, -60, 24, 0);
        parameters_.mix = bounded(value.mix, 0, 100, 100);
        parameters_.attack = bounded(value.attack, 0, 10, 0);
        parameters_.decay = bounded(value.decay, 0, 10, 0.1);
        parameters_.sustain = bounded(value.sustain, 0, 1, 1);
        parameters_.release = bounded(value.release, 0, 20, 0.02);
    }

    // Decode WAV/MP3 off the audio thread, then publish a prepared processor.
    // This function consumes the PCM vectors; neither file decoding nor sample
    // replacement belongs in the realtime callback.
    void setSample(std::vector<float> left, std::vector<float> right, double sampleRate) {
        if (left.empty() && !right.empty()) left = std::move(right);
        if (right.empty()) right = left;
        right.resize(left.size(), 0.0f);
        for (auto& value : left) if (!std::isfinite(value)) value = 0;
        for (auto& value : right) if (!std::isfinite(value)) value = 0;
        sampleLeft_ = std::move(left);
        sampleRight_ = std::move(right);
        sourceRate_ = dynamics_detail::rate(sampleRate);
        reset();
    }

    bool hasSample() const noexcept { return !sampleLeft_.empty(); }

    void reset() noexcept {
        for (auto& voice : voices_) voice = {};
        detector_ = 0;
        sinceTrigger_ = 1.0e9;
        armed_ = true;
    }

    void process(float* left, float* right, int frames, double sampleRate) noexcept {
        if (!left || frames <= 0) return;
        if (right == left) right = nullptr;
        // The input is a detector only. An empty/missing sample cannot leak it.
        if (!hasSample()) {
            std::fill_n(left, frames, 0.f);
            if (right) std::fill_n(right, frames, 0.f);
            return;
        }
        using namespace dynamics_detail;
        const double outputRate = rate(sampleRate);
        const double dt = 1.0 / outputRate;
        const double step = sourceRate_ / outputRate;
        const double detectorRelease = std::exp(-dt / 0.020);
        const double threshold = amplitude(parameters_.threshold);
        const double sampleGain = amplitude(parameters_.gain);
        const double duration = static_cast<double>(sampleLeft_.size()) / sourceRate_;
        for (int frame = 0; frame < frames; ++frame) {
            const double inputL = finiteSample(left[frame]);
            const double inputR = right ? finiteSample(right[frame]) : inputL;
            detector_ = std::max(std::max(std::abs(inputL), std::abs(inputR)), detector_ * detectorRelease);
            if (detector_ < 1.0e-24) detector_ = 0;
            sinceTrigger_ += dt;
            if (detector_ < threshold * 0.5) armed_ = true;
            if (armed_ && detector_ >= threshold) {
                // Consume the edge even inside the retrigger interval. Holding
                // a loud input must never produce a delayed/spurious trigger.
                armed_ = false;
                if (sinceTrigger_ >= parameters_.retrigger) {
                    beginVoice();
                    sinceTrigger_ = 0;
                }
            }
            double sampleL = 0, sampleR = 0;
            for (auto& voice : voices_) {
                if (!voice.active) continue;
                const auto index = static_cast<std::size_t>(voice.position);
                if (index >= sampleLeft_.size()) { voice.active = false; continue; }
                const auto next = std::min(index + 1, sampleLeft_.size() - 1);
                const double fraction = voice.position - static_cast<double>(index);
                const double envelope = envelopeAt(voice.position / sourceRate_, duration);
                sampleL += (sampleLeft_[index] + (sampleLeft_[next] - sampleLeft_[index]) * fraction) * envelope;
                sampleR += (sampleRight_[index] + (sampleRight_[next] - sampleRight_[index]) * fraction) * envelope;
                voice.position += step;
                if (voice.position >= static_cast<double>(sampleLeft_.size())) voice.active = false;
            }
            if (right) {
                left[frame] = output(sampleL * sampleGain);
                right[frame] = output(sampleR * sampleGain);
            } else {
                left[frame] = output((sampleL + sampleR) * 0.5 * sampleGain);
            }
        }
    }

private:
    struct Voice { double position = 0; bool active = false; };
    TriggerParameters parameters_;
    std::vector<float> sampleLeft_, sampleRight_;
    std::array<Voice, maximumVoices> voices_{};
    double sourceRate_ = 48000, detector_ = 0, sinceTrigger_ = 1.0e9;
    bool armed_ = true;

    void beginVoice() noexcept {
        auto* slot = &voices_[0];
        for (auto& voice : voices_) {
            if (!voice.active) { slot = &voice; break; }
            if (voice.position > slot->position) slot = &voice;
        }
        *slot = {0, true}; // Steal the oldest voice when the fixed pool is full.
    }
    double beforeRelease(double time, double attack) const noexcept {
        if (attack > 0 && time < attack) return time / attack;
        const double decayTime = time - attack;
        if (parameters_.decay > 0 && decayTime < parameters_.decay)
            return 1.0 + (parameters_.sustain - 1.0) * std::max(0.0, decayTime) / parameters_.decay;
        return parameters_.sustain;
    }
    double envelopeAt(double time, double duration) const noexcept {
        // Preserve both stages on short samples rather than starting release at
        // time zero with an attack gain of zero (which would mute the sample).
        const double scale = duration / std::max(duration, parameters_.attack + parameters_.release);
        const double attack = parameters_.attack * scale;
        const double release = parameters_.release * scale;
        const double releaseStart = duration - release;
        if (release > 0 && time >= releaseStart)
            return beforeRelease(releaseStart, attack) * std::max(0.0, (duration - time) / release);
        return beforeRelease(time, attack);
    }
};

struct GateParameters {
    double threshold = -40; // dBFS; 3 dB closing hysteresis
    double attack = 0.001;
    double decay = 0.02; // seconds, detector decay (independent of output release)
    double hold = 0.05, release = 0.1;
    double highPass = 20, lowPass = 20000; // Hz, detector filters
    bool filterOutput = false;
};

class Gate {
public:
    void setParameters(const GateParameters& value) noexcept {
        using dynamics_detail::bounded;
        parameters_.threshold = bounded(value.threshold, -100, 0, -40);
        parameters_.attack = bounded(value.attack, 0, 10, 0.001);
        parameters_.decay = bounded(value.decay, 0, 10, 0.02);
        parameters_.hold = bounded(value.hold, 0, 10, 0.05);
        parameters_.release = bounded(value.release, 0, 10, 0.1);
        parameters_.highPass = bounded(value.highPass, 0, 40000, 20);
        parameters_.lowPass = bounded(value.lowPass, 0, 40000, 20000);
        parameters_.filterOutput = value.filterOutput;
    }
    void reset() noexcept {
        for (auto& filter : highPass_) filter.reset();
        for (auto& filter : lowPass_) filter.reset();
        detector_ = gain_ = holdRemaining_ = 0;
        open_ = false;
    }
    void process(float* left, float* right, int frames, double sampleRate) noexcept {
        if (!left || frames <= 0) return;
        if (right == left) right = nullptr;
        using namespace dynamics_detail;
        const double outputRate = rate(sampleRate);
        if (outputRate != configuredRate_ || parameters_.highPass != configuredHP_ || parameters_.lowPass != configuredLP_) {
            for (auto& filter : highPass_) filter.configure(parameters_.highPass, outputRate, true);
            for (auto& filter : lowPass_) filter.configure(parameters_.lowPass, outputRate, false);
            configuredRate_ = outputRate;
            configuredHP_ = parameters_.highPass;
            configuredLP_ = parameters_.lowPass;
        }
        const double dt = 1.0 / outputRate;
        const double threshold = amplitude(parameters_.threshold);
        const double closeThreshold = threshold * 0.7079457843841379;
        const double decay = parameters_.decay > 0 ? std::exp(-dt / parameters_.decay) : 0;
        const double attackStep = parameters_.attack > 0 ? dt / parameters_.attack : 1;
        const double releaseStep = parameters_.release > 0 ? dt / parameters_.release : 1;
        for (int frame = 0; frame < frames; ++frame) {
            const double inputL = finiteSample(left[frame]);
            const double inputR = right ? finiteSample(right[frame]) : inputL;
            double filteredL = inputL, filteredR = inputR;
            if (parameters_.highPass > 0) {
                filteredL = highPass_[0].process(filteredL);
                filteredR = highPass_[1].process(filteredR);
            }
            if (parameters_.lowPass > 0 && parameters_.lowPass < outputRate * 0.49) {
                filteredL = lowPass_[0].process(filteredL);
                filteredR = lowPass_[1].process(filteredR);
            }
            detector_ = std::max(std::max(std::abs(filteredL), std::abs(filteredR)), detector_ * decay);
            if (detector_ < 1.0e-24) detector_ = 0;
            if (detector_ >= (open_ ? closeThreshold : threshold)) {
                open_ = true;
                holdRemaining_ = parameters_.hold;
            } else if (open_) {
                holdRemaining_ = std::max(0.0, holdRemaining_ - dt);
                if (holdRemaining_ == 0) open_ = false;
            }
            gain_ = open_ ? std::min(1.0, gain_ + attackStep) : std::max(0.0, gain_ - releaseStep);
            left[frame] = output((parameters_.filterOutput ? filteredL : inputL) * gain_);
            if (right) right[frame] = output((parameters_.filterOutput ? filteredR : inputR) * gain_);
        }
    }

private:
    GateParameters parameters_;
    std::array<dynamics_detail::Biquad, 2> highPass_{}, lowPass_{};
    double configuredRate_ = 0, configuredHP_ = -1, configuredLP_ = -1;
    double detector_ = 0, gain_ = 0, holdRemaining_ = 0;
    bool open_ = false;
};
} // namespace catlive::dsp
