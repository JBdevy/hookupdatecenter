#pragma once
#include "Common.h"

namespace catlive::fxschema {
// Swift's synthesized Codable decoder requires every non-optional field even
// when its declaration has an initial value. Keep Windows FX documents complete
// at the serialization boundary without replacing an existing parameter/state.
inline var complete(const var &source, bool initialEQBands = false, int depth = 0) {
    if (!source.isObject()) return source;
    if (depth > 8) throw std::runtime_error("Invalid nested FX settings.");
    auto result = source.clone();
    const auto missing = [](var &value, const char *key, var fallback) {
        if (get(value, key).isVoid()) put(value, key, std::move(fallback));
    };
    missing(result, "inserted", Array<var>{});
    for (const auto *key : {"eqEnabled", "compressorEnabled", "delayEnabled", "reverbEnabled"})
        missing(result, key, false);
    const std::pair<const char *, double> numbers[]{
        {"threshold", -20}, {"ratio", 4}, {"attack", .005}, {"release", .1}, {"makeup", 0},
        {"delayTime", .25}, {"feedback", 25}, {"delayMix", 20}, {"reverbMix", 20},
        {"reverbDecay", 2}, {"reverbLowCut", 80}, {"reverbHighCut", 12000}};
    for (const auto &[key, value] : numbers) missing(result, key, value);
    missing(result, "reverbRoom", 1);
    if (get(result, "bands").isVoid()) {
        Array<var> bands;
        if (initialEQBands) {
            const double frequencies[]{30, 200, 1000, 5000, 18000};
            for (int index = 0; index < 5; ++index) {
                auto band = object();
                put(band, "frequency", frequencies[index]);
                put(band, "type", index == 0 ? "lowCut" : index == 4 ? "highCut" : "bell");
                bands.add(band);
            }
        }
        put(result, "bands", bands);
    }
    for (auto band : list(get(result, "bands"))) {
        if (!band.isObject()) continue;
        if (get(band, "id").isVoid()) put(band, "id", text(uuid()));
        missing(band, "gain", 0.); missing(band, "q", .707); missing(band, "type", "bell");
        missing(band, "slope", 12); missing(band, "enabled", true);
    }
    for (auto instance : list(get(result, "instances")))
        if (instance.isObject() && get(instance, "settings").isObject())
            put(instance, "settings", complete(get(instance, "settings"), false, depth + 1));
    for (auto plugin : list(get(result, "externalPlugins"))) {
        if (!plugin.isObject()) continue;
        missing(plugin, "category", ""); missing(plugin, "bypassed", false);
    }
    auto limiter = get(result, "limiter");
    if (limiter.isObject()) {
        missing(limiter, "inputGain", 0.); missing(limiter, "ceiling", -.1); missing(limiter, "release", .1);
    }
    auto instrument = get(result, "instrumentParameters");
    if (instrument.isObject()) {
        for (const auto &[key, value] : std::initializer_list<std::pair<const char *, double>>{
                 {"gain", 0}, {"attack", 0}, {"hold", 10}, {"decay", 10}, {"sustain", 1}, {"release", .3}})
            missing(instrument, key, value);
        auto controllers = get(instrument, "controllers");
        if (controllers.isObject()) { missing(controllers, "modulation", false); missing(controllers, "pitchBend", false); }
        auto velocity = get(instrument, "velocity");
        if (velocity.isObject()) { missing(velocity, "curve", "medium"); missing(velocity, "cutoffMinimum", 20000.); }
        auto cutoff = get(instrument, "cutoff");
        if (cutoff.isObject())
            for (const auto &[key, value] : std::initializer_list<std::pair<const char *, double>>{
                     {"frequency", 20000}, {"attack", 0}, {"hold", 0}, {"decay", .3}, {"sustain", 1}, {"release", .3}, {"depth", 0}})
                missing(cutoff, key, value);
    }
    auto stems = get(result, "stemMix");
    if (stems.isObject()) {
        if (get(stems, "sources").isVoid()) {
            Array<var> sources; for (int i = 0; i < 5; ++i) sources.add(object());
            put(stems, "sources", sources);
        }
        for (auto source : list(get(stems, "sources"))) if (source.isObject()) {
            missing(source, "gain", 1.); missing(source, "mute", false); missing(source, "solo", false);
        }
    }
    return result;
}
inline var defaults(bool initialEQBands = false) { return complete(object(), initialEQBands); }
} // namespace catlive::fxschema
