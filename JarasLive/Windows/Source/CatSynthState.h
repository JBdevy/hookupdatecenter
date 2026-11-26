#pragma once
#include "Common.h"
#include "../../Core/Audio/CatSynth.hpp"

namespace catlive::synthState {
using Synth = jaras::audio::CatSynth;

inline int selected(const var &bank) {
    return jlimit(0, int(Synth::presetCount) - 1, (int)get(bank, "selected"));
}
inline Synth::Patch patch(const var &bank, int slot) {
    auto values = Synth::factory(unsigned(slot));
    const auto slots = list(get(bank, "slots"));
    if (slot >= slots.size()) return values;
    const auto saved = list(slots[slot]);
    if (saved.size() != int(values.size())) return values;
    for (int i = 0; i < saved.size(); ++i) {
        if (saved[i].isDouble() || saved[i].isInt() || saved[i].isInt64()) values[size_t(i)] = float((double)saved[i]);
    }
    return values;
}
inline Synth::Patch patch(const var &bank) { return patch(bank, selected(bank)); }

inline String name(const var &bank, int slot) {
    const auto names = list(get(bank, "names"));
    if (slot < names.size() && names[slot].isString() && names[slot].toString().isNotEmpty())
        return names[slot].toString();
    return Synth::names[size_t(slot)];
}

inline void rename(var &bank, int slot, String name) {
    auto names = list(get(bank, "names"));
    names.resize(int(Synth::presetCount));
    name = name.trim().substring(0, 20);
    names.set(slot, name.isEmpty() || name == Synth::names[size_t(slot)] ? var() : var(name));
    put(bank, "names", std::move(names));
}

inline var bank(var stored) {
    if (!stored.isObject()) stored = object();
    auto slots = list(get(stored, "slots"));
    slots.resize(int(Synth::presetCount));
    put(stored, "slots", slots);
    put(stored, "selected", selected(stored));
    return stored;
}
inline void save(var &bank, const Synth::Patch &patch, int slot) {
    auto slots = list(get(bank, "slots"));
    Array<var> values;
    for (const auto value : patch) values.add(var(double(value)));
    slots.set(slot, var(values));
    put(bank, "slots", slots);
}
}
