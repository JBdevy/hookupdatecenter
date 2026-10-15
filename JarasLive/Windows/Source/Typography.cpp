#include "Common.h"
#include <BinaryData.h>
namespace catlive::theme {
namespace {
// Calibrated against NSFont.systemFont at 13 pt using the real project labels.
// Inter is redistributable with the app; the Mac still uses its native system font.
constexpr float capScale = .9684564f;
Font calibrated(Typeface::Ptr face, float points, float width) {
    return Font(FontOptions(face).withPointHeight(points * capScale)).withHorizontalScale(width);
}
}
Font mediumFont(float size) {
    static auto face = Typeface::createSystemTypefaceFor(BinaryData::InterMedium_ttf, BinaryData::InterMedium_ttfSize);
    return calibrated(face, size, 1.031f);
}
Font semiboldFont(float size) {
    static auto face = Typeface::createSystemTypefaceFor(BinaryData::InterSemiBold_ttf, BinaryData::InterSemiBold_ttfSize);
    return calibrated(face, size, 1.040f);
}
Font font(float size, bool bold, bool italic) {
    static auto regular = Typeface::createSystemTypefaceFor(BinaryData::InterRegular_ttf, BinaryData::InterRegular_ttfSize);
    static auto boldFace = Typeface::createSystemTypefaceFor(BinaryData::InterBold_ttf, BinaryData::InterBold_ttfSize);
    static auto boldItalic = Typeface::createSystemTypefaceFor(BinaryData::InterBoldItalic_ttf, BinaryData::InterBoldItalic_ttfSize);
    return calibrated(italic ? boldItalic : bold ? boldFace : regular, size, bold || italic ? 1.054f : 1.017f);
}
}
