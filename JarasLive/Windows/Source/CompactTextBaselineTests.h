#pragma once
#include "Common.h"
#include <typeinfo>

namespace catlive::compactTextBaselineTests {
// Exercise the actual JUCE Direct2D renderer. The reference applies the physical
// baseline alignment explicitly in layout; the normal drawText call must match.
inline Image render(float scale, int height, int mode, bool reference) {
    const bool alpha = mode == 2;
    Image image(alpha ? Image::ARGB : Image::RGB, (int)std::ceil(600 * scale),
                (int)std::ceil(130 * scale), true, NativeImageType{});
    Graphics g(image);
    if (!alpha) g.fillAll(Colour(0xff141414));
    g.addTransform(AffineTransform::scale(scale));
    g.addTransform(AffineTransform::translation(.25f, .35f));
    RectangleList<int> outer;
    outer.add({3, 3, 275, 120}); outer.add({300, 3, 292, 120});
    g.reduceClipRegion(outer);
    g.saveState();
    if (mode == 1) {
        RectangleList<int> inner;
        inner.add({8, 6, 580, 55}); inner.add({8, 65, 580, 55});
        g.reduceClipRegion(inner);
    }
    if (mode == 3) g.beginTransparencyLayer(.5f);
    g.setColour(Colours::white.withAlpha(.13f)); g.fillRect(15, 6, 550, 115);
    const auto font = mode == 4 ? theme::font(13) : theme::semiboldFont(12);
    g.setFont(font);
    for (int row = 0; row < 3; ++row) {
        const String value = row == 0 ? "OUSADO AMOR - (Dm) - 126 bpm"
                             : row == 1 ? "-30.00  +24.00  Center Patch gypq"
                                        : String::fromUTF8("01 REGÊNCIA Guitar Trompete");
        float y = 9.f + row * 35;
        GlyphArrangement arrangement;
        arrangement.addCurtailedLineOfText(font, value, 0, 0, 550, false);
        arrangement.justifyGlyphs(0, arrangement.getNumGlyphs(), 0, 0, 550,
                                  (float)height, Justification::centredLeft);
        if (reference && font.getHeightInPoints() * scale <= 18) {
            const float physical = (y + arrangement.getGlyph(0).getBaselineY() + .35f) * scale;
            y += (std::round(physical) - physical) / scale;
        }
        g.setColour(Colours::white);
        g.drawText(value, juce::Rectangle<float>(15, y, 550, (float)height),
                   Justification::centredLeft, false);
    }
    g.setColour(Colours::black.withAlpha(.21f)); g.fillRect(25, 10, 520, 112);
    if (mode == 3) g.endTransparencyLayer();
    g.restoreState();
    return image;
}
inline bool samePixels(const Image &a, const Image &b) {
    const Image::BitmapData left(a, Image::BitmapData::readOnly);
    const Image::BitmapData right(b, Image::BitmapData::readOnly);
    for (int y = 0; y < a.getHeight(); ++y)
        for (int x = 0; x < a.getWidth(); ++x)
            if (left.getPixelColour(x, y) != right.getPixelColour(x, y)) return false;
    return true;
}
inline bool direct2DAvailable() {
    for (auto format : {Image::RGB, Image::ARGB}) {
        Image probe(format, 8, 8, true, NativeImageType{});
        auto context = probe.createLowLevelContext();
        // NativeImageType itself can fall back to software on a headless host.
        // Check the actual context, not only the image storage type.
        if (!context || !String(typeid(*context).name()).contains("Direct2DPixelData"))
            return false;
    }
    return true;
}
template<typename Test> void registerTests(Test &test, StringArray &skipped) {
    if (!direct2DAvailable()) {
        skipped.add("Compact text baseline: Direct2D is unavailable; native rendering comparison skipped.");
        return;
    }
    test("Compact text aligns physical baselines across DPI, UI scale and alpha clips", [] {
        for (float dpi : {1.f, 1.25f, 1.5f})
            for (float ui : {.8f, 1.f, 1.25f})
                for (int height : {12, 21, 26, 34})
                    for (int mode = 0; mode < 5; ++mode) {
                        const auto expected = render(dpi * ui, height, mode, true);
                        const auto actual = render(dpi * ui, height, mode, false);
                        if (!samePixels(expected, actual))
                            throw std::runtime_error("Text baseline/clip changed at DPI " +
                                std::to_string(dpi) + " scale " + std::to_string(ui) +
                                " height " + std::to_string(height) + " mode " + std::to_string(mode));
                    }
    });
}
}
