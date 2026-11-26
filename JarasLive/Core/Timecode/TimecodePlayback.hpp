#pragma once
#include "Timecode.hpp"
#include "../Songs/Song.hpp"
#include "../Songs/TempoEditMap.hpp"
#include <limits>

namespace jaras {
// Prepared on the control thread. The audio callback only reads these spans.
struct TimecodeProgram {
    struct Span {
        ID id, region;
        double start = 0, end = 0, origin = 0, source = 0, speed = 1;
        TimecodeSettings settings;
        bool muted = false;
        double time(double position) const { return source + (position - start) * speed + settings.offset; }
    };
    std::vector<Span> spans;
    TimecodeProgram() = default;
    TimecodeProgram(const Song& song, const Track& track) {
        TempoEditMap::PlaybackRates rates(song);
        for (const auto& clip : track.clips) {
            if (clip.audioFile || clip.duration <= 0) continue;
            Span span;
            span.id = clip.id; span.start = clip.startTime;
            span.end = clip.startTime + clip.duration;
            span.settings = clip.timecode.value_or(track.timecode.value_or(TimecodeSettings{}));
            span.muted = clip.muted;
            // Generated IDs use the same reversible UUID namespace as Mac.
            for (const auto& part : song.parts) {
                auto id = part.id;
                if (id.size() == 36) {
                    const int digit = id[0] >= '0' && id[0] <= '9' ? id[0] - '0'
                        : id[0] >= 'A' && id[0] <= 'F' ? id[0] - 'A' + 10
                        : id[0] >= 'a' && id[0] <= 'f' ? id[0] - 'a' + 10 : -1;
                    if (digit < 0) continue;
                    id[0] = "0123456789ABCDEF"[digit ^ 8];
                } else id += "-timecode";
                if (id == clip.id) { span.region = part.id; span.origin = part.startTime; break; }
            }
            if (span.region.empty()) span.origin = clip.startTime;
            if (!span.settings.regionRelative) span.origin = 0;
            auto sourceSpan=[&](double from,double to) {
                double total=0,time=from;
                for(const auto& point:rates.points(clip))if(point.time>time && point.time<to){total+=(point.time-time)*rates.playbackRate(clip,time);time=point.time;}
                return total+(to-time)*rates.playbackRate(clip,time);
            };
            double source=clip.sourceOffset+(clip.startTime>=span.origin?sourceSpan(span.origin,clip.startTime):-sourceSpan(clip.startTime,span.origin));
            std::vector<double> edges{span.start,span.end};
            for(const auto& point:rates.points(clip))if(point.time>span.start && point.time<span.end)edges.push_back(point.time);
            std::sort(edges.begin(),edges.end());edges.erase(std::unique(edges.begin(),edges.end()),edges.end());
            for(size_t i=1;i<edges.size();++i) {
                auto fragment=span;fragment.start=edges[i-1];fragment.end=edges[i];fragment.source=source;
                fragment.speed=rates.playbackRate(clip,fragment.start);
                source+=(fragment.end-fragment.start)*fragment.speed;spans.push_back(std::move(fragment));
            }
        }
        std::stable_sort(spans.begin(), spans.end(), [](const auto& a, const auto& b) { return a.start < b.start; });
    }
    int preferred(const std::optional<ID>& region) const {
        if (region) for (size_t i = 0; i < spans.size(); ++i)
            if (spans[i].region == *region) return static_cast<int>(i);
        return -1;
    }
    const Span* at(double position, int preferred = -1, double lookahead = 0) const {
        if (preferred >= 0 && preferred < static_cast<int>(spans.size())) {
            const auto& span = spans[static_cast<size_t>(preferred)];
            if (position >= span.start && position < span.end) return &span;
            for(const auto& fragment:spans)if(fragment.id==span.id && position>=fragment.start && position<fragment.end)return &fragment;
        }
        const Span* upcoming = nullptr;
        for (const auto& span : spans) {
            if (span.start > position + lookahead) break;
            if (position >= span.start && position < span.end) return &span;
            if (!upcoming && position < span.start) upcoming = &span;
        }
        return upcoming;
    }
};

class LTCWaveform {
public:
    float sample(double seconds, double fps) {
        if (!std::isfinite(seconds) || seconds < 0) return 0;
        const double rate = fps == 29.97 ? 30000.0 / 1001.0 : fps;
        if (rate <= 0) return 0;
        // Reduce before integer conversion, matching the codec's 24-hour wrap.
        const double dayFrames = fps == 29.97 ? 2589408.0 : std::round(fps) * 86400.0;
        const auto half = static_cast<int64_t>(std::floor(std::fmod(seconds, dayFrames / rate) * rate * 160));
        const auto frame = half / 160;
        if (frame != lastFrame || fps != lastRate) {
            const auto bits = ltcFrame((frame + 0.01) / rate, fps);
            float phase = .25f;
            for (int bit = 0; bit < 80; ++bit) {
                phase = -phase; halves[static_cast<size_t>(bit * 2)] = phase;
                if (bits[static_cast<size_t>(bit)]) phase = -phase;
                halves[static_cast<size_t>(bit * 2 + 1)] = phase;
            }
            lastFrame = frame; lastRate = fps;
        }
        return halves[static_cast<size_t>(half % 160)];
    }
private:
    int64_t lastFrame = -1;
    double lastRate = 0;
    std::array<float, 160> halves{};
};
}
