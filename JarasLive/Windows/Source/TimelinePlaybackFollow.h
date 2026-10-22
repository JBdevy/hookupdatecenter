#pragma once
#include "Common.h"
namespace catlive {
inline double timelineZoomPosition(const jaras::TransportState &state) {
    const double position = state.subPlay.playing ? state.subPlay.position
                          : state.playing ? state.position : state.editPosition;
    return std::isfinite(position) ? std::max(0., position) : 0.;
}
inline double timelineCenteredZoomOffset(double position, double scale, double contentWidth, double viewportWidth) {
    return jlimit(0., std::max(0., contentWidth - viewportWidth), position * scale - viewportWidth / 2);
}
// Mirrors TimelinePlaybackFollowPolicy.swift, including SubPlay handoffs and
// backward jumps. Only the presentation scrolls; the transport is never changed.
struct TimelinePlaybackFollowPolicy {
    std::optional<double> previousPosition;
    String previousSource;
    std::optional<jaras::TransportState> manualPause;
    void pause(const jaras::TransportState &state) { manualPause=state;reset(); }
    bool isPaused(const jaras::TransportState &state) {
        if(!manualPause)return false;
        const auto &before=*manualPause;
        if(before.playing!=state.playing || before.subPlay.playing!=state.subPlay.playing || before.songId!=state.songId ||
           (state.playing && before.regionId!=state.regionId) ||
           (state.subPlay.playing && before.subPlaybackStartRegionId!=state.subPlaybackStartRegionId))manualPause.reset();
        return manualPause.has_value();
    }
    void reset() {
        previousPosition.reset();
        previousSource.clear();
    }
    std::optional<double> destination(std::optional<double> position, double pixelsPerSecond,
                                      double contentWidth, double origin, double width,
                                      const String &source, double backingScale) {
        if (!position) {
            reset();
            return {};
        }
        if (!std::isfinite(*position) || !std::isfinite(pixelsPerSecond) || pixelsPerSecond <= 0 ||
            !std::isfinite(contentWidth) || contentWidth <= 0 || !std::isfinite(origin) ||
            !std::isfinite(width) || width <= 0)
            return {};
        const auto x = std::max(0., *position) * pixelsPerSecond;
        if (!std::isfinite(x))
            return {};
        const bool changed = previousPosition && previousSource != source;
        const bool backward = previousPosition && *position < *previousPosition - .000001;
        previousPosition = position;
        previousSource = source;
        if (!changed && !backward && x >= origin && x <= origin + width / 2)
            return {};
        const auto limit = std::max(0., contentWidth - width);
        auto next = jlimit(0., limit, x - width / 2);
        if (std::isfinite(backingScale) && backingScale > 0)
            next = jlimit(0., limit, std::round(next * backingScale) / backingScale);
        return std::abs(next - origin) > .0000001 ? std::optional<double>{next} : std::nullopt;
    }
};
} // namespace catlive
