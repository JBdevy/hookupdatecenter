#include "../../Core/Tracks/ElasticTime.hpp"
#include <cassert>
#include <cmath>
#include <iostream>

namespace {
using jaras::ElasticPoint;
struct Span { double start, end, source, rate; };
bool near(double a, double b) { return std::abs(a - b) < 1e-9; }

void checkPlayback(const std::vector<ElasticPoint>& points, double duration, double scale) {
    std::vector<Span> spans{{2, 2 + duration, 3, 1}};
    jaras::elastic::apply(spans, points, scale);
    double time = 2, source = 3;
    for (const auto& span : spans) {
        assert(near(span.start, time) && near(span.source, source));
        assert(span.end > span.start && span.rate > 0);
        time = span.end;
        source += (span.end - span.start) * span.rate;
    }
    assert(near(time, 2 + duration) && near(source, 11));
}
}

int main() {
    using namespace jaras::elastic;
    for (int count : {1, 2}) {
        for (bool right : {false, true}) {
            std::vector<ElasticPoint> original{{.25, .25}};
            if (count == 2) original.push_back({.625, .625});
            auto points = original;
            auto ratio = adjustRate(points, 0, right, 2, false, false, 1);
            assert(ratio > 1);
            const auto rates = speed(points, right ? 1 : 0, 1 / ratio);
            assert(near(right ? rates.start : rates.end, .99));
            assert(near(right ? rates.end : rates.start, 1));
            checkPlayback(points, 8 * ratio, 1 / ratio);
            const auto restoreRatio = adjustRate(points, 0, right, 0, false, true, 1 / ratio);
            assert(near(restoreRatio * ratio, 1));
            for (size_t i = 0; i < points.size(); ++i) assert(near(points[i].position, original[i].position));
        }
    }

    std::vector<ElasticPoint> points{{.25, .25}, {.625, .625}};
    assert(near(adjustRate(points, 0, true, 40, true, false, 1), 1));
    assert(near(points[0].position, .25) && near(points[1].position, .625));
    assert(near(speed(points, 1).start, .8) && near(speed(points, 1).end, 1.2));
    assert(insert(points, {.4375, .41875001}));
    assert(near(points[1].source, 3.35 / 8));
    assert(near(speed(points, 1).end, 1) && near(speed(points, 2).start, 1));
    checkPlayback(points, 8, 1);
    std::cout << "Elastic timing and audio continuity passed\n";
}
