#pragma once
#include "Common.h"
#include "../../Core/Songs/TempoEditMap.hpp"
namespace catlive {
// Source-time mapping shared by the piano roll and MIDI/audio playback. The
// project retains one item even when its performance crosses tempo boundaries.
class ClipTempo {
  public:
    struct Span { double start, end, source, rate; };
    std::vector<Span> spans;
    ClipTempo(const jaras::AudioClip &clip, const jaras::Song *song = nullptr) {
        const double end = clip.startTime + clip.duration;
        std::vector<double> edges{clip.startTime, end};
        if (song && song->markers)
            for (const auto &marker : *song->markers)
                if (marker.tempoBPM && marker.position > clip.startTime && marker.position < end)
                    edges.push_back(marker.position);
        std::sort(edges.begin(), edges.end());
        edges.erase(std::unique(edges.begin(), edges.end()), edges.end());
        double source = clip.sourceOffset;
        for (size_t i = 1; i < edges.size(); ++i) {
            const double rate = song ? jaras::TempoEditMap::playbackRate(*song, clip, edges[i-1])
                                     : clip.playbackRate;
            if (!spans.empty() && std::abs(spans.back().rate - rate) < 1e-9)
                spans.back().end = edges[i];
            else spans.push_back({edges[i-1], edges[i], source, rate});
            source += (edges[i] - edges[i-1]) * rate;
        }
    }
    const Span *at(double time) const {
        if (spans.empty()) return nullptr;
        auto it = std::upper_bound(spans.begin(), spans.end(), time,
                                  [](double t, const Span &s){ return t < s.start; });
        return it == spans.begin() ? &spans.front() : &*--it;
    }
    double sourceAt(double time) const {
        const auto *span = at(time);
        return span ? span->source + (time - span->start) * span->rate : 0;
    }
    double timeAt(double source, bool bounded = true) const {
        if (spans.empty()) return 0;
        const auto &last = spans.back();
        if (bounded) source = jlimit(spans.front().source,
                                    last.source + (last.end-last.start)*last.rate, source);
        auto it = std::upper_bound(spans.begin(), spans.end(), source,
                                  [](double t, const Span &s){ return t < s.source; });
        const auto &span = it == spans.begin() ? spans.front() : *--it;
        return span.start + (source-span.source)/span.rate;
    }
};
}
