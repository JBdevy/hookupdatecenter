#pragma once

namespace catlive {
// Read the same two raster sheets bundled by the macOS and iPad targets.
inline Image controlArtwork(const String &name, bool active) {
    struct Atlas {
        std::map<String, std::array<Image, 2>> icons;
        Atlas() {
            const auto dir = File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("ControlIcons");
            StringArray names;
            dir.getChildFile("controlNames.txt").readLines(names);
            const auto off = ImageFileFormat::loadFrom(dir.getChildFile("controlsOff.png"));
            const auto on = ImageFileFormat::loadFrom(dir.getChildFile("controlsOn.png"));
            if (off.isNull() || on.isNull() || off.getBounds() != on.getBounds()) return;
            const auto tile = off.getWidth() / 8;
            for (int i = 0; i < names.size(); ++i) {
                if (names[i].isEmpty()) continue;
                const juce::Rectangle<int> cell((i % 8) * tile, (i / 8) * tile, tile, tile);
                if (off.getBounds().contains(cell))
                    icons.emplace(names[i], std::array<Image, 2>{off.getClippedImage(cell), on.getClippedImage(cell)});
            }
        }
    };
    static const Atlas atlas;
    const auto found = atlas.icons.find(name);
    return found == atlas.icons.end() ? Image{} : found->second[active ? 1 : 0];
}
inline bool drawControlIcon(Graphics &g, const String &name, bool active, juce::Rectangle<float> bounds, float opacity) {
    const auto image = controlArtwork(name, active);
    if (!image.isValid()) return false;
    Graphics::ScopedSaveState save(g);
    g.setOpacity(opacity);
    g.setImageResamplingQuality(Graphics::highResamplingQuality);
    g.drawImage(image, bounds, RectanglePlacement::centred);
    return true;
}
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
