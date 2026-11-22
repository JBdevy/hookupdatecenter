#include "Common.h"
#include <BinaryData.h>
namespace catlive::theme {
namespace {
// Use the bundled Inter face at the requested point size on both desktops.
// The peer handles display DPI. Keep the small-label legibility floor.
Font calibrated(Typeface::Ptr face, float points) {
    // Preserve natural glyph proportions instead of compressing text to fit.
    return Font(FontOptions(face).withFallbacks({"Segoe UI Emoji", "Segoe UI Symbol"}).withFallbackEnabled(true).withPointHeight(std::max(10.8f, points)));
}
}
Font mediumFont(float size) {
    static auto face = Typeface::createSystemTypefaceFor(BinaryData::InterMedium_ttf, BinaryData::InterMedium_ttfSize);
    return calibrated(face, size);
}
Font semiboldFont(float size) {
    static auto face = Typeface::createSystemTypefaceFor(BinaryData::InterSemiBold_ttf, BinaryData::InterSemiBold_ttfSize);
    return calibrated(face, size);
}
Font font(float size, bool bold, bool italic) {
    static auto regular = Typeface::createSystemTypefaceFor(BinaryData::InterRegular_ttf, BinaryData::InterRegular_ttfSize);
    static auto boldFace = Typeface::createSystemTypefaceFor(BinaryData::InterBold_ttf, BinaryData::InterBold_ttfSize);
    static auto boldItalic = Typeface::createSystemTypefaceFor(BinaryData::InterBoldItalic_ttf, BinaryData::InterBoldItalic_ttfSize);
    return calibrated(italic ? boldItalic : bold ? boldFace : regular, size);
}
Font setlistFont(float size, int style) {
    if (style < 3 || style > 6) return font(size, style == 1 || style == 2, style == 2);
    static const Typeface::Ptr faces[] = {
        Typeface::createSystemTypefaceFor(BinaryData::InterExtraBold_ttf, BinaryData::InterExtraBold_ttfSize),
        Typeface::createSystemTypefaceFor(BinaryData::InterBlack_ttf, BinaryData::InterBlack_ttfSize),
        Typeface::createSystemTypefaceFor(BinaryData::ArchivoBlackRegular_ttf, BinaryData::ArchivoBlackRegular_ttfSize),
        Typeface::createSystemTypefaceFor(BinaryData::BungeeRegular_ttf, BinaryData::BungeeRegular_ttfSize)
    };
    return calibrated(faces[style - 3], size);
}
}
