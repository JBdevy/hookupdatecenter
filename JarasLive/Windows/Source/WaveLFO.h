#pragma once
#include "Common.h"
#include "../../Core/Audio/WaveLFO.hpp"
#include "../../Core/Tracks/Track.hpp"

namespace catlive {
struct WaveLFOParameters {
    double attack = .05, hold = 0, decay = .20, sustain = .75, release = .25;
    bool enabled = false, inserted = false;
    static bool supports(const jaras::AudioClip& clip, const jaras::Track& track) {
        const auto& file = clip.audioFile ? clip.audioFile : track.audioFile;
        return !clip.midi && file && !File::getCurrentWorkingDirectory().getChildFile(text(file->path))
            .hasFileExtension("png;jpg;jpeg;bmp;gif;tif;tiff;heic;webp");
    }
    const WaveLFOParameters& inheriting(const WaveLFOParameters& track, bool bypassed) const noexcept {
        return inserted && !bypassed ? *this : track;
    }

    static WaveLFOParameters read(const var& settings) {
        WaveLFOParameters e;
        e.inserted = list(get(settings, "inserted")).contains(var("Wave LFO"));
        e.enabled = e.inserted && flag(settings, "waveLFOEnabled");
        const auto data = get(settings, "waveLFO");
        e.attack = jlimit(0., 60., num(data, "attack", e.attack));
        e.hold = jlimit(0., 60., num(data, "hold", 0));
        e.decay = jlimit(0., 60., num(data, "decay", e.decay));
        e.sustain = jlimit(0., 1., num(data, "sustain", e.sustain));
        e.release = jlimit(0., 60., num(data, "release", e.release));
        return e;
    }
    var json() const {
        auto data = object();
        put(data, "attack", attack); put(data, "hold", hold); put(data, "decay", decay);
        put(data, "sustain", sustain); put(data, "release", release);
        return data;
    }
    jaras::WaveLFO prepared(double duration) const {
        return jaras::WaveLFO::prepare(duration, attack, hold, decay, sustain, release);
    }
    jaras::WaveLFO shape(double duration) const {
        return enabled ? prepared(duration) : jaras::WaveLFO{};
    }
    static juce::Rectangle<float> body(juce::Rectangle<float> rect) {
        return rect.withTrimmedTop(21.f).withTrimmedBottom(3.f);
    }
    std::array<Point<float>,6> points(juce::Rectangle<float> rect, double duration) const {
        const auto bounds = body(rect);
        std::array<Point<float>,6> result;
        const auto vertices = prepared(duration).vertices();
        for (size_t i = 0; i < result.size(); ++i) {
            result[i] = {bounds.getX() + float(vertices[i].time / duration) * bounds.getWidth(),
                         bounds.getBottom() - float(vertices[i].gain) * bounds.getHeight()};
        }
        return result;
    }
    WaveLFOParameters drag(int handle, Point<float> point, juce::Rectangle<float> rect, double duration) const {
        auto result = *this;
        const auto b = body(rect);
        const auto shape = prepared(duration);
        result.attack = shape.attackEnd;
        result.hold = shape.holdEnd - shape.attackEnd;
        result.decay = shape.decayEnd - shape.holdEnd;
        result.release = duration - shape.releaseStart;
        const double t = jlimit(0., duration, duration * (point.x - b.getX()) / std::max(1.f, b.getWidth()));
        if (handle == 1) result.attack = jlimit(0., std::clamp(duration - result.hold - result.decay - result.release, 0., 60.), t);
        if (handle == 2) result.hold = jlimit(0., std::clamp(duration - result.attack - result.decay - result.release, 0., 60.), t - result.attack);
        if (handle == 3) {
            result.decay = jlimit(0., std::clamp(shape.releaseStart - shape.holdEnd, 0., 60.), t - shape.holdEnd);
            result.sustain = jlimit(0., 1., double((b.getBottom() - point.y) / std::max(1.f, b.getHeight())));
        }
        if (handle == 4) result.release = jlimit(0., std::clamp(duration - shape.decayEnd, 0., 60.), duration - t);
        return result;
    }
};
}
