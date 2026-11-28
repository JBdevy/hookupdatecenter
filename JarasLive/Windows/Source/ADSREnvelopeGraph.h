#pragma once
#include "Common.h"
#include "../../Core/Audio/WaveLFO.hpp"

namespace catlive {
inline void drawEnvelopeGraph(Graphics& g, juce::Rectangle<int> area, const jaras::WaveLFO& shape, Colour colour) {
    const auto bounds = area.toFloat().reduced(0.f, 2.f);
    const auto y = [&](double gain) { return bounds.getBottom() - float(gain) * bounds.getHeight(); };
    Path path;
    bool first = true;
    for (const auto& point : shape.vertices()) {
        const float x = bounds.getX() + float(point.time / shape.end) * bounds.getWidth();
        if (first) { path.startNewSubPath(x, y(point.gain)); first = false; }
        else path.lineTo(x, y(point.gain));
    }
    g.setColour(colour.withAlpha(.82f));
    g.strokePath(path, PathStrokeType(1.4f));
}
inline void drawADSREnvelope(Graphics& g, juce::Rectangle<int> area, double attack, double decay,
                             double sustain, double release, Colour colour) {
    const auto duration = attack + decay + release + .4;
    drawEnvelopeGraph(g, area, jaras::WaveLFO::prepare(duration, attack, 0, decay, sustain, release), colour);
}
}
