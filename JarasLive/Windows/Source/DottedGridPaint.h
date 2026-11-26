#pragma once
#include "Common.h"

namespace catlive {
// Reuse a tiny raster tile instead of constructing and rasterising hundreds of
// dashed paths per frame. The anchor is the ruler, including partial row paints.
class DottedGridPaint final {
  public:
    void draw(Graphics &g, Colour colour, float x, float top, float bottom,
              float physicalPixel, float anchor) {
        if (bottom <= top) return;
        if (pattern.isNull() || cachedColour != colour) {
            cachedColour = colour;
            pattern = Image(Image::ARGB, 1, 16, true);
            for (int y = 0; y < 4; ++y) pattern.setPixelAt(0, y, colour);
        }
        g.setFillType(FillType(pattern, AffineTransform::scale(.25f).translated(0, anchor)));
        g.fillRect(x + physicalPixel * .125f, top, physicalPixel * .75f, bottom - top);
    }
  private:
    Image pattern;
    Colour cachedColour;
};
}
