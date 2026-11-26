#pragma once
#include <algorithm>
#include <vector>

namespace catlive {
// Measurements change with edits; scrolling only queries their prefix offsets.
class TrackRowGeometry {
  public:
    struct Row { int body = 0, height = 0; };
    template<class Measure> void rebuild(int count, Measure measure) {
        rows.clear(); rows.reserve(std::max(0, count));
        offsets.assign(1, 0); offsets.reserve(std::max(0, count) + 1);
        for (int i = 0; i < count; ++i) {
            auto row = measure(i);
            row.body = std::max(0, row.body); row.height = std::max(0, row.height);
            rows.push_back(row); offsets.push_back(offsets.back() + row.height);
        }
    }
    int size() const { return int(rows.size()); }
    int body(int index) const { return valid(index) ? rows[size_t(index)].body : 0; }
    int height(int index) const { return valid(index) ? rows[size_t(index)].height : 0; }
    int top(int index) const { return offsets[size_t(std::clamp(index, 0, size()))]; }
    int rowAt(int y) const {
        if (y < 0 || y >= offsets.back()) return -1;
        // upper_bound also skips any number of hidden, zero-height rows.
        return int(std::upper_bound(offsets.begin(), offsets.end(), y) - offsets.begin()) - 1;
    }
  private:
    bool valid(int index) const { return index >= 0 && index < size(); }
    std::vector<Row> rows;
    std::vector<int> offsets{0};
};
}
