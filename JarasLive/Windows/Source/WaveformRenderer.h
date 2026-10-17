#pragma once
#include "WaveformCache.h"
#include "../../Core/Tracks/ItemFade.hpp"
namespace catlive {
// Mac geometry: connected min/max envelopes at half-point resolution; actual
// extrema in temporal order at close zoom. No independent pixel-wide bars.
struct WaveformRenderer {
    struct FadeEnvelope {
        double origin, scale, duration, in, out;
        jaras::FadeCurve inCurve, outCurve;
        FadeEnvelope(const jaras::AudioClip &clip, double x, double pixelsPerSecond)
            : origin(x), scale(pixelsPerSecond), duration(clip.duration),
              in(std::min(duration, clip.fadeIn.value_or(0))), out(std::min(duration, clip.fadeOut.value_or(0))),
              inCurve(clip.fadeInCurve.value_or(0), clip.fadeInSCurve.value_or(1)),
              outCurve(clip.fadeOutCurve.value_or(0), clip.fadeOutSCurve.value_or(1)) {}
        float at(double x) const {
            const double elapsed = (x - origin) / scale;
            return (float)((in > 0 ? inCurve.value(elapsed / in) : 1) *
                (out > 0 ? outCurve.value((duration - elapsed) / out) : 1));
        }
        bool active() const { return in > 0 || out > 0; }
    };
    static void draw(Graphics &g, WaveformCache &cache,
                     const std::shared_ptr<const WaveformCache::Data> &data,
                     const jaras::AudioClip &clip, juce::Rectangle<float> item,
                     juce::Rectangle<float> viewport, double pixelsPerSecond, Colour ink, bool clipToItem = true) {
        if (!data || data->sourceChannels <= 0 || pixelsPerSecond <= 0) return;
        const int mode = clip.channelMode.value_or(0);
        const int channels = mode == 0 ? data->sourceChannels : 1;
        const float top = item.getY() + 18, height = std::max(0.f, item.getBottom() - top - 2) / channels;
        if (height <= 0) return;
        const double rate = std::max(.001, clip.playbackRate), sourceScale = pixelsPerSecond / rate;
        const double visibleStart = std::max(0., (viewport.getX() - item.getX()) / pixelsPerSecond);
        const double visibleEnd = std::min(clip.duration, (viewport.getRight() - item.getX()) / pixelsPerSecond);
        if (visibleEnd <= visibleStart) return;
        const double loop = clip.loopLength.value_or(0), loopStart = clip.loopStart.value_or(0);
        const auto step = WaveformCache::step(data->sampleRate, sourceScale);
        const float amplitude = height * .98f * (float)jlimit(0., std::pow(10., 24. / 20), clip.gain.value_or(1));
        const FadeEnvelope fade(clip, item.getX(), pixelsPerSecond);
        const float physical = std::max(.01f, g.getInternalContext().getPhysicalPixelScaleFactor());
        g.saveState();
        if (clipToItem) {Path outline;outline.addRoundedRectangle(item,3);g.reduceClipRegion(outline);}
        g.setColour(ink);
        for (int channel = 0; channel < channels; ++channel) {
            const int sourceChannel = mode == 1 ? 0 : mode == 2 ? std::min(1, data->sourceChannels - 1)
                : mode == 3 && data->sourceChannels > 1 ? data->sourceChannels : channel;
            const float middle = top + height * (channel + .5f);
            auto lane = juce::Rectangle<float>(item.getX(), top + channel * height + .5f, item.getWidth(), std::max(0.f, height - 1)).getIntersection(viewport);
            if (lane.isEmpty()) continue;
            g.saveState();
            Path laneClip; laneClip.addRectangle(lane); g.reduceClipRegion(laneClip);
            double position = visibleStart;
            while (position < visibleEnd) {
                const double source = WaveformCache::sourcePosition(clip, position);
                const double raw = clip.sourceOffset + position * rate;
                if (loop > 0 && loop * sourceScale < 1 && raw >= loopStart) {
                    // Preserve any nonrepeating prefix before drawing subpixel repeats.
                    const auto peaks=data->range(sourceChannel,loopStart,loopStart+loop);
                    const float left=std::max(lane.getX(),item.getX()+(float)(position*pixelsPerSecond));
                    Path band;
                    for(float px=left;px<lane.getRight()+.5f;px+=.5f) {
                        const float x=std::min(px,lane.getRight()), y=middle-peaks.second*amplitude*fade.at(x);
                        if(px==left) band.startNewSubPath(x,y); else band.lineTo(x,y);
                    }
                    for(float px=lane.getRight();px>left-.5f;px-=.5f) {
                        const float x=std::max(px,left); band.lineTo(x,middle-peaks.first*amplitude*fade.at(x));
                    }
                    band.closeSubPath(); g.fillPath(band);
                    break;
                }
                const double untilLoop = loop <= 0 ? visibleEnd - position
                    : raw < loopStart ? (loopStart - raw) / rate
                    : std::max(1e-9, (loopStart + loop - source) / rate);
                const double end = std::min(visibleEnd, position + untilLoop);
                const double sourceEnd = std::min(data->duration, source + (end - position) * rate);
                if (sourceEnd > source) {
                    const double x = item.getX() + position * pixelsPerSecond;
                    const auto segment = juce::Rectangle<float>((float)x, lane.getY(), (float)((end - position) * pixelsPerSecond), lane.getHeight()).getIntersection(lane);
                    const bool cropped=segment!=lane;
                    if(cropped) {g.saveState();Path clipPath;clipPath.addRectangle(segment);g.reduceClipRegion(clipPath);}
                    bool detailed = false;
                    if (step < 256) detailed = drawDetail(g, cache, data, sourceChannel, source, sourceEnd, sourceScale, x, middle, amplitude, step, fade);
                    if (!detailed) drawEnvelope(g, *data, sourceChannel, source, sourceEnd, sourceScale, x, middle, amplitude, std::max<int64>(256, step), physical, fade);
                    if(cropped) g.restoreState();
                }
                if (end <= position) break;
                position = end;
            }
            g.restoreState();
        }
        g.restoreState();
    }
  private:
    static void drawEnvelope(Graphics &g, const WaveformCache::Data &data, int channel,
        double start, double end, double scale, double x, float middle, float amplitude, int64 step, float physical, const FadeEnvelope &fade) {
        const int64 first = std::max<int64>(0, (int64)std::floor(start * data.sampleRate / step) - 1);
        const int64 last = std::min<int64>((data.frames - 1) / step, (int64)std::ceil(end * data.sampleRate / step) + 1);
        if (last < first) return;
        struct Edge { float x, upper, lower; };
        std::vector<Edge> edges; edges.reserve((size_t)(last - first + 3));
        for (int64 bin = first; bin <= last; ++bin) {
            const double a = bin * step / data.sampleRate, b = std::min(data.duration, (bin + 1) * step / data.sampleRate);
            const auto peak = data.rangeFrames(channel, bin * step, std::min(data.frames, (bin + 1) * step));
            const auto edgeAt = [&](double time) {
                const float px = (float)(x + (time - start) * scale), level = amplitude * fade.at(px);
                const float center = middle - (peak.first + peak.second) * .5f * level;
                const float half = std::max(.5f / physical, (peak.second - peak.first) * .5f * level);
                return Edge{px, center-half, center+half};
            };
            if (bin == first) edges.push_back(edgeAt(a));
            edges.push_back(edgeAt((a+b)*.5));
            if (bin == last) edges.push_back(edgeAt(b));
        }
        Path path; path.preallocateSpace((int)edges.size() * 6);
        path.startNewSubPath(edges[0].x, edges[0].upper);
        for (size_t i = 1; i < edges.size(); ++i) path.lineTo(edges[i].x, edges[i].upper);
        for (auto i = edges.rbegin(); i != edges.rend(); ++i) path.lineTo(i->x, i->lower);
        path.closeSubPath(); g.fillPath(path);
    }
    static bool drawDetail(Graphics &g, WaveformCache &cache,
        const std::shared_ptr<const WaveformCache::Data> &data, int channel,
        double start, double end, double scale, double x, float middle, float amplitude, int64 step, const FadeEnvelope &fade) {
        const int64 first = std::max<int64>(0, ((int64)(start * data->sampleRate) / step - 1) * step);
        const int64 last = std::min<int64>(data->frames - 1, ((int64)std::ceil(end * data->sampleRate) / step + 2) * step);
        std::map<int64, std::shared_ptr<const WaveformCache::Detail>> pages;
        bool complete = true;
        for (int64 frame = first / WaveformCache::Detail::pageFrames * WaveformCache::Detail::pageFrames; frame <= last; frame += WaveformCache::Detail::pageFrames) {
            auto page = cache.detail(data, frame); complete &= page != nullptr;
            pages[frame / WaveformCache::Detail::pageFrames] = std::move(page);
        }
        if (!complete) return false;
        Path path; bool begun = false; int64 previous = -1;
        const auto append = [&](int64 frame, float value) {
            if (frame <= previous) return;
            const float px = (float)(x + (frame / data->sampleRate - start) * scale), py = middle - value * amplitude * fade.at(px);
            if (begun) path.lineTo(px, py); else { path.startNewSubPath(px, py); begun = true; }
            previous = frame;
        };
        for (int64 at = first; at <= last; at += step) {
            const int64 until = std::min({last, at + step - 1, data->frames - 1});
            const auto sample = [&](int64 frame) {
                return pages.at(frame / WaveformCache::Detail::pageFrames)->sample(channel, frame);
            };
            int64 lowAt = at, highAt = at;
            float low = sample(at), high = low;
            for (int64 n = at + 1; n <= until; ++n) {
                const float value = sample(n);
                if (value < low) { low = value; lowAt = n; }
                if (value > high) { high = value; highAt = n; }
            }
            append(at, sample(at));
            if (lowAt < highAt) { append(lowAt, low); append(highAt, high); }
            else { append(highAt, high); append(lowAt, low); }
            append(until, sample(until));
        }
        const double progress = jlimit(0., 1., (8 - std::log2(std::max(1., data->sampleRate / scale))) / 6);
        const float width = (float)(2 - progress * progress * (3 - 2 * progress));
        g.strokePath(path, PathStrokeType(width, PathStrokeType::curved, PathStrokeType::rounded));
        return true;
    }
};
}
