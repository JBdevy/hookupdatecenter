#pragma once
#include "Common.h"

namespace catlive::markerEditing {
inline bool isSection(const jaras::TimelineMarker &marker) {
    return marker.section.value_or(false) && !marker.tempoBPM;
}
inline String editorName(const jaras::TimelineMarker &marker) {
    return String(isSection(marker) ? (marker.loopSection.value_or(false) ? "*" : "$") : "") + text(marker.name);
}
inline void applyPrefix(jaras::TimelineMarker &marker) {
    if (marker.tempoBPM) return;
    const auto raw = text(marker.name).trim();
    if (!raw.startsWithChar('$') && !raw.startsWithChar('*')) return;
    marker.section = true;
    marker.loopSection = raw.startsWithChar('*');
    const bool slot = raw.startsWithChar('*') && raw.length() > 1 && raw[1] >= '1' && raw[1] <= '4';
    marker.name = utf8(raw.substring(slot ? 2 : 1).trim());
}
inline bool canCreateSection(const jaras::Song &song, double position, bool includingEnd = false) {
    return std::any_of(song.parts.begin(), song.parts.end(), [&](const auto &part) {
        return position >= part.startTime && (position < part.endTime || (includingEnd && position == part.endTime));
    });
}
// Mirrors ShowController.setMarker: the displayed prefix selects a type, while
// the document stores its clean name and the section/loop flags separately.
inline jaras::TimelineMarker prepare(const jaras::Song &song, jaras::TimelineMarker marker) {
    const jaras::TimelineMarker *previous = nullptr;
    if (song.markers)
        for (const auto &candidate : *song.markers)
            if (candidate.id == marker.id) { previous = &candidate; break; }
    applyPrefix(marker);
    if (previous && isSection(*previous) && previous->loopSection.value_or(false) &&
        !(isSection(marker) && marker.loopSection.value_or(false)))
        for (const auto &part : song.parts)
            for (const auto &loop : part.multiLoops)
                if (loop.marker1 == marker.id || loop.marker2 == marker.id)
                    throw std::runtime_error("Remova este marcador dos Multiloops antes de mudar seu tipo.");
    if (isSection(marker) && !canCreateSection(song, marker.position, previous != nullptr))
        throw std::runtime_error("Marcadores de trecho só podem ser criados dentro de uma música.");
    if (!previous && song.markers)
        for (const auto &candidate : *song.markers)
            if (candidate.tempoBPM.has_value() == marker.tempoBPM.has_value() &&
                std::abs(candidate.position - marker.position) < .000001)
                throw std::runtime_error("Já existe um marcador nesta posição.");
    if (previous) {
        marker.unifiedRegionID = previous->unifiedRegionID;
        marker.sourceRegionID = previous->sourceRegionID;
        marker.tempoReferenceBPM = marker.tempoBPM ? previous->tempoReferenceBPM : std::nullopt;
    }
    auto name = text(marker.name).trim();
    if (isSection(marker)) name = unicodeCase(name).substring(0, 256);
    else if (!marker.unifiedRegionID) name = name.substring(0, 256);
    if (name.isEmpty()) throw std::runtime_error("Informe o nome do marcador.");
    marker.name = utf8(name);
    marker.regionOwnerID = previous && previous->position == marker.position
        ? previous->regionOwnerID : jaras::regionOwnerAt(song, marker.position);
    return marker;
}
} // namespace catlive::markerEditing
