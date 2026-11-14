#include "../../Windows/Source/TrackRowGeometry.h"
#include <cassert>
#include <iostream>

int main() {
    for (int count : {0, 1, 500, 900}) {
        catlive::TrackRowGeometry layout;
        int measurements = 0, total = 0;
        layout.rebuild(count, [&](int row) {
            ++measurements;
            const int body = 24 + (row % 5)*16;
            return catlive::TrackRowGeometry::Row{body, row % 7 == 0 ? 0 : body + (row % 3)*32};
        });
        assert(measurements == count);
        assert(layout.rowAt(-1) == -1);
        for (int row = 0; row < count; ++row) {
            assert(layout.top(row) == total);
            if (layout.height(row)) {
                assert(layout.rowAt(total) == row);
                assert(layout.rowAt(total + layout.height(row) - 1) == row);
            }
            total += layout.height(row);
        }
        assert(layout.top(count) == total && layout.rowAt(total) == -1);
        for (int pass = 0; pass < 100; ++pass)
            for (int y = total - 1; y >= 0; y -= 37) {
                const int row = layout.rowAt(y);
                assert(row >= 0 && layout.top(row) <= y && layout.top(row) + layout.height(row) > y);
            }
        assert(measurements == count); // Scrolling never remeasures offscreen rows.
        layout.rebuild(2, [](int row) { return catlive::TrackRowGeometry::Row{64, row == 0 ? 64 : 128}; });
        assert(layout.top(1) == 64 && layout.rowAt(191) == 1 && layout.rowAt(192) == -1);
    }
    std::cout << "WINDOWS_TRACK_GEOMETRY_500_900_HIDDEN_AUTOMATION_BOUNDARIES_OK\n";
}
