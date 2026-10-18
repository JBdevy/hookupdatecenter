#pragma once
#include "Common.h"
#include "Localization.h"

namespace catlive::timelineRegionLabels {
inline String displayName(const jaras::Part &part) {
    const auto name=text(part.name);
    if (!part.uppercaseName.value_or(true)) return name;
    // Match Part.displayName on Mac: uppercase the name by default while
    // preserving annotations inside parentheses, including nested ones.
    String result, outside;
    int depth=0;
    for (const auto character:name) {
        if (character=='(') {
            result+=unicodeCase(outside);outside.clear();++depth;
        }
        if (depth>0) result+=String::charToString(character);
        else outside+=String::charToString(character);
        if (character==')') depth=std::max(0,depth-1);
    }
    return result+unicodeCase(outside);
}

inline std::set<ID> parents(const jaras::Song &song) {
    std::set<ID> result;
    for (const auto &part : song.parts) if (part.parentRegionID) result.insert(*part.parentRegionID);
    return result;
}
inline String identifier(const jaras::Song &song, size_t index, const std::set<ID> &parents) {
    if (index >= song.parts.size() || song.parts[index].parentRegionID) return {};
    const auto &part = song.parts[index];
    if (parents.count(part.id)) return localization::translate("Special");
    // Like the Mac header, the number belongs to the persisted region, not its
    // chronological position or the currently selected playlist.
    return String::formatted("%dst  %02d", part.pitchSemitones.value_or(0), (int)index + 1);
}

inline String marker(const jaras::Song &song, const jaras::TimelineMarker &value) {
    if (value.tempoBPM)
        return String::formatted("%g  %d/%d",*value.tempoBPM,value.tempoBeats.value_or(4),value.tempoUnit.value_or(4));
    if (value.sourceRegionID)
        for (const auto &part : song.parts)
            if (part.id == *value.sourceRegionID)
                return String(part.pitchSemitones.value_or(0)) + "st  " + text(value.name);
    return value.section.value_or(false) ? unicodeCase(text(value.name)) : text(value.name);
}
}
