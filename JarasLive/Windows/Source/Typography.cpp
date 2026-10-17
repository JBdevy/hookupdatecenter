#include "Common.h"
#include <BinaryData.h>
namespace catlive::theme {
namespace {
// Inter, bundled on both desktop platforms.
// Compact Windows text requested for the notebook display. Keep component
// bounds and the application's DPI/UI scale independent of typography.
constexpr float windowsTextScale = .9f;
Font calibrated(Typeface::Ptr face, float points) {
    // Keep the outlines at their natural aspect ratio. Stretching every glyph
    // to match another font's widths makes small text less legible on Windows.
    return Font(FontOptions(face).withPointHeight(points * windowsTextScale));
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
}
