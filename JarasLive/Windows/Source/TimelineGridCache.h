#pragma once
#include <cstdint>
#include <algorithm>
#include <limits>
#include <optional>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

namespace catlive {
// One visible ruler/grid per canvas. Selection/hover repaints keep the same
// divisions and formatted labels; zoom, pan and project edits rebuild them.
template <typename Tick> class TimelineGridCache final {
  public:
    template <typename Build>
    const std::vector<Tick>& get(const std::string& project, const std::string& song, uint64_t revision,
                                double start, double end, double scale, Build build) {
        const Key next{project, song, revision, start, end, scale};
        if (key && *key == next) { ++hits; return retained; }
        auto result = build();
        retained = std::move(result); key = next; ++builds;
        return retained;
    }
    void invalidate() { key.reset(); retained.clear(); }
    uint64_t builds = 0, hits = 0;
  private:
    using Key = std::tuple<std::string, std::string, uint64_t, double, double, double>;
    std::optional<Key> key;
    std::vector<Tick> retained;
};
}

namespace catlive {
// Immutable document intervals with retained drawing metadata. Zoom queries
// only overlapping candidates; project edits and drag previews replace them.
template <typename Metadata> class TimelineRegionDrawingCache final {
  public:
    struct Entry { double start, end; size_t sourceIndex; Metadata data; };
    template <typename Build>
    void prepare(const std::string& project, const std::string& song, uint64_t revision, bool english, Build build) {
        const Key next{project, song, revision, english};
        if (key && *key == next) return;
        entries=build();
        std::stable_sort(entries.begin(),entries.end(),[](const auto& a,const auto& b) {
            return a.start==b.start?a.sourceIndex<b.sourceIndex:a.start<b.start;
        });
        maximumEnds.clear(); maximumEnds.reserve(entries.size());
        double maximum=-std::numeric_limits<double>::infinity();
        for(const auto& entry:entries) { maximum=std::max(maximum,entry.end);maximumEnds.push_back(maximum); }
        key=next; ++builds;
    }
    std::vector<const Entry*> visible(double from,double through) const {
        const auto end=std::upper_bound(entries.begin(),entries.end(),through,
            [](double value,const auto& entry){return value<entry.start;});
        const auto count=(size_t)std::distance(entries.begin(),end);
        const auto first=std::lower_bound(maximumEnds.begin(),maximumEnds.begin()+(ptrdiff_t)count,from);
        std::vector<const Entry*> result;
        for(size_t i=(size_t)std::distance(maximumEnds.begin(),first);i<count;++i)
            if(entries[i].end>=from)result.push_back(&entries[i]);
        std::sort(result.begin(),result.end(),[](const auto* a,const auto* b){return a->sourceIndex<b->sourceIndex;});
        return result;
    }
    void invalidate() { key.reset(); }
    uint64_t builds=0;
  private:
    using Key=std::tuple<std::string,std::string,uint64_t,bool>;
    std::optional<Key> key;
    std::vector<Entry> entries;
    std::vector<double> maximumEnds;
};
}
