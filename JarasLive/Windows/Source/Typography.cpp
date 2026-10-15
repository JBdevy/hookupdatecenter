#include "Common.h"
#include <BinaryData.h>
namespace catlive::theme {
Font mediumFont(float size) {
    static auto face = Typeface::createSystemTypefaceFor(BinaryData::FigtreeMedium_ttf, BinaryData::FigtreeMedium_ttfSize);
    return Font(FontOptions(face).withPointHeight(size));
}
Font semiboldFont(float size) {
    static auto face = Typeface::createSystemTypefaceFor(BinaryData::FigtreeSemiBold_ttf, BinaryData::FigtreeSemiBold_ttfSize);
    return Font(FontOptions(face).withPointHeight(size));
}
Font font(float size, bool bold, bool italic) {
    // Read the actual faces from the executable. No installed font or network is needed.
    static auto regular = Typeface::createSystemTypefaceFor(BinaryData::FigtreeRegular_ttf, BinaryData::FigtreeRegular_ttfSize);
    static auto boldFace = Typeface::createSystemTypefaceFor(BinaryData::FigtreeBold_ttf, BinaryData::FigtreeBold_ttfSize);
    static auto boldItalic = Typeface::createSystemTypefaceFor(BinaryData::FigtreeBoldItalic_ttf, BinaryData::FigtreeBoldItalic_ttfSize);
    auto face = italic ? boldItalic : bold ? boldFace : regular;
    // Use the same logical point sizes as the Mac views. JUCE applies display DPI;
    // shrinking the font here makes every screen smaller than its reference.
    return Font(FontOptions(face).withPointHeight(size));
}
}
