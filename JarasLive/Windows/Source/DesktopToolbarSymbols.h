#pragma once

namespace catlive {
// Read the same two raster sheets bundled by the macOS and iPad targets.
inline Image controlArtwork(const String &name, bool active, bool toolbar = false) {
    struct Atlas {
        std::map<String, std::array<Image, 3>> icons;
        Atlas() {
            const auto dir = File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("ControlIcons");
            StringArray names;
            dir.getChildFile("controlNames.txt").readLines(names);
            const auto off = ImageFileFormat::loadFrom(dir.getChildFile("controlsOff.png"));
            const auto on = ImageFileFormat::loadFrom(dir.getChildFile("controlsOn.png"));
            const auto toolbarOff = ImageFileFormat::loadFrom(dir.getChildFile("controlsToolbarOff.png"));
            if (off.isNull() || on.isNull() || off.getBounds() != on.getBounds()) return;
            const auto tile = off.getWidth() / 8;
            for (int i = 0; i < names.size(); ++i) {
                if (names[i].isEmpty()) continue;
                const juce::Rectangle<int> cell((i % 8) * tile, (i / 8) * tile, tile, tile);
                if (off.getBounds().contains(cell))
                    icons.emplace(names[i], std::array<Image, 3>{off.getClippedImage(cell), on.getClippedImage(cell),
                        toolbarOff.getBounds() == off.getBounds() ? toolbarOff.getClippedImage(cell) : off.getClippedImage(cell)});
            }
        }
    };
    static const Atlas atlas;
    const auto found = atlas.icons.find(name);
    return found == atlas.icons.end() ? Image{} : found->second[active ? 1 : toolbar ? 2 : 0];
}

inline Image rasterizeControlIcon(const Image &source, int pixels) {
    if (pixels >= source.getWidth())
        return source.rescaled(pixels, pixels, Graphics::highResamplingQuality);

    // Integrate the artwork's pixel coverage before the window renderer sees
    // it. Point and bilinear sampling lose thin strokes when shrinking 96 px
    // tiles to the icon's physical size, especially at fractional DPI scales.
    Image result(Image::ARGB, pixels, pixels, true, SoftwareImageType());
    const Image::BitmapData input(source, Image::BitmapData::readOnly);
    const Image::BitmapData output(result, Image::BitmapData::writeOnly);
    const double span = double(source.getWidth()) / pixels;
    for (int y = 0; y < pixels; ++y) {
        const double top = y * span, bottom = (y + 1) * span;
        for (int x = 0; x < pixels; ++x) {
            const double left = x * span, right = (x + 1) * span;
            double alpha = 0, red = 0, green = 0, blue = 0;
            for (int row = int(top); row < std::min(source.getHeight(), int(std::ceil(bottom))); ++row) {
                const double height = std::min(bottom, double(row + 1)) - std::max(top, double(row));
                for (int col = int(left); col < std::min(source.getWidth(), int(std::ceil(right))); ++col) {
                    const double width = std::min(right, double(col + 1)) - std::max(left, double(col));
                    const auto ink = input.getPixelColour(col, row);
                    const double weight = width * height * ink.getAlpha();
                    alpha += weight;
                    red += weight * ink.getRed();
                    green += weight * ink.getGreen();
                    blue += weight * ink.getBlue();
                }
            }
            if (alpha > 0) {
                const auto channel = [](double value) { return uint8(std::lround(value)); };
                output.setPixelColour(x, y, Colour(channel(red / alpha), channel(green / alpha),
                                                   channel(blue / alpha), channel(alpha / (span * span))));
            }
        }
    }
    return result;
}

inline bool drawControlIcon(Graphics &g, const String &name, bool active, juce::Rectangle<float> bounds, float opacity, bool toolbar = false) {
    const auto artwork = controlArtwork(name, active, toolbar);
    if (!artwork.isValid()) return false;
    const float scale = std::max(.25f, g.getInternalContext().getPhysicalPixelScaleFactor());
    const int pixels = std::max(1, int(std::lround(std::min(bounds.getWidth(), bounds.getHeight()) * scale)));
    using Key = std::tuple<String, int, int>;
    static thread_local std::map<Key, Image> rasters;
    const auto [at, inserted] = rasters.try_emplace({name, active ? 1 : toolbar ? 2 : 0, pixels});
    if (inserted) at->second = rasterizeControlIcon(artwork, pixels);
    const float side = pixels / scale;
    const float x = std::round((bounds.getCentreX() - side * .5f) * scale) / scale;
    const float y = std::round((bounds.getCentreY() - side * .5f) * scale) / scale;
    Graphics::ScopedSaveState save(g);
    g.setOpacity(opacity);
    // Parent transforms can still offset the filtered raster by a fraction of
    // a device pixel. Preserve its edge coverage across that last translation.
    g.setImageResamplingQuality(Graphics::mediumResamplingQuality);
    g.drawImageTransformed(at->second, AffineTransform::scale(1.f / scale).translated(x, y));
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
    const float density = std::max(.25f, g.getInternalContext().getPhysicalPixelScaleFactor());
    const float side = std::round(std::min(bounds.getWidth(), bounds.getHeight()) * density) / density;
    if (side <= 0) return true;
    const float scale = side / 24.f;
    const auto pin = [density](float point) { return std::round(point * density) / density; };
    const auto transform = AffineTransform::scale(scale)
        .translated(pin(bounds.getCentreX() - side * .5f), pin(bounds.getCentreY() - side * .5f));
    g.fillPath(icon->second.interior, transform);
    auto outline = icon->second.outline;
    outline.applyTransform(transform);
    // A small symbol must still resolve a complete physical pixel at compact scale.
    g.strokePath(outline, PathStrokeType(std::max(1.7f * scale, 1.f / density),
                                        PathStrokeType::curved, PathStrokeType::rounded));
    return true;
}
}
