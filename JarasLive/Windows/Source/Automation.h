#pragma once
#include "Common.h"
namespace catlive {
// The document representation is shared with TrackAutomation.swift. Compiled curves
// contain no variants or allocations in the audio callback; plugin IDs are prepared once.
struct AutomationCurve {
    enum Target { volume, pan, mute, externalFX, unsupported };
    enum Shape { linear, square, smooth, fastStart, fastEnd };
    struct Point {
        double time, value;
        Shape shape;
    };
    Target target = volume;
    String plugin;
    uint32 parameter = 0;
    double fallback = 1;
    bool linearGain = false;
    std::vector<Point> points;
    static double gain(double normalized) {
        return normalized <= 0 ? 0 : std::pow(10., (-96 + std::min(1., normalized) * 108) / 20);
    }
    static double normalized(double gain) {
        return gain <= 0 ? 0 : jlimit(0., 1., (20 * std::log10(gain) + 96) / 108);
    }
    double value(double time) const {
        if (points.empty())
            return fallback;
        auto next = std::upper_bound(points.begin(), points.end(), time,
                                     [](double t, const Point &p) { return t < p.time; });
        if (next == points.begin())
            return next->value;
        const auto &a = *(next - 1);
        if (next == points.end())
            return a.value;
        const auto &b = *next;
        double x = jlimit(0., 1., (time - a.time) / std::max(.0000001, b.time - a.time));
        if (a.shape == square)
            x = 0;
        else if (a.shape == smooth)
            x = x * x * (3 - 2 * x);
        else if (a.shape == fastStart)
            x = 1 - std::pow(1 - x, 3);
        else if (a.shape == fastEnd)
            x = x * x * x;
        return linearGain ? normalized(gain(a.value) + (gain(b.value) - gain(a.value)) * x)
                          : a.value + (b.value - a.value) * x;
    }
};
struct AutomationProgram {
    bool trim = true, take = false;
    std::vector<AutomationCurve> curves;
    bool controlsMute() const {
        for (const auto &curve : curves)
            if (curve.target == AutomationCurve::mute)
                return true;
        return false;
    }
    void prepare(const var &settings, bool item = false) {
        curves.clear();
        take = item;
        trim = str(settings, "mode", "trimRead") == "trimRead";
        if (!flag(settings, "enabled", true) || (!take && !flag(settings, "lanesVisible", true)))
            return;
        for (const auto &entry : list(get(settings, "envelopes"))) {
            if (!flag(entry, "enabled", true) || (!take && !flag(entry, "visible", true)))
                continue;
            AutomationCurve curve;
            const auto kind = str(get(entry, "target"), "kind");
            curve.target = kind == "volume" ? AutomationCurve::volume
                           : kind == "pan"  ? AutomationCurve::pan
                           : kind == "mute" ? AutomationCurve::mute
                           : kind == "externalFX" ? AutomationCurve::externalFX
                                            : AutomationCurve::unsupported;
            if (curve.target == AutomationCurve::externalFX) {
                curve.plugin = str(get(entry,"target"),"plugin");
                curve.parameter = (uint32)(int64)get(get(entry,"target"),"parameter");
                if (curve.plugin.isEmpty()) continue;
            }
            if (curve.target == AutomationCurve::unsupported)
                continue;
            curve.fallback = jlimit(
                0., 1.,
                num(entry, "defaultValue",
                    curve.target == AutomationCurve::volume ? AutomationCurve::normalized(1) : .5));
            curve.linearGain = str(entry, "valueScale") == "linearGain";
            for (const auto &p : list(get(entry, "points"))) {
                const double time = num(p, "time"), value = num(p, "value");
                if (!std::isfinite(time) || !std::isfinite(value) || time < 0)
                    continue;
                const auto shape = str(p, "shape");
                curve.points.push_back({time, jlimit(0., 1., value),
                                        shape == "square"      ? AutomationCurve::square
                                        : shape == "smooth"    ? AutomationCurve::smooth
                                        : shape == "fastStart" ? AutomationCurve::fastStart
                                        : shape == "fastEnd"   ? AutomationCurve::fastEnd
                                                               : AutomationCurve::linear});
            }
            std::stable_sort(curve.points.begin(), curve.points.end(),
                             [](const auto &a, const auto &b) { return a.time < b.time; });
            curves.push_back(std::move(curve));
        }
    }
    struct Values {
        double gain, pan;
        bool mute;
    };
    Values evaluate(double time, double gain, double pan, bool mute = false) const {
        Values result{gain, pan, mute};
        for (const auto &curve : curves) {
            const double value = curve.value(time);
            if (curve.target == AutomationCurve::volume) {
                const auto level = AutomationCurve::gain(value);
                result.gain =
                    take   ? gain * level
                    : trim ? gain * level / std::max(.000001, AutomationCurve::gain(curve.fallback))
                           : level;
            } else if (curve.target == AutomationCurve::pan) {
                const auto position = value * 2 - 1;
                result.pan = jlimit(-1., 1.,
                                    take   ? pan + position
                                    : trim ? pan + position - (curve.fallback * 2 - 1)
                                           : position);
            } else if (curve.target == AutomationCurve::mute)
                result.mute = take ? (mute || value >= .5) : value >= .5;
        }
        return result;
    }
};
namespace automation {
inline var settings(const jaras::Track &track) {
    return track.automationJSON ? JSON::parse(text(*track.automationJSON)) : object();
}
inline Array<var> visible(const jaras::Track &track) {
    const auto saved = settings(track);
    Array<var> result;
    if (!flag(saved, "enabled", true) || !flag(saved, "lanesVisible", true))
        return result;
    for (auto curve : list(get(saved, "envelopes")))
        if (flag(curve, "visible", true))
            result.add(curve);
    return result;
}
inline var envelope(String kind, double value) {
    auto curve = object(), target = object();
    put(target, "kind", kind);
    put(curve, "target", target);
    put(curve, "id", text(uuid()));
    put(curve, "name", kind == "volume" ? "Volume" : kind == "pan" ? "Pan" : "Mute");
    put(curve, "defaultValue", value);
    put(curve, "enabled", true);
    put(curve, "visible", true);
    put(curve, "armed", false);
    put(curve, "points", Array<var>{});
    return curve;
}
inline void toggle(jaras::Track &track) {
    auto next = settings(track);
    auto curves = list(get(next, "envelopes"));
    const bool show = visible(track).isEmpty();
    if (show && curves.isEmpty())
        curves.add(envelope("volume", AutomationCurve::normalized(track.volume)));
    if (show)
        for (auto &curve : curves)
            put(curve, "visible", true);
    put(next, "envelopes", curves);
    put(next, "enabled", show);
    put(next, "lanesVisible", show);
    track.automationJSON = utf8(JSON::toString(next, true));
}
inline void insert(var &curve, var point) {
    auto points = list(get(curve, "points"));
    for (int i = points.size(); --i >= 0;)
        if (str(points[i], "id") == str(point, "id") ||
            std::abs(num(points[i], "time") - num(point, "time")) < .000001)
            points.remove(i);
    points.add(point);
    std::sort(points.begin(), points.end(),
              [](const var &a, const var &b) { return num(a, "time") < num(b, "time"); });
    put(curve, "points", points);
}
} // namespace automation
} // namespace catlive
