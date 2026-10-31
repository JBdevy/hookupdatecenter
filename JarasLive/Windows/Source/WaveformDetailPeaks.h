#pragma once
#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cmath>
#include <utility>
#include <vector>

namespace catlive {
// Prepared alongside decoder pages on the waveform worker. Intermediate zoom
// needs exact 32/48/.../256-frame intervals, not the file's 256-frame overview.
// Sixteen-frame summaries retain those intervals with 1/8 the PCM storage.
class WaveformDetailPeaks {
  public:
    static constexpr int stride = 16;
    static constexpr double maximumSamplesPerPixel = 256;
    static bool needsDetail(double samplesPerPixel) { return samplesPerPixel <= maximumSamplesPerPixel; }
    static float pixelWidth(float density) { return 1.f / std::clamp(density, 1.f, 8.f); }
    static std::pair<float, float> displayEdges(float low, float high, float middle,
                                               float amplitude, float density) {
        const float center = middle - (low + high) * .5f * amplitude;
        const float half = std::max(pixelWidth(density) * .5f, (high - low) * .5f * std::abs(amplitude));
        return {center - half, center + half};
    }
    template <class Sample> void prepare(int channels, int frames, Sample sample) {
        if (channels <= 0 || frames <= 0) { channelCount=frameCount=buckets=0; values.clear(); return; }
        channelCount = channels; frameCount = frames;
        buckets = (frames + stride - 1) / stride;
        values.resize((std::size_t)channels * buckets);
        for (int channel = 0; channel < channels; ++channel)
            for (int bucket = 0; bucket < buckets; ++bucket) {
                const int first = bucket * stride, last = std::min(frames, first + stride);
                const float initial = sample(channel, first);
                auto peak = std::pair<float,float>{initial, initial};
                for (int frame = first + 1; frame < last; ++frame) {
                    const float value = sample(channel, frame);
                    peak.first = std::min(peak.first, value); peak.second = std::max(peak.second, value);
                }
                values[(std::size_t)channel * buckets + bucket] = peak;
            }
    }
    // Both endpoints are source-aligned multiples of 16, except the true EOF.
    // No PCM access, allocation, or disk work occurs in this paint-time query.
    std::pair<float,float> alignedRange(int channel, int first, int last) const {
        first = std::max(0, first); last = std::min(frameCount, last);
        if (channelCount <= 0 || last <= first) return {};
        assert(first % stride == 0 && (last % stride == 0 || last == frameCount));
        channel = std::clamp(channel, 0, channelCount - 1);
        const int begin = first / stride, end = (last + stride - 1) / stride;
        auto result = values[(std::size_t)channel * buckets + begin];
        for (int bucket = begin + 1; bucket < end; ++bucket) {
            const auto peak = values[(std::size_t)channel * buckets + bucket];
            result.first = std::min(result.first, peak.first); result.second = std::max(result.second, peak.second);
        }
        return result;
    }
    std::size_t bytes() const { return values.size() * sizeof(values[0]); }
  private:
    int channelCount = 0, frameCount = 0, buckets = 0;
    std::vector<std::pair<float,float>> values;
};
}
