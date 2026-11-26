#pragma once
#include <algorithm>
namespace catlive {
struct MixerSlotSections {
    static constexpr int bypassRowHeight = 26, sessionRowHeight = 21, routingDividerHeight = 9;
    int plugins = 0, outputs = 0, divider = 0;
    MixerSlotSections(int height, int outputCount, bool main = false, bool separatedRouting = false) {
        height = std::max(0, height);
        if (height < bypassRowHeight + 19) {
            plugins = height;
            return;
        }
        const int afterBypass = height - bypassRowHeight - sessionRowHeight;
        const int extra = separatedRouting && afterBypass >= 38 ? routingDividerHeight : 0;
        const int midpoint = std::max(19, (height - bypassRowHeight) / 2 - extra);
        const int preferredRouting = separatedRouting ? 21 + extra + 19 : 19;
        const int minimumRouting = afterBypass >= 19 + preferredRouting ? preferredRouting : 19;
        plugins = afterBypass >= 38 ? std::min(midpoint, afterBypass - minimumRouting) : midpoint;
        const int spaceBelow = height - plugins - bypassRowHeight;
        const int sessionHeight = main && spaceBelow >= sessionRowHeight ? sessionRowHeight : 0;
        divider = bypassRowHeight + sessionHeight;
        outputs = outputCount > 0 ? spaceBelow - (spaceBelow >= sessionRowHeight ? sessionRowHeight : 0) : 0;
    }
};

struct MixerRoutingRows {
    static constexpr int stride = 21, rowHeight = 19;
    int count, busIndex;

    int rowTop(int row) const {
        return row * stride + (busIndex >= 0 && row >= busIndex ? MixerSlotSections::routingDividerHeight : 0);
    }
    int viewportTop(int first) const {
        return first == busIndex ? first * stride : rowTop(first);
    }
    int contentHeight() const {
        return count == 0 ? 0 : rowTop(count - 1) + rowHeight;
    }
    int rowAt(int y, int first) const {
        y += viewportTop(first);
        if (busIndex >= 0 && y >= busIndex * stride) {
            if (y < rowTop(busIndex)) return -1;
            y -= MixerSlotSections::routingDividerHeight;
        }
        return y >= 0 && y % stride < rowHeight && y / stride < count ? y / stride : -1;
    }
    int maximumFirstRow(int height) const {
        if (height <= 0 || count <= 1) return 0;
        const int remaining = contentHeight() - height;
        int first = std::clamp((remaining + stride - 1) / stride, 0, count - 1);
        if (first > 0 && first - 1 >= busIndex && viewportTop(first - 1) >= remaining) --first;
        return first;
    }
};
}
