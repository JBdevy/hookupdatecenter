#pragma once
#include "Common.h"
#include <set>
#include <limits>
#include "TimelineMovementLock.h"
#include "TimelineSnapping.h"
#include "TimelineScale.h"
namespace catlive::timelineGrid {
inline constexpr int verticalScrollbarWidth = 14;
inline constexpr double maximumVisibleDuration = 45. * 60 * 60, maximumZoom = 81920.;
inline double minimumZoom(double viewportWidth) {
    return std::max(minimumPointsPerSecond, viewportWidth / maximumVisibleDuration);
}
struct Tick { double time; bool primary; String label; bool drawsInGrid; };

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
inline std::vector<Tick> ticks(const std::vector<Section>& parts, int divisions,
                               double start, double end, double scale, bool musical) {
    const auto ruler = rulerTicks(parts, divisions, start, end, scale, musical);
    std::vector<Tick> result;
    result.reserve(ruler.size());
    for (const auto& mark : ruler) {
        const String title = !mark.labeled ? String{} : musical ? text(mark.musicalLabel) : label(mark.time);
        result.push_back({mark.time, mark.primary, title, mark.drawsInGrid});
    }
    return result;
}
inline std::vector<Tick> ticks(const jaras::Song &song, double start, double end, double scale, bool musical = false) {
    const auto parts = musical ? rulerSections(song, std::max(scrollEnd(&song), end))
                               : sections(song, std::max(song.duration, end));
    return ticks(parts, song.timeSettings ? song.timeSettings->divisions : 4, start, end, scale, musical);
}
}
