#pragma once
#include <algorithm>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace catlive {
// Document coordinates: scrolling changes the query, not the item geometry.
// Rows include automation gaps; item rectangles include their actual overlap lane.
class TimelineMarqueeIndex {
public:
    struct Bounds {
        double left, top, right, bottom;
        bool intersects(const Bounds &other) const {
            return left < other.right && right > other.left && top < other.bottom && bottom > other.top;
        }
    };
    struct Item { std::string id; Bounds bounds; };
    struct Row {
        double top, bottom;
        std::vector<Item> items;
        std::vector<double> maximumRight;
    };
    void clear() { rows.clear(); boundsByID.clear(); }
    void addRow(double top, double bottom, std::vector<Item> items) {
        if (items.empty()) return;
        std::stable_sort(items.begin(), items.end(), [](const auto &a, const auto &b) { return a.bounds.left < b.bounds.left; });
        Row row{top, bottom, std::move(items), {}};
        row.maximumRight.reserve(row.items.size());
        double right = row.items.front().bounds.right;
        for (const auto &item : row.items) {
            right = std::max(right, item.bounds.right);
            row.maximumRight.push_back(right);
            boundsByID.emplace(item.id, item.bounds);
        }
        rows.push_back(std::move(row));
    }
    void select(const Bounds &query, std::set<std::string> &selected, size_t *visited = nullptr) const {
        if (visited) *visited = 0;
        auto row = std::lower_bound(rows.begin(), rows.end(), query.top,
            [](const Row &value, double top) { return value.bottom <= top; });
        for (; row != rows.end() && row->top < query.bottom; ++row) {
            const auto first = std::upper_bound(row->maximumRight.begin(), row->maximumRight.end(), query.left);
            for (size_t i = size_t(first - row->maximumRight.begin()); i < row->items.size(); ++i) {
                const auto &item = row->items[i];
                if (item.bounds.left >= query.right) break;
                if (visited) ++*visited;
                if (item.bounds.intersects(query)) selected.insert(item.id);
            }
        }
    }
    const Bounds *bounds(const std::string &id) const {
        const auto found = boundsByID.find(id);
        return found == boundsByID.end() ? nullptr : &found->second;
    }
private:
    std::vector<Row> rows;
    std::map<std::string, Bounds> boundsByID;
};
}
