#pragma once
#include "../../Core/Songs/Song.hpp"
#include "../../Core/Transport/TransportState.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>
#include <set>

// Pure timeline calculations shared by the native input and its portable tests.
namespace catlive::timelineGrid {
using jaras::ID;
struct Section { double start, end, bpm; int beats, unit; };
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
// Match TimelineTempo.snap: visible divisions plus region/marker/cursor anchors.
inline double snap(double time, const jaras::Song &song, double scale, bool free,
                   bool includeHiddenDivisions, const jaras::TransportState *transport = nullptr, bool includeItemEdges = false, const std::set<ID> *excludedItems = nullptr, const ID *excludedRegion = nullptr, const ID *excludedMarker = nullptr,
                   const std::vector<std::pair<ID,double>> *itemEdges = nullptr,
                   std::optional<double> maximumDistancePixels = {}) {
    if (!std::isfinite(time) || !std::isfinite(scale) || scale <= 0) return 0;
    const double position=std::max(0.,time);
    if (free || !std::isfinite(scale) || scale<=0) return position;
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
    auto map=sections(song,std::max(song.duration,position)+1);
    Section active{0,song.duration,song.bpm,song.beatsPerBar,song.beatUnit};
    for(const auto &section:map) if(section.start<=position && position<section.end) {active=section;break;}
    const double bar=60./active.bpm*active.beats*4/active.unit;
    const int divisions=song.timeSettings?song.timeSettings->divisions:4;
    double step=0;
    if(divisions>0 && bar>0) {
        if(includeHiddenDivisions) step=bar/active.beats*active.unit/divisions;
        else if(bar*scale>=64) {step=bar/active.beats*active.unit/divisions;step*=std::pow(2.,std::max(0.,std::ceil(std::log2(16/std::max(.001,step*scale)))));}
        else step=bar*std::pow(2.,std::max(0.,std::ceil(std::log2(16/std::max(.001,bar*scale)))))/2;
    }
    double nearest=0,distance=position;
    auto consider=[&](double anchor) {if(!std::isfinite(anchor)||anchor<0)return;const auto d=std::abs(anchor-position);if(d<distance||(d==distance&&anchor<nearest)){nearest=anchor;distance=d;}};
    if(step>0)consider(std::min(active.end,active.start+std::round((position-active.start)/step)*step));
    for(const auto &part:song.parts) if(!excludedRegion || part.id!=*excludedRegion){consider(part.startTime);consider(part.endTime);}
    if(song.markers)for(const auto &marker:*song.markers)if(!excludedMarker || marker.id!=*excludedMarker)consider(marker.position);
    if(includeItemEdges) visitNearbyItemEdges(distance,consider);
    if(transport) {
        consider(transport->editPosition);consider(transport->position);
        if(transport->subPlay.playing)consider(transport->subPlay.position);
    }
    // Do not reconsider an out-of-range edge/cursor without the capture
    // radius: that used to pull a released item back to its original start.
    return distance*scale<=maximumDistance+1e-9 ? nearest : position;
}
inline double snapSelection(double time, const jaras::Song &song, double scale,
                            const jaras::TransportState &transport, bool free, const std::set<ID> *excludedItems = nullptr,
                            const std::vector<std::pair<ID,double>> *itemEdges = nullptr) {
    return snap(time,song,scale,free,false,&transport,true,excludedItems,nullptr,nullptr,itemEdges,8.);
}
inline double snapCursor(double time, const jaras::Song &song, double scale, bool free) {
    return snap(time,song,scale,free,true,nullptr,true);
}
}
