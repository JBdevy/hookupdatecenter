#pragma once
#include "Common.h"
#include "../../Core/Audio/WaveLFO.hpp"

namespace catlive {
struct WaveLFOParameters {
    double attack = .05, decay = .20, sustain = .75, release = .25;
    bool enabled = false;

    static WaveLFOParameters read(const var& settings) {
        WaveLFOParameters e;
        e.enabled = flag(settings, "waveLFOEnabled") && list(get(settings, "inserted")).contains(var("Wave LFO"));
        const auto data = get(settings, "waveLFO");
        e.attack = jlimit(0., 60., num(data, "attack", e.attack));
        e.decay = jlimit(0., 60., num(data, "decay", e.decay));
        e.sustain = jlimit(0., 1., num(data, "sustain", e.sustain));
        e.release = jlimit(0., 60., num(data, "release", e.release));
        return e;
    }
    var json() const {
        auto data = object();
        put(data, "attack", attack); put(data, "decay", decay);
        put(data, "sustain", sustain); put(data, "release", release);
        return data;
    }
    jaras::WaveLFO shape(double duration) const {
        return enabled ? jaras::WaveLFO::prepare(duration, attack, decay, sustain, release) : jaras::WaveLFO{};
    }
    static juce::Rectangle<float> body(juce::Rectangle<float> rect) {
        return rect.withTrimmedTop(21.f).withTrimmedBottom(3.f);
    }
    std::array<Point<float>,5> points(juce::Rectangle<float> rect, double duration) const {
        const auto bounds = body(rect);
        const auto e = shape(duration);
        const auto x = [&](double t) {return bounds.getX() + float(t / duration) * bounds.getWidth();};
        const float y = bounds.getBottom() - float(e.sustain) * bounds.getHeight();
        return {{bounds.getBottomLeft(), {x(e.attackEnd), bounds.getY()}, {x(e.decayEnd), y},
                 {x(e.releaseStart), y}, bounds.getBottomRight()}};
    }
    WaveLFOParameters drag(int handle, Point<float> point, juce::Rectangle<float> rect, double duration) const {
        auto result = *this;
        const auto b = body(rect);
        const auto fitted = shape(duration);
        result.attack = fitted.attackEnd;
        result.decay = fitted.decayEnd - fitted.attackEnd;
        result.release = duration - fitted.releaseStart;
        const double t = jlimit(0., duration, duration * (point.x - b.getX()) / b.getWidth());
        if (handle == 1) result.attack = jlimit(0., std::max(0., std::min(60., duration - result.decay - result.release)), t);
        if (handle == 2) {
            result.decay = jlimit(0., std::max(0., std::min(60., fitted.releaseStart - result.attack)), t - result.attack);
            result.sustain = jlimit(0., 1., double((b.getBottom() - point.y) / b.getHeight()));
        }
        if (handle == 3) result.release = jlimit(0., std::max(0., std::min(60., duration - fitted.decayEnd)), duration - t);
        return result;
    }
};
}
