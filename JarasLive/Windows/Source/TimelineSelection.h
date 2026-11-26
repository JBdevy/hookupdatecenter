#pragma once
#include <algorithm>
#include <set>
#include <vector>

namespace catlive::timelineSelection {
template <class ID>
std::set<ID> interval(const std::vector<ID>& ordered, const ID& anchor, const ID& target) {
    const auto first = std::find(ordered.begin(), ordered.end(), anchor);
    const auto last = std::find(ordered.begin(), ordered.end(), target);
    if (first == ordered.end() || last == ordered.end()) return {target};
    return {std::min(first, last), std::max(first, last) + 1};
}
}
