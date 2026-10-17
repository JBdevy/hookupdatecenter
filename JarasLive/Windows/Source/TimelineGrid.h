#pragma once
#include "Common.h"
#include "TimelineMovementLock.h"
namespace catlive::timelineGrid {
// Mac stores a zoom factor from .001 to 8192, at ten points per second.
inline constexpr double minimumZoom = .01, maximumZoom = 81920.;
struct Section { double start, end, bpm; int beats, unit; };
struct Tick { double time; bool primary; String label; };
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
// ClickTrackProgram.visibleBeats: bounded by the visible pixels, preserving tempo origin.
inline std::vector<double> clickBeats(const jaras::Song &song,const jaras::AudioClip &clip,double from,double to,double scale) {
    std::vector<double> result;if(!std::isfinite(scale)||scale<=0)return result;
    for(const auto &section:sections(song,std::max(song.duration,to))) {
        const double first=std::max({clip.startTime,from,section.start}),last=std::min({clip.startTime+clip.duration,to,section.end});
        if(first>=last || section.bpm<=0 || section.unit<=0)continue;
        const double beat=60./section.bpm*4/section.unit,step=std::max(1.,std::ceil(1/(beat*scale)));
        double index=std::ceil(std::max(0.,std::ceil((first-section.start)/beat-1e-9))/step)*step;
        for(;section.start+index*beat<last-1e-9;index+=step)result.push_back(section.start+index*beat);
    }
    return result;
}
// Match TimelineTempo.snap: visible divisions plus region/marker/cursor anchors.
inline double snap(double time, const jaras::Song &song, double scale, bool free,
                   bool includeHiddenDivisions, const jaras::TransportState *transport = nullptr, bool includeItemEdges = false) {
    if (!std::isfinite(time) || !std::isfinite(scale) || scale <= 0) return 0;
    const double position=std::max(0.,time);
    if (free || !std::isfinite(scale) || scale<=0) return position;
    auto map=sections(song,std::max(song.duration,position)+1);
    Section active{0,song.duration,song.bpm,song.beatsPerBar,song.beatUnit};
    for(const auto &section:map) if(section.start<=position && position<section.end) {active=section;break;}
    const double bar=60./active.bpm*active.beats*4/active.unit;
    const int divisions=song.timeSettings?song.timeSettings->divisions:4;
    double step=0;
    if(divisions>0 && bar>0) {
        if(includeHiddenDivisions) step=bar/active.beats*active.unit/divisions;
        else if(bar*scale>=64) {step=bar/active.beats*active.unit/divisions;step*=std::pow(2.,std::max(0.,std::ceil(std::log2(16/std::max(.001,step*scale)))));}
        else step=bar*std::pow(2.,std::max(0.,std::ceil(std::log2(16/std::max(.001,bar*scale)))));
    }
    double nearest=0,distance=position;
    auto consider=[&](double anchor) {if(!std::isfinite(anchor)||anchor<0)return;const auto d=std::abs(anchor-position);if(d<distance||(d==distance&&anchor<nearest)){nearest=anchor;distance=d;}};
    if(step>0)consider(std::min(active.end,active.start+std::round((position-active.start)/step)*step));
    for(const auto &part:song.parts){consider(part.startTime);consider(part.endTime);}
    if(song.markers)for(const auto &marker:*song.markers)consider(marker.position);
    if(includeItemEdges) for(const auto &track:song.tracks) for(const auto &clip:track.clips) {
        consider(clip.startTime);consider(clip.startTime+clip.duration);
    }
    if(transport) {
        consider(transport->editPosition);consider(transport->position);
        if(transport->subPlay.playing)consider(transport->subPlay.position);
    }
    return nearest;
}
inline double snapSelection(double time, const jaras::Song &song, double scale,
                            const jaras::TransportState &transport, bool free) {
    return snap(time,song,scale,free,false,&transport);
}
inline double snapCursor(double time, const jaras::Song &song, double scale, bool free) {
    return snap(time,song,scale,free,true,nullptr,true);
}
inline String label(double time) {
    const auto ms = (int64)std::llround(time * 1000);
    auto value = clockText(ms / 1000., true);
    if (ms % 1000) value += "." + String(ms % 1000).paddedLeft('0', 3);
    return value;
}
// Shared geometry with TimelineTimeRuler.swift: the ruler and grid restart at
// tempo/meter markers, retain subdivisions, and thin at fixed pixel density.
inline std::vector<Tick> ticks(const jaras::Song &song, double start, double end, double scale) {
    std::vector<Tick> result;
    if (!std::isfinite(start) || !std::isfinite(end) || !std::isfinite(scale) || scale <= 0 || end < start) return result;
    const auto parts = sections(song, std::max(song.duration, end));
    const int divisions = song.timeSettings ? song.timeSettings->divisions : 4;
    const double spacing = 130 + 50 * jlimit(0., 1., -std::log10(scale));
    const double labelSeconds = spacing / scale, columnSeconds = 8 / scale;
    const double densityStart = std::floor(std::max(0., start) / columnSeconds) * columnSeconds;
    double previousLabel = -std::numeric_limits<double>::infinity();
    double lastColumn = -std::numeric_limits<double>::infinity();
    for (const auto &section : parts) {
        if (section.start > end) break;
        if (section.end <= (lastColumn + 1) * columnSeconds) continue;
        const double bar = 60 / section.bpm * section.beats * 4 / section.unit;
        if (!std::isfinite(bar) || bar <= 0 || section.end <= section.start) continue;
        const double stride = std::pow(2., std::max(0., std::ceil(std::log2(16 / std::max(.001, bar * scale)))));
        const double first = std::max(0., std::floor(std::floor((densityStart - section.start) / bar) / stride) * stride);
        const double last = std::max(first, std::ceil((std::min(section.end, end) - section.start) / bar));
        const bool distant = bar * scale < 64;
        const double step = bar / section.beats * section.unit / (divisions == 0 ? 4 : divisions);
        const double minor = distant ? bar * stride / 2 : step * std::pow(2., std::max(0., std::ceil(std::log2(16 / std::max(.001, step * scale)))));
        if (!std::isfinite(minor) || minor <= 0) continue;
        const double labelBars = std::max(stride, std::pow(2., std::max(0., std::ceil(std::log2(spacing / (bar * scale))))));
        const double labelMinor = std::max(1., std::ceil(spacing / (minor * scale)));
        const double firstAllowed = previousLabel + labelSeconds;
        const double lastBar = std::max(0., std::ceil((section.end - section.start) / bar) - 1);
        double lastCandidate = section.start + std::floor(lastBar / labelBars) * labelBars * bar;
        if (!distant) {
            const double labelStep = minor * labelMinor;
            for (double i = lastBar; i >= std::max(0., lastBar - 1); --i) {
                const double origin = section.start + i * bar;
                const double available = std::min(bar - labelSeconds, std::nextafter(section.end - origin, 0.));
                if (available >= labelStep) lastCandidate = std::max(lastCandidate, origin + std::floor(available / labelStep) * labelStep);
            }
        }
        if (lastCandidate >= firstAllowed) previousLabel = lastCandidate;
        if (section.end <= densityStart) continue;
        const auto append = [&](double time, bool primary, bool labeled) {
            if (time < densityStart || time > end || time >= section.end) return;
            const double column = std::floor(time / columnSeconds + 1e-9);
            if (column == lastColumn) return;
            lastColumn = column;
            if (time < std::max(0., start)) return;
            result.push_back({time, primary, labeled && time >= firstAllowed ? label(time) : String()});
        };
        for (double i = first; i <= last; i += stride) {
            const double time = section.start + i * bar;
            if (time >= section.end) break;
            append(time, true, std::fmod(i, labelBars) == 0);
            if (distant) append(time + minor, false, false);
            else for (int sub = 1; sub * minor < std::min(bar, section.end - time) - 1e-9; ++sub)
                append(time + sub * minor, false, std::fmod(sub, labelMinor) == 0 && (bar - sub * minor) * scale >= spacing);
        }
    }
    return result;
}
}
