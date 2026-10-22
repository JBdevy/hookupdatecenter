#include "../../Core/Include/CatDynamicsDSP.hpp"
#include <cstdlib>
#include <iostream>
#include <limits>
#include <new>
#include <stdexcept>
#include <string>

static bool watchAllocations = false;
static std::size_t realtimeAllocations = 0;
void* operator new(std::size_t count) {
    if (watchAllocations) ++realtimeAllocations;
    if (void* result = std::malloc(count ? count : 1)) return result;
    throw std::bad_alloc();
}
void* operator new[](std::size_t count) { return ::operator new(count); }
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete[](void* memory) noexcept { std::free(memory); }
void operator delete(void* memory, std::size_t) noexcept { std::free(memory); }
void operator delete[](void* memory, std::size_t) noexcept { std::free(memory); }

using catlive::dsp::Trigger;
using catlive::dsp::TriggerParameters;
using catlive::dsp::Gate;
using catlive::dsp::GateParameters;
constexpr double pi = 3.14159265358979323846;

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
static void near(double value, double expected, double tolerance, const char* message) {
    if (std::abs(value - expected) > tolerance) {
        std::cerr << message << ": " << value << " expected " << expected << '\n';
        throw std::runtime_error(message);
    }
}
static std::vector<float> constant(double seconds, double rate, float value) {
    return std::vector<float>(static_cast<std::size_t>(std::llround(seconds * rate)), value);
}
static std::vector<float> tone(double seconds, double rate, double frequency, float gain) {
    auto result = constant(seconds, rate, 0);
    for (std::size_t i = 0; i < result.size(); ++i)
        result[i] = gain * static_cast<float>(std::sin(2 * pi * frequency * static_cast<double>(i) / rate));
    return result;
}
template<class Processor>
static void render(Processor& processor, std::vector<float>& left, std::vector<float>* right,
                   double rate, int blockSize = 127) {
    watchAllocations = true;
    for (std::size_t offset = 0; offset < left.size();) {
        const auto count = static_cast<int>(std::min(static_cast<std::size_t>(blockSize), left.size() - offset));
        processor.process(left.data() + offset, right ? right->data() + offset : nullptr, count, rate);
        offset += count;
    }
    watchAllocations = false;
    require(realtimeAllocations == 0, "DSP process allocated memory");
    for (const auto value : left) require(std::isfinite(value), "non-finite left output");
    if (right) for (const auto value : *right) require(std::isfinite(value), "non-finite right output");
}
static double rms(const std::vector<float>& values, std::size_t from = 0) {
    double power = 0;
    for (std::size_t i = from; i < values.size(); ++i) power += values[i] * values[i];
    return std::sqrt(power / static_cast<double>(values.size() - from));
}
static TriggerParameters basicTrigger() {
    TriggerParameters value;
    value.threshold = -20; value.retrigger = 0.05;
    value.attack = value.decay = value.release = 0;
    return value;
}
static GateParameters basicGate() {
    GateParameters value;
    value.threshold = -20;
    value.attack = value.decay = value.hold = value.release = 0;
    value.highPass = value.lowPass = 0;
    return value;
}
static void triggerTests(double rate) {
    auto parameters = basicTrigger();
    {
        Trigger trigger;
        auto input = tone(.1, rate, 440, .25f), reference = input;
        render(trigger, input, nullptr, rate);
        require(input == reference, "unloaded trigger must pass input through");
        trigger.setSample({.5f}, {}, rate);
        trigger.setParameters(parameters);
        auto quiet = constant(.2, rate, .01f);
        render(trigger, quiet, nullptr, rate);
        require(rms(quiet) == 0, "noise below trigger threshold fired sample");
    }
    {
        // A sustained waveform crosses zero every cycle but must trigger only
        // once; otherwise the replacement becomes a machine-gun oscillator.
        Trigger trigger;
        trigger.setSample({.8f}, {}, rate);
        trigger.setParameters(parameters);
        auto input = tone(.5, rate, 200, .5f);
        render(trigger, input, nullptr, rate);
        std::size_t hits = 0;
        for (float value : input) if (value > .4f) ++hits;
        require(hits == 1, "sustained input retriggered without a fresh attack");
        trigger.reset();
        input = constant(.7, rate, 0);
        for (double time : {.01, .25, .5}) input[static_cast<std::size_t>(time * rate)] = 1;
        render(trigger, input, nullptr, rate);
        hits = 0;
        for (float value : input) if (value > .4f) ++hits;
        require(hits == 3, "separate input attacks did not retrigger");
    }
    {
        Trigger trigger;
        trigger.setSample({1.f}, {}, rate);
        parameters.retrigger = .3;
        trigger.setParameters(parameters);
        auto input = constant(.5, rate, 0);
        input[0] = 1;
        for (std::size_t i = static_cast<std::size_t>(.1 * rate); i < input.size(); ++i) input[i] = 1;
        render(trigger, input, nullptr, rate);
        std::size_t hits = 0;
        for (float value : input) if (value > .5f) ++hits;
        require(hits == 1, "retrigger interval queued a false late hit on sustained signal");
        parameters = basicTrigger();
    }
    for (double sourceRate : {44100., 48000.}) {
        Trigger trigger;
        auto sample = tone(.12, sourceRate, 733, .75f);
        auto opposite = sample;
        for (auto& value : opposite) value = -value;
        trigger.setSample(sample, opposite, sourceRate);
        trigger.setParameters(parameters);
        auto left = constant(.2, rate, 0), right = left;
        right[0] = 1;
        render(trigger, left, &right, rate);
        const auto duration = static_cast<std::size_t>(std::ceil(sample.size() * rate / sourceRate));
        for (std::size_t i = 0; i + 2 < duration; ++i) {
            const double expected = .75 * std::sin(2 * pi * 733 * static_cast<double>(i) / rate);
            near(left[i], expected, .0012, "mixed-rate sample pitch or timing changed");
            near(right[i], -left[i], 1e-7, "trigger lost stereo sample channel");
        }
        for (std::size_t i = duration + 1; i < left.size(); ++i)
            require(left[i] == 0 && right[i] == 0, "one-shot exceeded original sample duration");
    }
    {
        Trigger trigger;
        trigger.setSample(constant(.1, rate, 1), {}, rate);
        parameters.attack = .01; parameters.decay = .02;
        parameters.sustain = .3; parameters.release = .02;
        trigger.setParameters(parameters);
        auto input = constant(.15, rate, 0); input[0] = 1;
        render(trigger, input, nullptr, rate);
        near(input[static_cast<std::size_t>(.005 * rate)], .5, .003, "trigger attack incorrect");
        near(input[static_cast<std::size_t>(.02 * rate)], .65, .003, "trigger decay incorrect");
        near(input[static_cast<std::size_t>(.05 * rate)], .3, .003, "trigger sustain incorrect");
        near(input[static_cast<std::size_t>(.09 * rate)], .15, .003, "trigger release incorrect");
        trigger.reset(); parameters.attack = 0; parameters.decay = .01; parameters.sustain = 0;
        trigger.setParameters(parameters);
        input = constant(.15, rate, 0); input[0] = 1;
        render(trigger, input, nullptr, rate);
        require(input[0] == 1 && input[static_cast<std::size_t>(.02 * rate)] == 0,
                "zero-sustain percussive envelope silent or failed to decay");
        parameters = basicTrigger(); parameters.attack = .01; parameters.release = .02;
        trigger.setSample(constant(.005, rate, 1), {}, rate);
        trigger.setParameters(parameters);
        input = constant(.02, rate, 0); input[0] = 1;
        render(trigger, input, nullptr, rate);
        require(rms(input) > .1, "short sample was silenced by attack plus release");
        parameters = basicTrigger();
    }
    {
        Trigger trigger;
        trigger.setSample(constant(.5, rate, .5f), {}, rate);
        trigger.setParameters(parameters);
        auto input = constant(.6, rate, 0); input[0] = input[static_cast<std::size_t>(.2 * rate)] = 1;
        render(trigger, input, nullptr, rate);
        near(input[static_cast<std::size_t>(.3 * rate)], 1, 1e-7, "one-shot tail cut instead of overlapping");
    }
    {
        Trigger trigger;
        trigger.setSample(constant(.1, rate, 1), {}, rate);
        parameters.gain = -6; parameters.mix = 50;
        trigger.setParameters(parameters);
        auto input = constant(.2, rate, .5f);
        render(trigger, input, nullptr, rate);
        near(input[static_cast<std::size_t>(.05 * rate)], .25 + .5 * std::pow(10.0, -6.0 / 20.0),
             1e-7, "trigger output gain or dry/wet mix uses wrong scale");
        near(input.back(), .25, 1e-7, "dry mix disappeared after sample completed");
        parameters = basicTrigger();
    }
    {
        // The UI permits a 20-second release, which must not be silently
        // clamped to the 10-second maximum of the attack/decay controls.
        Trigger trigger;
        trigger.setSample(constant(25, rate, 1), {}, rate);
        parameters.release = 20;
        trigger.setParameters(parameters);
        auto input = constant(6.1, rate, 0); input[0] = 1;
        render(trigger, input, nullptr, rate);
        near(input[static_cast<std::size_t>(6 * rate)], .95, 1e-6,
             "20-second trigger release was clamped below model range");
        parameters = basicTrigger();
    }
    {
        Trigger trigger;
        trigger.setSample(constant(4, rate, 1), {}, rate);
        parameters.retrigger = 0;
        trigger.setParameters(parameters);
        auto input = constant(3, rate, 0);
        for (std::size_t i = 0; i < 25; ++i) input[static_cast<std::size_t>(.1 * i * rate)] = 1;
        render(trigger, input, nullptr, rate);
        require(*std::max_element(input.begin(), input.end()) == Trigger::maximumVoices,
                "trigger voices exceeded bounded pool or failed to steal oldest");
        parameters = basicTrigger();
    }
    {
        Trigger a, b;
        auto sample = tone(.3, 44100, 317, .5f);
        a.setSample(sample, {}, 44100); b.setSample(sample, {}, 44100);
        a.setParameters(parameters); b.setParameters(parameters);
        auto first = constant(.6, rate, 0); first[0] = first[static_cast<std::size_t>(.2 * rate)] = 1;
        auto second = first;
        render(a, first, nullptr, rate, 1); render(b, second, nullptr, rate, 257);
        require(first == second, "trigger changes with callback block size");
    }
}
static void gateTests(double rate) {
    auto parameters = basicGate();
    {
        Gate gate;
        gate.setParameters(parameters);
        auto input = constant(.1, rate, .01f);
        render(gate, input, nullptr, rate);
        require(rms(input) == 0, "gate leaked signal below threshold");
        auto left = constant(.1, rate, .02f), right = constant(.1, rate, .5f);
        render(gate, left, &right, rate);
        near(left.back(), .02, 1e-7, "right-channel detector did not open left gate");
        near(right.back(), .5, 1e-7, "gate changed open right channel level");
    }
    {
        Gate gate;
        parameters.attack = .01; parameters.hold = .02; parameters.release = .03;
        gate.setParameters(parameters);
        auto input = constant(.12, rate, .01f);
        std::fill(input.begin(), input.begin() + static_cast<std::size_t>(.04 * rate), .5f);
        render(gate, input, nullptr, rate);
        near(input[static_cast<std::size_t>(.005 * rate)], .25, .003, "gate attack time wrong");
        near(input[static_cast<std::size_t>(.05 * rate)], .01, 1e-6, "gate hold failed");
        near(input[static_cast<std::size_t>(.075 * rate)], .005, .00002, "gate release time wrong");
        require(input[static_cast<std::size_t>(.1 * rate)] == 0, "gate failed to fully close");
        parameters = basicGate();
    }
    {
        Gate gate;
        parameters.decay = .1;
        gate.setParameters(parameters);
        auto input = constant(.4, rate, .001f); input[0] = 1;
        render(gate, input, nullptr, rate);
        require(input[static_cast<std::size_t>(.2 * rate)] > 0 && input[static_cast<std::size_t>(.3 * rate)] == 0,
                "gate detector decay does not affect closing independently of output release");
        parameters = basicGate();
    }
    for (bool highPass : {false, true}) {
        Gate gate;
        parameters.highPass = highPass ? 500 : 0;
        parameters.lowPass = highPass ? 0 : 500;
        parameters.decay = .005;
        gate.setParameters(parameters);
        auto rejected = tone(.5, rate, highPass ? 30 : 6000, .5f);
        render(gate, rejected, nullptr, rate);
        require(rms(rejected, static_cast<std::size_t>(.2 * rate)) == 0,
                "detector filter did not reject out-of-band signal");
        gate.reset();
        auto passed = tone(.5, rate, highPass ? 3000 : 100, .5f), reference = passed;
        render(gate, passed, nullptr, rate);
        for (std::size_t i = static_cast<std::size_t>(.2 * rate); i < passed.size(); ++i)
            near(passed[i], reference[i], 1e-7, "detector-only filters colored audible output");
    }
    {
        Gate gate;
        parameters = basicGate(); parameters.threshold = -100;
        parameters.highPass = 500; parameters.filterOutput = true;
        parameters.decay = .01;
        gate.setParameters(parameters);
        auto input = tone(.5, rate, 50, .5f);
        render(gate, input, nullptr, rate);
        require(rms(input, static_cast<std::size_t>(.2 * rate)) < .01,
                "optional audible detector filtering did not attenuate out-of-band input");
        parameters = basicGate();
    }
    {
        Gate a, b;
        parameters.attack = .004; parameters.decay = .006;
        parameters.hold = .01; parameters.release = .02;
        parameters.highPass = 80; parameters.lowPass = 12000;
        a.setParameters(parameters); b.setParameters(parameters);
        auto first = tone(.6, rate, 1000, .5f);
        for (std::size_t i = first.size()/2; i < first.size(); ++i) first[i] *= .02f;
        auto second = first;
        render(a, first, nullptr, rate, 1); render(b, second, nullptr, rate, 511);
        require(first == second, "gate changes with callback block size");
        a.reset(); b.reset();
        first = tone(.2, rate, 1000, .5f); second = first;
        render(a, first, nullptr, rate);
        watchAllocations = true;
        b.process(second.data(), second.data(), static_cast<int>(second.size()), rate);
        watchAllocations = false;
        require(first == second, "aliased mono channel was processed twice");
    }
    {
        Gate gate; Trigger trigger;
        const double nan = std::numeric_limits<double>::quiet_NaN();
        parameters.threshold = parameters.attack = parameters.highPass = parameters.lowPass = nan;
        gate.setParameters(parameters);
        TriggerParameters invalid; invalid.threshold = invalid.gain = invalid.attack = nan;
        trigger.setParameters(invalid);
        trigger.setSample({1, std::numeric_limits<float>::quiet_NaN(), 1}, {}, rate);
        std::vector<float> input{1, std::numeric_limits<float>::infinity(), -1,
            std::numeric_limits<float>::quiet_NaN(), 0};
        render(gate, input, nullptr, nan);
        render(trigger, input, nullptr, nan);
    }
}
int main() {
    try {
        for (double rate : {44100., 48000.}) {
            triggerTests(rate); gateTests(rate);
            std::cout << "CAT_DYNAMICS_PCM_OK " << rate << " Hz\n";
        }
        require(realtimeAllocations == 0, "realtime allocations detected");
        std::cout << "CAT_DYNAMICS_BLOCK_INVARIANCE_STEREO_RESAMPLE_ENVELOPE_FILTER_NO_ALLOC_OK\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
