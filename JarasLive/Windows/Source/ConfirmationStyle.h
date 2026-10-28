#pragma once
#include "Common.h"
namespace catlive::confirmationStyle {
// Short decisions share one compact size; height follows the amount of content.
inline constexpr int width = 320, iconWidth = 240, margin = 20, gap = 8, buttonHeight = 30;
inline constexpr float radius = 24, titleSize = 14, bodySize = 13, buttonSize = 14;
inline void surface(Graphics &g, juce::Rectangle<float> bounds) {
    g.setGradientFill(ColourGradient(Colour(0xff343434),bounds.getX(),bounds.getY(),
        Colour(0xff2e2e30),bounds.getRight(),bounds.getBottom(),false));
    g.fillRoundedRectangle(bounds,radius);
    g.setColour(Colours::white.withAlpha(.22f));g.drawRoundedRectangle(bounds.reduced(.5f),radius,1);
}
}
