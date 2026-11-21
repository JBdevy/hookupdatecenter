#pragma once

namespace catlive {
inline bool drawDesktopToolbarSymbol(Graphics &g, const String &name, juce::Rectangle<float> bounds) {
    struct Artwork {
        Path outline;
        Path interior;

        Artwork(const char *outlinePath, const char *filledPath) {
            outline.restoreFromString(outlinePath);
            interior.restoreFromString(filledPath);
            interior.setUsingNonZeroWinding(false);
        }
    };
    static const std::map<String, Artwork> symbols{
        #define CATLIVE_TOOLBAR_SYMBOL(symbol, outline, interior) {symbol, Artwork(outline, interior)},
        #include "../../Resources/DesktopToolbarSymbols.def"
        #undef CATLIVE_TOOLBAR_SYMBOL
    };
    const auto icon = symbols.find(name);
    if (icon == symbols.end()) return false;
    const float scale = std::min(bounds.getWidth(), bounds.getHeight()) / 24.f;
    const auto transform = AffineTransform::scale(scale)
        .translated(bounds.getCentreX() - 12 * scale, bounds.getCentreY() - 12 * scale);
    g.fillPath(icon->second.interior, transform);
    auto outline = icon->second.outline;
    outline.applyTransform(transform);
    g.strokePath(outline, PathStrokeType(1.7f * scale, PathStrokeType::curved, PathStrokeType::rounded));
    return true;
}
}
