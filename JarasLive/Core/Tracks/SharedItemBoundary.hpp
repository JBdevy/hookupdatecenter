#pragma once
#include "ItemResize.hpp"
#include <utility>
namespace jaras {
inline std::optional<std::pair<AudioClip, AudioClip>> sharedItemBoundary(
    const AudioClip &left, const AudioClip &right, double position,
    std::optional<double> leftSource = {}, std::optional<double> rightSource = {}) {
    if (!std::isfinite(position) || left.id == right.id ||
        std::abs(left.startTime + left.duration - right.startTime) >= 1e-7 ||
        left.recordingLane.value_or(0) != right.recordingLane.value_or(0)) return {};
    // Keep the 10 ms interval representable after subtracting a large timeline
    // position; rounding below .01 would make resizedItemSource reject one half.
    double lower = std::nextafter(left.startTime + .01, INFINITY);
    double upper = std::nextafter(right.startTime + right.duration - .01, -INFINITY);
    if (right.audioFile && !right.midi && !right.loopLength && !rightSource)
        lower = std::max(lower, right.startTime - right.sourceOffset / right.playbackRate);
    if (lower > upper) return {};
    const double boundary = std::clamp(position, lower, upper);
    auto a = resizedItemSource(left, left.startTime, boundary, leftSource);
    auto b = resizedItemSource(right, boundary, right.startTime + right.duration, rightSource);
    if (std::abs(a.startTime + a.duration - b.startTime) >= 1e-7) return {};
    return std::pair<AudioClip, AudioClip>{std::move(a), std::move(b)};
}
}
