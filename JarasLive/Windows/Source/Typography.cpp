#include "Common.h"
#include <BinaryData.h>
namespace catlive::theme {
namespace {
// Inter, bundled on both desktop platforms. Keep component bounds and the
// application's DPI/UI scale independent of typography. Tiny Windows labels
// retain at least 10.8px EM (the selected-song display size) rather than collapsing to 7–8px at 100-percent scale.
constexpr float windowsTextScale = .9f;
Font calibrated(Typeface::Ptr face, float points) {
    // Preserve natural glyph proportions instead of compressing text to fit.
    return Font(FontOptions(face).withFallbacks({"Segoe UI Emoji", "Segoe UI Symbol"}).withFallbackEnabled(true).withPointHeight(std::max(10.8f, points * windowsTextScale)));
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
