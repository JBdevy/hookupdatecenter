#pragma once
#include <juce_graphics/juce_graphics.h>

namespace catlive::timelineNeedle {
inline constexpr float maxTrailWidth = 38.f;

inline juce::Rectangle<int> paintBounds(float x, float trailWidth, juce::Rectangle<int> viewport) {
    // Include the rounded head and one extra pixel for antialiasing.
    const auto left = std::max(x - std::max(8.f, trailWidth + 1.f), float(viewport.getX()));
    const auto right = std::min(x + 8.f, float(viewport.getRight()));
    if (right <= left) return {};
    return juce::Rectangle<float>::leftTopRightBottom(left, float(viewport.getY()), right,
                                                      float(viewport.getBottom())).getSmallestIntegerContainer();
}

inline void draw(juce::Graphics &graphics, float x, float top, float tip, float bottom,
                 juce::Colour colour, float trailWidth = 0.f) {
    if (trailWidth > 0.f && bottom > tip) {
        juce::ColourGradient fade(colour.withAlpha(0.f), x - trailWidth, tip,
                                  colour.withMultipliedAlpha(.42f), x, tip, false);
        fade.addColour(.5, colour.withMultipliedAlpha(.08f));
        graphics.setGradientFill(fade);
        graphics.fillRect(x - trailWidth, tip, trailWidth, bottom - tip);
    }
    graphics.setColour(colour.withMultipliedAlpha(.12f));
    graphics.fillRect(x-3, tip, 6.f, std::max(0.f,bottom-tip));
    graphics.setColour(colour);
    graphics.fillRect(x-.75f, tip, 1.5f, std::max(0.f,bottom-tip));
    juce::Path head;
    head.startNewSubPath(x-5,top);
    head.lineTo(x+5,top);
    head.quadraticTo(x+7.5f,top,x+6.25f,top+2.25f);
    head.lineTo(x+.9f,tip-1.1f);
    head.quadraticTo(x+.5f,tip,x,tip);
    head.quadraticTo(x-.5f,tip,x-.9f,tip-1.1f);
    head.lineTo(x-6.25f,top+2.25f);
    head.quadraticTo(x-7.5f,top,x-5,top);
    head.closeSubPath();
    graphics.fillPath(head);
}
}
