#pragma once
#include "PluginTransport.hpp"
#include <atomic>
#include <cstdint>
#include <limits>

namespace jaras {
// Single control publisher / single render reader. All payload members are
// atomic: an interrupted publication cannot cause a C++ data race. Rendering
// takes one bounded attempt, retaining the previous coherent clock if busy.
class PluginTransportClock {
public:
    void publish(double position, double clock, bool playing, double loopStart = 0, double loopEnd = 0,
                 double tempo = 120, int beats = 4, int unit = 4) noexcept {
        generation.fetch_add(1);
        origin = position; anchor = clock; running = playing; lo = loopStart; hi = loopEnd;
        bpm = tempo; numerator = beats; denominator = unit;
        generation.fetch_add(1);
    }
    PluginTransport render(double clock, double rate, unsigned frames, const PluginTempoMap* map) noexcept {
        const auto serial = generation.load();
        if (!(serial & 1) && serial != seen) {
            const State next{origin.load(), anchor.load(), lo.load(), hi.load(), bpm.load(), numerator.load(), denominator.load(), running.load()};
            if (serial == generation.load()) { state = next; seen = serial; elapsedFrames = 0; }
        }
        const bool anchored = std::isfinite(state.anchor) && std::isfinite(clock);
        const double elapsed = anchored ? clock - state.anchor : elapsedFrames / rate;
        const bool moving = state.playing && (!anchored || elapsed >= 0);
        double position = state.origin + (state.playing ? std::max(0., elapsed) : 0.);
        if (moving && state.hi > state.lo && position >= state.hi)
            position = state.lo + std::fmod(position - state.lo, state.hi - state.lo);
        if (state.playing) elapsedFrames += frames;
        if (map) return map->at(position, moving);
        const double quarters = position * state.bpm / 60.;
        const double bar = state.beats * 4. / state.unit;
        return {position, quarters, state.bpm, state.beats, state.unit, moving, std::floor(quarters / bar) * bar};
    }
private:
    struct State {
        double origin = 0, anchor = std::numeric_limits<double>::quiet_NaN(), lo = 0, hi = 0, bpm = 120;
        int beats = 4, unit = 4; bool playing = false;
    } state;
    std::atomic<std::uint64_t> generation{0};
    std::atomic<double> origin{0}, anchor{std::numeric_limits<double>::quiet_NaN()}, lo{0}, hi{0}, bpm{120};
    std::atomic<int> numerator{4}, denominator{4};
    std::atomic<bool> running{false};
    std::uint64_t seen = 0, elapsedFrames = 0;
};
}
