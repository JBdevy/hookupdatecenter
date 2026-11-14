#pragma once
#include "MultiLoop.hpp"
#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <vector>

namespace jaras {
struct MultiLoopTrackSelection {
    std::set<ID> ids;
    std::optional<ID> anchor;
    void select(const ID &id, const std::vector<ID> &ordered, bool extending = false, bool additive = false) {
        const std::set<ID> available(ordered.begin(), ordered.end());
        for (auto it = ids.begin(); it != ids.end();) {
            if (!available.count(*it)) it = ids.erase(it); else ++it;
        }
        const auto last = std::find(ordered.begin(), ordered.end(), id);
        if (last == ordered.end()) return;
        const auto first = anchor ? std::find(ordered.begin(), ordered.end(), *anchor) : ordered.end();
        if (extending && first != ordered.end()) {
            if (!additive) ids.clear();
            ids.insert(std::min(first, last), std::max(first, last) + 1);
        } else {
            if (additive) { if (!ids.insert(id).second) ids.erase(id); }
            else ids = {id};
            anchor = id;
        }
    }
    const std::set<ID> &targets(const ID &id) {
        if (!ids.count(id)) { ids = {id}; anchor = id; }
        return ids;
    }
};

struct MultiLoopGainDrag {
    ID source;
    std::map<ID, double> start, ceilings;
    MultiLoopGainDrag(const ID &source, const std::set<ID> &targets,
                     const std::vector<MultiLoopTrack> &rules, std::map<ID, double> limits)
        : source(source), ceilings(std::move(limits)) {
        for (const auto &rule : rules) if (targets.count(rule.id))
            start[rule.id] = std::min(std::max(0., ceilings[rule.id]), std::max(0., rule.gain));
    }
    std::map<ID, double> gains(double value) const {
        const auto origin = start.find(source);
        if (!std::isfinite(value) || origin == start.end()) return {};
        const double requested = std::max(0., value), ratio = requested / std::max(.000001, origin->second);
        std::map<ID, double> result;
        for (const auto &[id, gain] : start) {
            const auto ceiling = ceilings.find(id);
            const double limit = ceiling == ceilings.end() ? 0 : std::max(0., ceiling->second);
            result[id] = std::min(limit, id == source ? requested : std::max(.000001, gain) * ratio);
        }
        return result;
    }
};
}
