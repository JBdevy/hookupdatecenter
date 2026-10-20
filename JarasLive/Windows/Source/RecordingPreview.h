#pragma once
#include "Common.h"
namespace catlive {
// One audio producer, one UI consumer. The callback only aggregates samples
// into a bounded FIFO; allocation and display-history compaction stay on UI.
class RecordingPreview final {
  public:
    struct Peak { int64 start = 0, end = 0; std::array<float, 2> low{}, high{}; };
    RecordingPreview(double sampleRate, int channelCount)
        : rate(sampleRate), channels(jlimit(1, 2, channelCount)), bucketFrames(std::max(1, (int)(sampleRate / 50))), untilFlush(bucketFrames) {}
    const double rate;
    const int channels;
    std::atomic<int64> frames{0};
    std::vector<Peak> history; // UI thread only
    void append(const float *const *input, int count) noexcept {
        for (int i = 0; i < count; ++i) {
            for (int ch = 0; ch < channels; ++ch) {
                const float value = std::isfinite(input[ch][i]) ? input[ch][i] : 0.f;
                pending.low[(size_t)ch] = std::min(pending.low[(size_t)ch], value);
                pending.high[(size_t)ch] = std::max(pending.high[(size_t)ch], value);
            }
            ++pending.end;
            if (--untilFlush == 0) { flush(); untilFlush = bucketFrames; }
        }
    }
    void flush() noexcept {
        if (pending.end == pending.start) return;
        int a, n, b, m; fifo.prepareToWrite(1, a, n, b, m);
        if (!n) return; // Coalesce visual peaks if the UI is temporarily busy.
        queue[(size_t)a] = pending; fifo.finishedWrite(1);
        const auto end = pending.end; pending = {}; pending.start = pending.end = end;
    }
    bool drain() {
        int a, n, b, m; fifo.prepareToRead(fifo.getNumReady(), a, n, b, m);
        for (int i = 0; i < n; ++i) history.push_back(queue[(size_t)(a + i)]);
        for (int i = 0; i < m; ++i) history.push_back(queue[(size_t)(b + i)]);
        fifo.finishedRead(n + m);
        if (history.size() > 65536) {
            size_t out = 0;
            for (size_t i = 0; i < history.size(); i += 2) {
                auto peak = history[i];
                if (i + 1 < history.size()) {
                    peak.end = history[i + 1].end;
                    for (int ch = 0; ch < 2; ++ch) {
                        peak.low[ch] = std::min(peak.low[ch], history[i + 1].low[ch]);
                        peak.high[ch] = std::max(peak.high[ch], history[i + 1].high[ch]);
                    }
                }
                history[out++] = peak;
            }
            history.resize(out);
        }
        return n + m != 0;
    }
  private:
    AbstractFifo fifo{2048};
    std::array<Peak, 2048> queue{};
    Peak pending;
    const int bucketFrames;
    int untilFlush;
};
}
