#pragma once
#include "Common.h"
#include <set>
#include <limits>
#include <queue>
#include <tuple>
#include "../../Core/Songs/TempoPlaybackRate.hpp"
#include "TimelineMovementLock.h"
#include "TimelineSnapping.h"
namespace catlive::timelineGrid {
inline constexpr int verticalScrollbarWidth = 14;
inline constexpr double maximumVisibleDuration = 45. * 60 * 60, maximumZoom = 81920.;
// Points/second: the complete grid viewport can display 45 hours at any size.
inline double minimumZoom(double viewportWidth) {
    return std::max(1., viewportWidth) / maximumVisibleDuration;
}
inline double scrollEnd(const jaras::Song* song) {
    constexpr double trailingMargin = 60. * 60 * 60;
    double end = 0;
    if (song) {
        for (const auto& region : song->parts)
            if (std::isfinite(region.endTime)) end = std::max(end, region.endTime);
        for (const auto& track : song->tracks)
            for (const auto& item : track.clips) {
                const double itemEnd = item.startTime + item.duration;
                if (std::isfinite(itemEnd)) end = std::max(end, itemEnd);
            }
    }
    return end + trailingMargin;
}
struct Tick { double time; bool primary; String label; bool drawsInGrid; };

// Like Song.tempoSections on Mac, the ruler also starts a new section when
// a region-owned marker expires, restoring the preceding active tempo.
inline std::vector<Section> rulerSections(const jaras::Song& song, double end) {
    if (!std::isfinite(end) || end <= 0) return {};
    struct MarkerSpan { const jaras::TimelineMarker* marker; double end; };
    std::vector<MarkerSpan> markers;
    std::vector<double> boundaries{0, end};
    if (song.markers) for (const auto& marker : *song.markers) {
        if (!marker.tempoBPM || !std::isfinite(*marker.tempoBPM) || *marker.tempoBPM <= 0 ||
            !std::isfinite(marker.position) || marker.position < 0 || marker.position >= end) continue;
        const auto limit = jaras::tempoPlayback::markerEnd(song, marker);
        markers.push_back({&marker, limit});
        boundaries.push_back(marker.position);
        if (limit > 0 && limit < end) boundaries.push_back(limit);
    }
    std::sort(markers.begin(), markers.end(), [](const auto& lhs, const auto& rhs) {
        return std::tie(lhs.marker->position, lhs.marker->id) < std::tie(rhs.marker->position, rhs.marker->id);
    });
    std::sort(boundaries.begin(), boundaries.end());
    boundaries.erase(std::unique(boundaries.begin(), boundaries.end()), boundaries.end());
    std::priority_queue<size_t> active;
    size_t nextMarker = 0;
    std::vector<Section> result;
    result.reserve(boundaries.size() - 1);
    for (size_t index = 0; index + 1 < boundaries.size(); ++index) {
        const double start = boundaries[index], stop = boundaries[index + 1];
        while (nextMarker < markers.size() && markers[nextMarker].marker->position <= start) active.push(nextMarker++);
        while (!active.empty() && markers[active.top()].end <= start) active.pop();
        const auto* marker = active.empty() ? nullptr : markers[active.top()].marker;
        result.push_back(marker
            ? Section{start, stop, *marker->tempoBPM, marker->tempoBeats.value_or(4), marker->tempoUnit.value_or(4)}
            : Section{start, stop, song.bpm, song.beatsPerBar, song.beatUnit});
    }
    return result;
}
// ClickTrackProgram.visibleBeats: bounded by the visible pixels, preserving tempo origin.
inline std::vector<double> clickBeats(const jaras::Song &song,const jaras::AudioClip &clip,double from,double to,double scale) {
    std::vector<double> result;if(!std::isfinite(scale)||scale<=0)return result;
    for(const auto &section:sections(song,std::max(song.duration,to))) {
        const double first=std::max({clip.startTime,from,section.start}),last=std::min({clip.startTime+clip.duration,to,section.end});
        if(first>=last || section.bpm<=0 || section.unit<=0)continue;
        const double beat=60./section.bpm*4/section.unit/(clip.clickDouble.value_or(false)?2:1)/clip.tempoBasePlaybackRate.value_or(clip.playbackRate),step=std::max(1.,std::ceil(1/(beat*scale)));
        double index=std::ceil(std::max(0.,std::ceil((first-section.start)/beat-1e-9))/step)*step;
        for(;section.start+index*beat<last-1e-9;index+=step)result.push_back(section.start+index*beat);
    }
    return result;
}
inline String label(double time) {
    const auto ms = (int64)std::llround(time * 1000);
    auto value = clockText(ms / 1000., true);
    if (ms % 1000) value += "." + String(ms % 1000).paddedLeft('0', 3);
    return value;
}
// Shared geometry with TimelineTimeRuler.swift: the ruler and grid restart at
// tempo/meter markers, retain subdivisions, and thin at fixed pixel density.
inline std::vector<Tick> ticks(const std::vector<Section>& parts, int divisions,
                               double start, double end, double scale, bool musical) {
    std::vector<Tick> result;
    if (!std::isfinite(start) || !std::isfinite(end) || !std::isfinite(scale) || scale <= 0 || end < start) return result;
    std::optional<MeasureLabels> measures;
    if (musical) measures.emplace(parts);
    const double spacing = measures ? measures->spacing : 130 + 50 * jlimit(0., 1., -std::log10(scale));
    constexpr double barLineSpacing = 6., beatLineSpacing = 32., rulerTickSpacing = 5.;
    const double labelSeconds = spacing / scale, columnSeconds = (musical ? rulerTickSpacing : 8.) / scale;
    const double densityStart = std::floor(std::max(0., start) / columnSeconds) * columnSeconds;
    const double densityEnd = (std::floor(end / columnSeconds) + 1) * columnSeconds;
    double lastColumn = -std::numeric_limits<double>::infinity();
    int lastColumnRank = 0;
    const auto hierarchyStep=[](uint64_t index) { return index & (~index + 1); };
    auto firstSection=std::upper_bound(parts.begin(),parts.end(),densityStart,
        [](double time,const Section &section){return time<section.end;});
    for (auto it=firstSection;it!=parts.end();++it) {
        const auto &section=*it;
        if (section.start > densityEnd) break;
        const size_t sectionIndex=(size_t)(it-parts.begin());
        const double bar = section.barSeconds();
        if (!std::isfinite(bar) || bar <= 0 || section.end <= section.start) continue;
        const double boundaryEnd=sectionIndex+1<parts.size()?section.end:std::numeric_limits<double>::infinity();
        const double stride = std::pow(2., std::max(0., std::ceil(std::log2((musical ? barLineSpacing : 8.) / std::max(.001, bar * scale)))));
        const double first = std::max(0., std::floor(std::floor((densityStart - section.start) / bar) / stride) * stride);
        const double last = std::max(first, std::ceil((std::min(section.end, densityEnd) - section.start) / bar));
        const double beat = bar / section.beats;
        const double base = std::min(beat, beat * section.unit / (divisions == 0 ? 4 : divisions));
        const double minor = musical
            ? base * std::pow(2., std::max(0., std::ceil(std::log2(rulerTickSpacing / std::max(.001, base * scale)))))
            : visibleGridStep(bar,section.beats,section.unit,divisions==0?4:divisions,scale);
        if (!std::isfinite(base) || base<=0 || !std::isfinite(minor) || minor <= 0) continue;
        const auto divisionsPerBeat = std::max(1, (int)std::llround(beat / base));
        double boundaryClearance=std::numeric_limits<double>::infinity();
        if(sectionIndex>0) {
            const auto step=(size_t)hierarchyStep(sectionIndex);
            const double left=parts[sectionIndex-step].start;
            const double right=sectionIndex+step<parts.size()?parts[sectionIndex+step].start:std::numeric_limits<double>::infinity();
            boundaryClearance=std::min(section.start-left,right-section.start);
        }
        // Fixed higher-priority neighbours make visibility monotonic with zoom,
        // including at tempo boundaries. Match the Mac/iPad ruler hierarchy.
        const auto append = [&](double time, int64_t bar, int64_t subdivision, double clearance) {
            if (time < densityStart || time > densityEnd || time >= section.end) return;
            const bool labeled=clearance+1e-9>=labelSeconds;
            const bool primary = subdivision == 0;
            const double room = clearance * scale + 1e-9;
            const bool drawsInGrid = musical
                ? room >= barLineSpacing && (primary || (subdivision % divisionsPerBeat == 0 && beat * scale >= beatLineSpacing))
                : primary && room >= 24.;
            const int rank = labeled ? 3 : !musical ? 0 : drawsInGrid ? 2 : primary ? 1 : 0;
            const double column = std::floor(time / columnSeconds + 1e-9);
            if (column == lastColumn) {
                if (rank <= lastColumnRank) return;
                result.pop_back();
            }
            lastColumn = column; lastColumnRank = rank;
            const auto title = labeled ? (measures ? text(measures->label(sectionIndex, bar, subdivision, divisionsPerBeat)) : label(time)) : String();
            result.push_back({time, primary, title, drawsInGrid});
        };
        for (double i = first; i <= last; i += stride) {
            const double time = section.start + i * bar;
            if (time >= section.end) break;
            const double clearance=i==0?boundaryClearance:
                std::min((double)hierarchyStep((uint64_t)i)*bar,boundaryEnd-time);
            append(time, (int64_t)i, 0, clearance);
            if (minor < bar) for (int sub = 1; sub * minor < std::min(bar, section.end - time) - 1e-9; ++sub) {
                const double offset=sub*minor;
                const auto index=(uint64_t)std::max<int64>(1,(int64)std::llround(offset/base));
                append(time+offset,(int64_t)i,(int64_t)index,std::min({(double)hierarchyStep(index)*base,bar-offset,boundaryEnd-time-offset}));
            }
        }
    }
    result.erase(std::remove_if(result.begin(),result.end(),[&](const auto &tick){return tick.time<std::max(0.,start)||tick.time>end;}),result.end());
    return result;
}
inline std::vector<Tick> ticks(const jaras::Song &song, double start, double end, double scale, bool musical = false) {
    const auto parts = musical ? rulerSections(song, std::max(scrollEnd(&song), end))
                               : sections(song, std::max(song.duration, end));
    return ticks(parts, song.timeSettings ? song.timeSettings->divisions : 4, start, end, scale, musical);
}
}
