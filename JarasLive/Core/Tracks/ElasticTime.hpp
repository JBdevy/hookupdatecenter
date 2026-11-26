#pragma once
#include "Track.hpp"
#include <algorithm>
#include <cmath>

namespace jaras::elastic {
inline constexpr size_t maxPoints = 256;
inline constexpr double minimumGap = 0.000001;

inline bool valid(const std::vector<ElasticPoint> &points) {
    if (points.size() > maxPoints) return false;
    double position = 0, source = 0;
    for (const auto &point : points) {
        if (!std::isfinite(point.position) || !std::isfinite(point.source) ||
            !std::isfinite(point.slopeBefore) || !std::isfinite(point.slopeAfter) ||
            std::abs(point.slopeBefore) >= 1 || std::abs(point.slopeAfter) >= 1 ||
            point.position < position + minimumGap || point.source < source + minimumGap ||
            point.position > 1 - minimumGap || point.source > 1 - minimumGap) return false;
        position = point.position;
        source = point.source;
    }
    return true;
}

struct Speed {
    double start, end;
    double at(double fraction) const { return start + (end - start) * fraction; }
};
inline double slope(const std::vector<ElasticPoint> &points, size_t span) {
    return points.empty() ? 0 : span == 0 ? points.front().slopeBefore : points[span - 1].slopeAfter;
}
inline Speed speed(const std::vector<ElasticPoint> &points, size_t span, double reference = 1) {
    const auto left = span == 0 ? ElasticPoint{0, 0} : points[span - 1];
    const auto next = span == points.size() ? ElasticPoint{1, 1} : points[span];
    const auto mean = reference * (next.source - left.source) / (next.position - left.position);
    const auto shape = slope(points, span);
    return {mean * (1 - shape), mean * (1 + shape)};
}
inline double laneOffset(double rate, double height) {
    return -std::tanh(std::log2(std::max(.01, rate))) * std::max(0., height / 2 - 6);
}
inline void setSlope(std::vector<ElasticPoint> &points, size_t span, double value) {
    (span == 0 ? points.front().slopeBefore : points[span - 1].slopeAfter) = std::abs(value) < 1e-12 ? 0 : value;
}
inline double adjustRate(std::vector<ElasticPoint> &points, size_t index, bool right, double down,
                         bool preservePositions, bool reset, double reference) {
    if (index >= points.size() || !std::isfinite(down) || !std::isfinite(reference) || reference <= 0) return 1;
    const auto span = right ? index + 1 : index;
    const auto begin = span == 0 ? 0 : points[span - 1].position;
    const auto end = span == points.size() ? 1 : points[span].position;
    auto rates = speed(points, span, reference);
    const auto sum = rates.start + rates.end, old = right ? rates.start : rates.end;
    const auto steps = std::trunc(down / 2);
    if (!reset && steps == 0) return 1;
    const auto lower = std::min(.01, sum / 4);
    const auto target = reset ? 1 : std::max(lower, (std::round(old * 100) - steps) / 100);
    const auto adjustedRate = preservePositions ? std::min(sum - lower, target) : target;
    (right ? rates.start : rates.end) = adjustedRate;
    if (preservePositions) (right ? rates.end : rates.start) = sum - adjustedRate;
    const auto total = rates.start + rates.end;
    const auto delta = preservePositions ? 0 : (end - begin) * (sum / total - 1);
    const auto ratio = 1 + delta;
    auto changed = points;
    if (delta != 0) for (size_t i = 0; i < changed.size(); ++i)
        changed[i].position = (points[i].position + (i >= span ? delta : 0)) / ratio;
    setSlope(changed, span, (rates.end - rates.start) / total);
    if (!valid(changed)) return 1;
    points.swap(changed);
    return ratio;
}
template <typename Span>
void apply(std::vector<Span> &spans, const std::vector<ElasticPoint> &points, double sourceScale = 1) {
    if (points.empty() || spans.empty() || !valid(points)) return;
    const auto first = spans.front().start, last = spans.back().end;
    const auto sourceStart = spans.front().source;
    const auto sourceLength = (spans.back().source + (last - spans.back().start) * spans.back().rate - sourceStart) * sourceScale;
    if (sourceLength <= 0 || last <= first) return;
    std::vector<Span> result;
    result.reserve(spans.size() + points.size());
    size_t index = 0;
    double start = first, fromSource = sourceStart, baseStart = sourceStart;
    for (size_t point = 0; point <= points.size(); ++point) {
        const auto anchor = point < points.size() ? points[point] : ElasticPoint{1, 1};
        const double end = first + anchor.position * (last - first);
        const double toSource = sourceStart + anchor.source * sourceLength;
        auto endIndex = index;
        while (endIndex + 1 < spans.size() && spans[endIndex].end < end) ++endIndex;
        const auto &tail = spans[endIndex];
        const double baseEnd = tail.source + (end - tail.start) * tail.rate;
        if (slope(points, point) != 0) {
            const auto rates = speed(points, point, sourceLength / (last - first));
            const int slices = int(std::clamp(std::ceil(std::abs(rates.end - rates.start) * 100), 1., 256.));
            double source = fromSource;
            for (int slice = 0; slice < slices; ++slice) {
                const auto a = double(slice) / slices, b = double(slice + 1) / slices;
                const double from = start + (end - start) * a, to = slice + 1 == slices ? end : start + (end - start) * b;
                const double rate = rates.at((a + b) / 2);
                result.push_back({from, to, source, rate});
                source += (to - from) * rate;
            }
            index = endIndex;
            if (index + 1 < spans.size() && spans[index].end <= end) ++index;
            start = end;
            fromSource = toSource;
            baseStart = baseEnd;
            continue;
        }
        const double factor = (toSource - fromSource) / (baseEnd - baseStart);
        if (!std::isfinite(factor) || factor <= 0) return;
        double position = start, source = fromSource;
        while (index < spans.size() && position < end) {
            const auto &span = spans[index];
            const auto finish = std::min(end, span.end);
            const auto rate = span.rate * factor;
            if (finish > position) {
                result.push_back({position, finish, source, rate});
                source += (finish - position) * rate;
                position = finish;
            }
            if (finish >= span.end) ++index;
            else break;
        }
        start = end;
        fromSource = toSource;
        baseStart = baseEnd;
    }
    spans.swap(result);
}

inline bool insert(std::vector<ElasticPoint> &points, ElasticPoint point) {
    const auto at = std::lower_bound(points.begin(), points.end(), point.position,
        [](const auto &p, double value) { return p.position < value; });
    auto replacement = points;
    const auto span = static_cast<size_t>(at - points.begin());
    const auto before = span == 0 ? 0 : points[span - 1].position;
    const auto after = span == points.size() ? 1 : points[span].position;
    const auto rates = speed(points, span);
    const auto u = (point.position - before) / (after - before);
    const auto middle = rates.at(u);
    // The playback engine approximates ramps with constant-rate blocks. Insert
    // at the exact integral so splitting a ramp preserves its timing.
    if (slope(points, span) != 0) {
        const auto source = span == 0 ? 0 : points[span - 1].source;
        point.source = source + (point.position - before) * (rates.start + middle) / 2;
    }
    if (span == 0 && !replacement.empty()) replacement.front().slopeBefore = 0;
    replacement.insert(replacement.begin() + span, point);
    if (!valid(replacement)) return false;
    setSlope(replacement, span, (middle - rates.start) / (middle + rates.start));
    setSlope(replacement, span + 1, (rates.end - middle) / (rates.end + middle));
    points.swap(replacement);
    return true;
}

inline double restrain(const std::vector<ElasticPoint> &points, size_t index, double position) {
    const auto left = index > 0 ? points[index - 1] : ElasticPoint{0, 0};
    const auto right = index + 1 < points.size() ? points[index + 1] : ElasticPoint{1, 1};
    const auto source = points[index].source;
    // Keep the stretch factor bounded while preserving the order of anchors.
    const auto gap = minimumGap * 2;
    const auto lower = left.position + std::max(gap, (source - left.source) / 8);
    const auto upper = right.position - std::max(gap, (right.source - source) / 8);
    return lower <= upper ? std::clamp(position, lower, upper) : points[index].position;
}
}
