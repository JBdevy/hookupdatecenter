#pragma once
#include <algorithm>
namespace catlive {
struct MixerSlotSections {
    static constexpr int bypassRowHeight = 26, sessionRowHeight = 21;
    int plugins = 0, outputs = 0, divider = 0;
    MixerSlotSections(int height, int outputCount, bool main = false) {
        height = std::max(0, height);
        if (height < bypassRowHeight + 19) {
            plugins = height;
            return;
        }
        const int midpoint = std::max(19, (height - bypassRowHeight) / 2);
        const bool fitsBoth = height >= 19 + bypassRowHeight + sessionRowHeight + 19;
        plugins = fitsBoth ? std::min(midpoint, height - bypassRowHeight - sessionRowHeight - 19) : midpoint;
        const int spaceBelow = height - plugins - bypassRowHeight;
        const int sessionHeight = main && spaceBelow >= sessionRowHeight ? sessionRowHeight : 0;
        divider = bypassRowHeight + sessionHeight;
        outputs = outputCount > 0 ? spaceBelow - (spaceBelow >= sessionRowHeight ? sessionRowHeight : 0) : 0;
    }
};
}
