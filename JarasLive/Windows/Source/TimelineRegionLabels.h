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

// Match the Mac's region-boundary clipping, including overlapping regions.
// A linked song marker belongs to its unified parent; other markers use the
// earliest end of the root regions that contain their position.
inline double markerRegionEnd(const jaras::Song &song, const jaras::TimelineMarker &marker) {
    double end=std::numeric_limits<double>::infinity();
    for(const auto &part:song.parts) {
        if(part.parentRegionID) continue;
        if(marker.unifiedRegionID && *marker.unifiedRegionID==part.id) return part.endTime;
        if(part.startTime<=marker.position && marker.position<part.endTime) end=std::min(end,part.endTime);
    }
    return end;
}
inline float markerHeadWidth(double position, double next, double regionEnd, float naturalWidth, double scale) {
    const auto available=std::min({(double)naturalWidth,(next-position)*scale-3,(regionEnd-position)*scale});
    return available>=18 ? (float)available : 0.f;
}

inline float programChangeHeadWidth(const jaras::Song &song, double position, float naturalWidth, double scale) {
    double end=std::numeric_limits<double>::infinity();
    for(const auto &part:song.parts)
        if(!part.parentRegionID && part.startTime<=position && position<part.endTime)
            end=std::min(end,part.endTime);
    return markerHeadWidth(position,std::numeric_limits<double>::infinity(),end,naturalWidth,scale);
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
