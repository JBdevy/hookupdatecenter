#pragma once
#include "../../Core/Transport/Engine.hpp"
#include <algorithm>
#include <cmath>
#include <deque>

namespace catlive {
// Only changes made by the advancing scheduler are delayed. User queue/cancel
// commands remain immediate, and no wall clock advances a pending transition.
class TransportPresentationQueues {
  public:
    void reset() {
        section.clear(); region.clear(); song.clear();
        renderedSeconds = 0; latencySeconds = 0;
    }
    void advance(double elapsed, double latency, const jaras::TransportState &before,
                 const jaras::TransportState &after) {
        if (before.songId != after.songId || latency <= 0) { reset(); return; }
        if (std::abs(latencySeconds - latency) > 1e-9) reset();
        latencySeconds = latency;
        renderedSeconds += std::max(0., elapsed);
        section.advance(renderedSeconds, latency, before.queuedSectionMarkerId,
                        before.sectionQueueStartedAt, after.queuedSectionMarkerId,
                        after.sectionQueueStartedAt);
        region.advance(renderedSeconds, latency, before.queuedRegionId, before.queueStartedAt,
                       after.queuedRegionId, after.queueStartedAt);
        song.advance(renderedSeconds, latency, before.queue.songId, 0, after.queue.songId, 0);
    }
    void apply(jaras::TransportState &state) const {
        section.apply(state.queuedSectionMarkerId, state.sectionQueueStartedAt);
        region.apply(state.queuedRegionId, state.queueStartedAt);
        double unused = 0;
        song.apply(state.queue.songId, unused);
    }
    void command(jaras::CommandKind kind, const jaras::TransportState &before,
                 const jaras::TransportState &after) {
        using Kind = jaras::CommandKind;
        if (before.songId != after.songId || before.position != after.position ||
            before.playing != after.playing || kind == Kind::stop || kind == Kind::stopAll ||
            kind == Kind::pause || kind == Kind::seek || kind == Kind::select ||
            kind == Kind::selectRegion || kind == Kind::next || kind == Kind::previous ||
            (kind == Kind::play && before.playing != after.playing)) {
            reset(); return;
        }
        if (kind == Kind::escape) {
            // Match the core's one-action-per-Escape priority. Cancelling a
            // loop must not hide a still-pending section or region jump.
            if (before.queuedSectionMarkerId) section.clear();
            else if (!before.loop.enabled) { region.clear(); song.clear(); }
            return;
        }
        if (kind == Kind::queueSection || kind == Kind::cancelSection) section.clear();
        if (kind == Kind::queueRegion) region.clear();
        if (kind == Kind::queue) song.clear();
    }

  private:
    struct Change { double until; std::optional<jaras::ID> target; double started; };
    struct Channel {
        std::deque<Change> pending;
        void clear() { pending.clear(); }
        void advance(double now, double latency, const std::optional<jaras::ID> &before,
                     double beforeStarted, const std::optional<jaras::ID> &after,
                     double afterStarted) {
            while (!pending.empty() && pending.front().until <= now + 1e-9) pending.pop_front();
            if (before != after || (before && beforeStarted != afterStarted))
                pending.push_back({now + latency, before, beforeStarted});
        }
        void apply(std::optional<jaras::ID> &target, double &started) const {
            if (pending.empty()) return;
            target = pending.front().target;
            started = pending.front().started;
        }
    } section, region, song;
    double renderedSeconds = 0, latencySeconds = 0;
};
} // namespace catlive
