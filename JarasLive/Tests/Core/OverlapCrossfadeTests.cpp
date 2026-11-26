#include "../../Core/Tracks/OverlapCrossfade.hpp"
#include <cassert>
#include <cmath>
#include <iostream>

using namespace jaras::overlap;

static double mixedGain(const std::vector<Item>& items, const Envelopes& fades, double time) {
    double mix = 0;
    for (const auto& item : items) {
        if (time < item.start || time >= item.end) continue;
        const auto fade = fades.find(item.id);
        mix += fade == fades.end() ? 1 : gain(fade->second, time - item.start);
    }
    return mix;
}

int main() {
    assert(compile({{"first", 0, 1}, {"adjacent", 1, 2}}).empty());

    const std::vector<Item> items{{"first", 1, 7}, {"second", 3, 9},
        {"contained", 4, 6}, {"same-start", 4, 8}, {"last", 7, 10}};
    const auto fades = compile(items);
    for (int sample = 100; sample < 1000; ++sample)
        assert(std::abs(mixedGain(items, fades, sample / 100.) - 1) < 1e-12);

    const std::vector<Item> pair{{"out", 10, 14}, {"in", 12, 17}};
    const auto pairFades = compile(pair);
    assert(gain(pairFades.at("out"), 2) == 1);
    assert(gain(pairFades.at("in"), 0) == 0);
    assert(gain(pairFades.at("out"), 3) == .5);
    assert(gain(pairFades.at("in"), 1) == .5);
    assert(gain(pairFades.at("in"), 2) == 1);
    auto reversed = pair;
    std::reverse(reversed.begin(), reversed.end());
    const auto reversedFades = compile(reversed);
    assert(gain(reversedFades.at("in"), .5) == gain(pairFades.at("in"), .5));
    std::cout << "Stacked audio crossfades passed\n";
}
