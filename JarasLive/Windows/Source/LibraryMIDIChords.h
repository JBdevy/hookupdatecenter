#pragma once
#include "Common.h"

namespace catlive::libraryChords {
inline const var& catalog() {
    static const auto entries = JSON::parse(File::getSpecialLocation(File::currentExecutableFile)
                                             .getSiblingFile("MIDIChords").getChildFile("catalog.json"));
    return entries;
}

inline const var* find(const String& name) {
    if (const auto* chords = catalog().getArray())
        for (const auto& chord : *chords)
            if (str(chord, "name") == name) return &chord;
    return nullptr;
}
}
