#pragma once
#include "FXPresets.h"
#include "FXSchema.h"
#include "InstrumentAssets.h"

namespace catlive::fxui {
inline String enabledKey(const String &kind) {
    if (kind == "Wave LFO") return "waveLFOEnabled";
    if (const auto *spec = jaras::audio::creativeEffect(utf8(kind))) return spec->enabledField;
    if (kind == "CatSynth") return "catSynthEnabled";
    return kind == "Drummer Pad 16" ? "drummer16Enabled" : kind == "Drummer Pad 48" ? "drummer48Enabled" : kind == "Arpeggiator" ? "arpeggiatorEnabled"
           : kind == "CatLive Trigger" ? "triggerEnabled"
           : kind == "Cat Gate" ? "gateEnabled"
           : kind == "CatStemSeparation 5" ? "stemSeparatorEnabled"
           : kind == "EQ"            ? "eqEnabled"
           : kind == "Compressor"  ? "compressorEnabled"
           : kind == "Delay"       ? "delayEnabled"
           : kind == "Reverb"      ? "reverbEnabled"
           : kind == "Limiter"     ? "limiterEnabled"
           : kind == "Pitch"       ? "pitchEnabled"
           : kind == "Instruments" ? "instrumentBypassed"
           : kind == "External"    ? "bypassed"
                                   : "";
}
inline bool isEnabled(const String &kind, const var &settings) {
    const auto key = enabledKey(kind);
    return key.isNotEmpty() && ((kind == "Instruments" || kind == "External") ? !flag(settings, Identifier(key))
                                                      : flag(settings, Identifier(key)));
}
inline void enable(const String &kind, var &settings, bool value) {
    const auto key = enabledKey(kind);
    if (key.isNotEmpty())
        put(settings, Identifier(key), (kind == "Instruments" || kind == "External") ? !value : value);
}
inline void defaults(var &s) {
    s = s.isObject() ? fxschema::complete(s, true) : fxschema::defaults(true);
    if (!get(s, "trigger").isObject()) {
        auto trigger = object();
        for (const auto &[key, value] : std::map<String, double>{{"threshold",-30},{"retrigger",.08},{"gain",0},{"mix",100},{"attack",0},{"decay",.1},{"sustain",1},{"release",.02}}) put(trigger, Identifier(key), value);
        put(s, "trigger", trigger);
    }
    if (!get(s, "gate").isObject()) {
        auto gate = object();
        for (const auto &[key, value] : std::map<String, double>{{"threshold",-40},{"attack",.001},{"decay",.02},{"hold",.05},{"release",.1},{"highPass",20},{"lowPass",20000}}) put(gate, Identifier(key), value);
        put(gate, "filterOutput", false); put(s, "gate", gate);
    }
    if (get(s, "pitchFormant").isVoid()) put(s, "pitchFormant", 0.);
    if (get(s, "pitchSemitones").isVoid()) put(s, "pitchSemitones", 0.);
    if (!get(s, "limiter").isObject()) {
        auto l = object();
        put(l, "ceiling", -.1);
        put(l, "release", .1);
        put(l, "inputGain", 0);
        put(s, "limiter", l);
    }
}
inline var instrumentParameters(const String &instrument) {
    auto parameters = object(), controllers = object();
    put(parameters, "gain", 0);
    put(parameters, "attack", 0);
    put(parameters, "hold", 10);
    put(parameters, "decay", 10);
    put(parameters, "sustain", 1);
    put(parameters, "release", instrument.startsWith("drum-") ? 20. : .16);
    String category;
    for (auto item : instrumentAssets::catalog())
        if (str(item, "id") == instrument)
            category = str(item, "category");
    put(controllers, "modulation", category == "synthPad" || category == "strings");
    put(controllers, "pitchBend", category == "bass" || category == "lead");
    put(controllers, "monophonic", category == "lead");
    put(parameters, "controllers", controllers);
    return parameters;
}
inline void reset(const String &kind, var &settings) {
    for (const auto &key : fxpresets::fields(kind)) fxpresets::erase(settings, Identifier(key));
    defaults(settings);
}
} // namespace catlive::fxui
