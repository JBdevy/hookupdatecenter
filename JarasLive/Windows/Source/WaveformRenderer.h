#pragma once
#include <optional>
#include "WaveformCache.h"
#include "ClipTempo.h"
#include "../../Core/Tracks/ItemFade.hpp"
namespace catlive {
// Source-anchored min/max columns at physical-pixel resolution; real PCM
// extrema at close zoom. Connected contours keep fractional pans continuous.
struct WaveformRenderer {
    // Dense transients must keep the same pixel coverage while following the
    // transport. Fractional raster translations otherwise brighten/dim them.
    static float pixelAlignedPosition(float position, float physical) {
        return std::round(position * physical) / physical;
    }
    // ±1 PCM (0 dBFS) reaches the channel clipping border, not half that level.
    static float fullScale(float channelHeight) { return std::max(0.f, channelHeight - 1.f) * .5f; }

    static double gain(const jaras::AudioClip &clip, std::optional<double> itemGainOverride = std::nullopt) {
        const auto limit=std::pow(10.,24./20);
        return jlimit(0.,limit,itemGainOverride.value_or(clip.gain.value_or(1))) * jlimit(0.,limit,clip.normalizationGain.value_or(1)) * (clip.phaseInverted.value_or(false) ? -1 : 1);
    }
    static double panGain(double pan, int channel, int channels) {
        pan = jlimit(-1., 1., pan);
        return channels < 2 ? 1. : channel == 0 && pan > 0 ? 1. - pan : channel == 1 && pan < 0 ? 1. + pan : 1.;
    }
    struct FadeEnvelope {
        double origin, scale, duration, in, out;
        jaras::FadeCurve inCurve, outCurve;
        FadeEnvelope(const jaras::AudioClip &clip, double x, double pixelsPerSecond)
            : origin(x), scale(pixelsPerSecond), duration(clip.duration),
              in(std::min(duration, clip.fadeIn.value_or(0))), out(std::min(duration, clip.fadeOut.value_or(0))),
              inCurve(clip.fadeInCurve.value_or(0), clip.fadeInSCurve.value_or(1)),
              outCurve(clip.fadeOutCurve.value_or(0), clip.fadeOutSCurve.value_or(1)) {}
        float at(double x) const {
            if(in<=0 && out<=0)return 1.f;
            const double elapsed = (x - origin) / scale;
            return (float)((in > 0 ? inCurve.value(elapsed / in) : 1) *
                (out > 0 ? outCurve.value((duration - elapsed) / out) : 1));
        }
        bool active() const { return in > 0 || out > 0; }
    };
    static void draw(Graphics &g, WaveformCache &cache,
                     const std::shared_ptr<const WaveformCache::Data> &data,
                     const jaras::AudioClip &clip, juce::Rectangle<float> item,
                     juce::Rectangle<float> viewport, double pixelsPerSecond, Colour ink, bool clipToItem = true,
                     std::optional<double> itemGainOverride = std::nullopt, const jaras::Song *song = nullptr,
                     const ClipTempo *preparedTiming = nullptr, std::optional<double> itemPanOverride = std::nullopt) {
        if (!data || data->sourceChannels <= 0 || pixelsPerSecond <= 0) return;
        const float physical = jlimit(1.f, 8.f, g.getInternalContext().getPhysicalPixelScaleFactor());
        item.setX(pixelAlignedPosition(item.getX(), physical));
        const int mode = clip.channelMode.value_or(0);
        const int channels = (mode == 0 || mode == 4) ? data->sourceChannels : 1;
        const float top = item.getY() + 18, height = std::max(0.f, item.getBottom() - top - 2) / channels;
        if (height <= 0) return;
        std::optional<ClipTempo> localTiming;
        if(!preparedTiming)localTiming.emplace(clip,song);
        const auto &timing=preparedTiming?*preparedTiming:*localTiming;
        const double visibleStart = std::max(0., (viewport.getX() - item.getX()) / pixelsPerSecond);
        const double visibleEnd = std::min(clip.duration, (viewport.getRight() - item.getX()) / pixelsPerSecond);
        if (visibleEnd <= visibleStart) return;
        const double loop = clip.loopLength.value_or(0), loopStart = clip.loopStart.value_or(0);
        const float baseAmplitude = fullScale(height) * (float)gain(clip,itemGainOverride);
        const FadeEnvelope fade(clip, item.getX(), pixelsPerSecond);
        g.saveState();
        if (clipToItem) {Path outline;outline.addRoundedRectangle(item,3);g.reduceClipRegion(outline);}
        g.setColour(ink);
        for (int channel = 0; channel < channels; ++channel) {
            const float amplitude = baseAmplitude * (float)panGain(itemPanOverride.value_or(clip.pan.value_or(0)), channel, channels);
            const int sourceChannel = mode == 1 ? 0 : mode == 2 ? std::min(1, data->sourceChannels - 1)
                : mode == 3 && data->sourceChannels > 1 ? data->sourceChannels
                : mode == 4 && data->sourceChannels > 1 && channel < 2 ? 1 - channel : channel;
            const float middle = top + height * (channel + .5f);
            auto lane = juce::Rectangle<float>(item.getX(), top + channel * height + .5f, item.getWidth(), std::max(0.f, height - 1)).getIntersection(viewport);
            if (lane.isEmpty()) continue;
            g.saveState();
            Path laneClip; laneClip.addRectangle(lane); g.reduceClipRegion(laneClip);
            double position = visibleStart;
            while (position < visibleEnd) {
                const auto *span=timing.at(clip.startTime+position);
                const double rate=std::max(.001,span?span->rate:clip.playbackRate), sourceScale=pixelsPerSecond/rate;
                const auto step=WaveformCache::step(data->sampleRate,sourceScale*physical/2.0);
                const double raw=timing.sourceAt(clip.startTime+position);
                const double source=loop>0 && raw>=loopStart ? loopStart+std::fmod(raw-loopStart,loop) : raw;
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
                const double untilTempo=span?span->end-clip.startTime-position:visibleEnd-position;
                const double end = std::min({visibleEnd, position + untilLoop,position+std::max(1e-9,untilTempo)});
                const double sourceEnd = std::min(data->duration, source + (end - position) * rate);
                if (sourceEnd > source) {
                    const double x = item.getX() + position * pixelsPerSecond;
                    const auto segment = juce::Rectangle<float>((float)x, lane.getY(), (float)((end - position) * pixelsPerSecond), lane.getHeight()).getIntersection(lane);
                    const bool cropped=segment!=lane;
                    if(cropped) {g.saveState();Path clipPath;clipPath.addRectangle(segment);g.reduceClipRegion(clipPath);}
                    // Reading every PCM sample is useful only at close zoom.
                    // At overview zoom the cached extrema retain transients
                    // while keeping continuous-scroll work bounded by pixels.
                    bool detailed = false;
                    if (data->sampleRate / (sourceScale * physical) <= 32) detailed = drawDetail(g, cache, data, sourceChannel, source, sourceEnd, sourceScale, x, middle, amplitude, step, fade);
                    if (!detailed) drawEnvelope(g, *data, sourceChannel, source, sourceEnd, sourceScale, x, middle, amplitude, physical, fade);
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
        double start, double end, double scale, double x, float middle, float amplitude, float physical, const FadeEnvelope &fade) {
        // Anchor intervals to the source, not the visible crop: panning cannot
        // repartition a transient or change its height. One column per device
        // pixel bounds work by the visible width, including fractional DPI.
        const double secondsPerColumn = 1.0 / (scale * physical);
        const int64 first = std::max<int64>(0, (int64)std::floor(start / secondsPerColumn) - 1);
        const int64 last = std::min<int64>((int64)std::ceil(data.duration / secondsPerColumn) - 1,
                                          (int64)std::ceil(end / secondsPerColumn) + 1);
        if (last < first) return;
        struct Edge { float x, upper, lower; };
        std::vector<Edge> edges; edges.reserve((size_t)(last - first + 3));
        for (int64 column = first; column <= last; ++column) {
            const double a = column * secondsPerColumn, b = std::min(data.duration, (column + 1) * secondsPerColumn);
            const auto peak = data.rangeFrames(channel, (int64)std::floor(a * data.sampleRate),
                std::min(data.frames, (int64)std::ceil(b * data.sampleRate) + 1));
            const auto edgeAt = [&](double time) {
                const float px = (float)(x + (time - start) * scale), level = amplitude * fade.at(px);
                const float center = middle - (peak.first + peak.second) * .5f * level;
                const float half = std::max(.5f / physical, (peak.second - peak.first) * .5f * std::abs(level));
                return Edge{px, center-half, center+half};
            };
            if (column == first) edges.push_back(edgeAt(a));
            edges.push_back(edgeAt((a+b)*.5));
            if (column == last) edges.push_back(edgeAt(b));
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
        // Multiple samples per pixel need an extrema envelope, not a rounded
        // stroke through every local turn. The latter expands thousands of
        // joins on the software renderer and stalls all message-thread meters.
        // Retain exact PCM extrema and source-anchored buckets at this zoom.
        if (step > 1) {
            struct Edge { float x, upper, lower; };
            std::vector<Edge> edges;
            edges.reserve((size_t)((last-first)/step+3));
            for (int64 at=first;at<=last;at+=step) {
                const int64 until=std::min({last,at+step-1,data->frames-1});
                float low=std::numeric_limits<float>::max(),high=-low;
                for(int64 frame=at;frame<=until;++frame) {
                    const auto &page=*pages.at(frame/WaveformCache::Detail::pageFrames);
                    const float value=page.sample(channel,frame);
                    low=std::min(low,value);high=std::max(high,value);
                }
                const auto edge=[&](double frame) {
                    const float px=(float)(x+(frame/data->sampleRate-start)*scale);
                    const float level=amplitude*fade.at(px);
                    const float a=middle-low*level,b=middle-high*level;
                    edges.push_back({px,std::min(a,b),std::max(a,b)});
                };
                if(at==first)edge((double)at);
                edge(((double)at+until)*.5);
                if(until==last)edge((double)until);
            }
            if(!edges.empty()) {
                Path envelope;envelope.preallocateSpace((int)edges.size()*6);
                envelope.startNewSubPath(edges.front().x,edges.front().upper);
                for(size_t i=1;i<edges.size();++i)envelope.lineTo(edges[i].x,edges[i].upper);
                for(auto i=edges.rbegin();i!=edges.rend();++i)envelope.lineTo(i->x,i->lower);
                envelope.closeSubPath();g.fillPath(envelope);
            }
            return true;
        }
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
