#pragma once
#include "Common.h"
#include "../../Core/Audio/DrummerPad.hpp"
namespace catlive::drummer {
inline int count(const String &kind) { return kind == "Drummer Pad 16" ? 16 : kind == "Drummer Pad 48" ? 48 : 0; }
inline Identifier field(int n) { return n == 16 ? "drummer16" : "drummer48"; }
inline Identifier enabledField(int n) { return n == 16 ? "drummer16Enabled" : "drummer48Enabled"; }
inline var kit(const var &settings, int n) {
    auto state = get(settings, field(n));
    if (list(get(state, "pads")).size() == n) return state;
    state = object(); put(state, "volume", 1.);
    Array<var> pads;
    for (int i = 0; i < n; ++i) {
        auto pad = object(); put(pad, "name", ""); put(pad, "note", 36+i); put(pad, "volume", 1.);
        pads.add(pad);
    }
    put(state, "pads", pads); return state;
}
inline std::array<std::pair<String,File>,3> roots() {
    const auto support = File::getSpecialLocation(File::userApplicationDataDirectory).getChildFile("Hook Developer/CatLive");
    return {{{"Native", File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("NativeSamples")},
             {"User", support.getChildFile("Library/Samplers")}, {"Pads", support.getChildFile("Vinhetas/Pads")}}};
}
inline String reference(const File &file) {
    for (const auto &[name, dir] : roots()) if (file.isAChildOf(dir))
        return name + "/" + file.getRelativePathFrom(dir).replaceCharacter('\\','/');
    return {};
}
inline File resolve(const String &path) {
    const auto relative = path.fromFirstOccurrenceOf("/", false, false);
    for (const auto &[key, dir] : roots()) {
        if (!path.startsWith(key + "/") || relative.containsChar(':') || relative.containsChar('\\')) continue;
        const auto file = dir.getChildFile(relative);
        if (file.isAChildOf(dir) && reference(file) == path) return file;
    }
    return {};
}
inline void configure(jaras::audio::DrummerPad &voice, const var &state) {
    auto pads = list(get(state, "pads"));
    for (int i = 0; i < pads.size(); ++i)
        voice.controls(unsigned(i), int(num(pads[i], "note", -1)), float(num(pads[i], "volume", 1.)));
    voice.setMaster(float(num(state,"volume",1.)));
}
}
