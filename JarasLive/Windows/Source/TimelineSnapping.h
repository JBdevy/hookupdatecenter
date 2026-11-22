#pragma once
#include "../../Core/Songs/Song.hpp"
#include "../../Core/Songs/TempoPlaybackRate.hpp"
#include "../../Core/Transport/TransportState.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <queue>
#include <tuple>
#include <utility>
#include <set>

// Pure timeline calculations shared by the native input and its portable tests.
namespace catlive::timelineGrid {
using jaras::ID;
struct Section {
    double start, end, bpm;
    int beats, unit;
    double barSeconds() const { return 60 / bpm * beats * 4 / unit; }
};
struct MeasureLabels {
    explicit MeasureLabels(const std::vector<Section>& sections) {
        int64_t next = 1;
        firstMeasures.reserve(sections.size());
        for (const auto& section : sections) {
            firstMeasures.push_back(next);
            const auto count = (section.end - section.start) / section.barSeconds();
            if (std::isfinite(count) && count > 0) next += std::max<int64_t>(1, (int64_t)std::ceil(count - 1e-9));
        }
        spacing = (std::to_string(next).size() + 5) * 8.5 + 14.0;
    }
    std::string label(size_t section, int64_t bar, int64_t subdivision, int divisionsPerBeat) const {
        auto name = std::to_string(firstMeasures[section] + bar);
        if (subdivision == 0) return name;
        name += "." + std::to_string(subdivision / divisionsPerBeat + 1);
        const auto withinBeat = subdivision % divisionsPerBeat;
        if (withinBeat) name += "." + std::to_string(withinBeat + 1);
        return name;
    }
    double spacing;
private:
    std::vector<int64_t> firstMeasures;
};
inline std::vector<Section> sections(const jaras::Song &song, double end) {
    std::vector<const jaras::TimelineMarker *> markers;
    if (song.markers) for (const auto &m : *song.markers)
        if (m.tempoBPM && std::isfinite(*m.tempoBPM) && *m.tempoBPM > 0 &&
            std::isfinite(m.position) && m.position >= 0 && m.position <= end) markers.push_back(&m);
    std::sort(markers.begin(), markers.end(), [](auto *a, auto *b) {
        return a->position == b->position ? a->id < b->id : a->position < b->position;
    });
    Section active{0, end, song.bpm, song.beatsPerBar, song.beatUnit};
    std::vector<Section> result;
    for (const auto *m : markers) {
        if (m->position > active.start) { active.end = m->position; result.push_back(active); }
        active = {m->position, end, *m->tempoBPM, m->tempoBeats.value_or(4), m->tempoUnit.value_or(4)};
    }
    if (end > active.start) { active.end = end; result.push_back(active); }
    return result;
}
inline double visibleGridStep(double bar, int beats, int unit, int divisions, double scale) {
    if (divisions <= 0 || bar <= 0 || beats <= 0 || scale <= 0) return 0;
    const double beat=bar/beats;
    const double base=std::min(beat,beat*unit/divisions);
    const double step=base*std::pow(2.,std::max(0.,std::ceil(std::log2(16/std::max(.001,base*scale)))));
    return step<bar ? step : bar*std::pow(2.,std::max(0.,std::ceil(std::log2(8/std::max(.001,bar*scale)))));
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
struct RulerTick {
    double time;
    bool primary;
    std::string musicalLabel;
    bool drawsInGrid, labeled;
};

// Shared geometry with TimelineTimeRuler.swift: the ruler and grid restart at
// tempo/meter markers, retain subdivisions, and thin at fixed pixel density.
inline std::vector<RulerTick> rulerTicks(const std::vector<Section>& parts, int divisions,
                               double start, double end, double scale, bool musical, bool formatLabels = true) {
    std::vector<RulerTick> result;
    if (!std::isfinite(start) || !std::isfinite(end) || !std::isfinite(scale) || scale <= 0 || end < start) return result;
    std::optional<MeasureLabels> measures;
    if (musical) measures.emplace(parts);
    const double spacing = measures ? measures->spacing : 130 + 50 * std::clamp(-std::log10(scale), 0., 1.);
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
            const auto title = labeled && formatLabels && measures
                ? measures->label(sectionIndex, bar, subdivision, divisionsPerBeat) : std::string{};
            result.push_back({time, primary, std::move(title), drawsInGrid, labeled});
        };
        for (double i = first; i <= last; i += stride) {
            const double time = section.start + i * bar;
            if (time >= section.end) break;
            const double clearance=i==0?boundaryClearance:
                std::min((double)hierarchyStep((uint64_t)i)*bar,boundaryEnd-time);
            append(time, (int64_t)i, 0, clearance);
            if (minor < bar) for (int sub = 1; sub * minor < std::min(bar, section.end - time) - 1e-9; ++sub) {
                const double offset=sub*minor;
                const auto index=(uint64_t)std::max<int64_t>(1,(int64_t)std::llround(offset/base));
                append(time+offset,(int64_t)i,(int64_t)index,std::min({(double)hierarchyStep(index)*base,bar-offset,boundaryEnd-time-offset}));
            }
        }
    }
    result.erase(std::remove_if(result.begin(),result.end(),[&](const auto &tick){return tick.time<std::max(0.,start)||tick.time>end;}),result.end());
    return result;
}
inline std::optional<double> nearestRulerTick(double position, double scale, int divisions,
                                              const std::vector<Section>& timing) {
    const double radius = 24. / scale;
    auto marks = rulerTicks(timing, divisions, position - radius, position + radius, scale, true, false);
    const auto nearest = std::min_element(marks.begin(), marks.end(), [&](const auto& lhs, const auto& rhs) {
        return std::abs(lhs.time - position) < std::abs(rhs.time - position);
    });
    return nearest == marks.end() ? std::nullopt : std::optional<double>(nearest->time);
}
// Match TimelineTempo.snap: visible divisions plus region/marker/cursor anchors.
inline double snap(double time, const jaras::Song &song, double scale, bool free,
                   const jaras::TransportState *transport = nullptr, bool includeItemEdges = false, const std::set<ID> *excludedItems = nullptr, const ID *excludedRegion = nullptr, const ID *excludedMarker = nullptr,
                   const std::vector<std::pair<ID,double>> *itemEdges = nullptr,
                   std::optional<double> maximumDistancePixels = {}, const std::vector<Section> *timing = nullptr) {
    if (!std::isfinite(time) || !std::isfinite(scale) || scale <= 0) return 0;
    const double position=std::max(0.,time);
    if (free || !std::isfinite(scale) || scale<=0) return position;
    const int divisions = song.timeSettings ? song.timeSettings->divisions : 4;
    std::optional<double> gridAnchor;
    if (divisions > 0) {
        gridAnchor = timing ? nearestRulerTick(position, scale, divisions, *timing)
            : nearestRulerTick(position, scale, divisions, rulerSections(song, scrollEnd(&song)));
        if (gridAnchor && std::abs(*gridAnchor - position) * scale <= .5) return *gridAnchor;
    }
    auto visitNearbyItemEdges = [&](double radius, auto &&visit) {
        if (itemEdges) {
            const double lower = std::max(0., position - radius), upper = position + radius;
            auto at = std::lower_bound(itemEdges->begin(), itemEdges->end(), lower,
                [](const auto &entry, double value) { return entry.second < value; });
            for (; at != itemEdges->end() && at->second <= upper; ++at)
                if (!excludedItems || !excludedItems->count(at->first)) visit(at->second);
            return;
        }
        for (const auto &track : song.tracks) for (const auto &clip : track.clips)
            if (!excludedItems || !excludedItems->count(clip.id)) {
                const double start = clip.startTime, end = clip.startTime + clip.duration;
                if (start >= position - radius && start <= position + radius) visit(start);
                if (end >= position - radius && end <= position + radius) visit(end);
            }
    };
    // Drags have a finite screen-space magnet; cursor clicks still quantize
    // unconditionally unless their caller explicitly requests a radius.
    const double maximumDistance = maximumDistancePixels
        ? (std::isfinite(*maximumDistancePixels) ? std::max(0., *maximumDistancePixels) : 0.)
        : std::numeric_limits<double>::infinity();
    const double strongRadius = std::min(12., maximumDistance);
    double strong=position, strongDistance=std::numeric_limits<double>::infinity();
    auto considerStrong=[&](double anchor){const double distance=std::abs(anchor-position);if(std::isfinite(anchor)&&anchor>=0&&distance*scale<=strongRadius+1e-9&&(distance<strongDistance||(distance==strongDistance&&anchor<strong))){strong=anchor;strongDistance=distance;}};
    if(transport){considerStrong(transport->editPosition);considerStrong(transport->position);if(transport->subPlay.playing)considerStrong(transport->subPlay.position);}
    if(includeItemEdges)visitNearbyItemEdges(strongRadius/scale,considerStrong);
    if(std::isfinite(strongDistance))return strong;
    double nearest=0,distance=position;
    auto consider=[&](double anchor) {if(!std::isfinite(anchor)||anchor<0)return;const auto d=std::abs(anchor-position);if(d<distance||(d==distance&&anchor<nearest)){nearest=anchor;distance=d;}};
    if (gridAnchor) consider(*gridAnchor);
    for(const auto &part:song.parts) if(!excludedRegion || part.id!=*excludedRegion){consider(part.startTime);consider(part.endTime);}
    if(song.markers)for(const auto &marker:*song.markers)if(!excludedMarker || marker.id!=*excludedMarker)consider(marker.position);
    if(includeItemEdges) visitNearbyItemEdges(distance,consider);
    if(transport) {
        consider(transport->editPosition);consider(transport->position);
        if(transport->subPlay.playing)consider(transport->subPlay.position);
    }
    // Do not reconsider an out-of-range edge/cursor without the capture
    // radius: that used to pull a released item back to its original start.
    return gridAnchor || distance*scale<=maximumDistance+1e-9 ? nearest : position;
}
inline double snapSelection(double time, const jaras::Song &song, double scale,
                            const jaras::TransportState &transport, bool free, const std::set<ID> *excludedItems = nullptr,
                            const std::vector<std::pair<ID,double>> *itemEdges = nullptr, const std::vector<Section> *timing = nullptr) {
    return snap(time,song,scale,free,&transport,true,excludedItems,nullptr,nullptr,itemEdges,8.,timing);
}
inline double snapCursor(double time, const jaras::Song &song, double scale, bool free, const std::vector<Section> *timing = nullptr) {
    return snap(time,song,scale,free,nullptr,true,nullptr,nullptr,nullptr,nullptr,{},timing);
}
}
