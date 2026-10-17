#pragma once
#include "Common.h"
namespace catlive {
// Mirrors TimelinePlaybackFollowPolicy.swift, including SubPlay handoffs and
// backward jumps. Only the presentation scrolls; the transport is never changed.
struct TimelinePlaybackFollowPolicy {
    std::optional<double> previousPosition;
    String previousSource;
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
