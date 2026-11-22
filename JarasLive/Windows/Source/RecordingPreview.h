#pragma once
#include "Common.h"
namespace catlive {
// One producer publishes immutable events. Both the live display and final take
// read the same bounded recording, without locking or consuming one another's data.
struct RecordedMIDIEvents {
    struct Event { int target = 0, length = 0; int64 frame = 0; std::array<uint8, 3> bytes{}; };
    std::array<Event, 65536> values{};
    std::atomic<unsigned> published{0};
    bool append(const Event &event) noexcept {
        const auto i = published.load(std::memory_order_relaxed);
        if (i == values.size()) return false;
        values[i] = event;
        published.store(i + 1, std::memory_order_release);
        return true;
    }
};
class RecordedMIDINotes {
  public:
    struct Note { int pitch, channel, velocity; int64 start, end; };
    std::vector<Note> notes;
    int low = 127, high = 0;
    void read(const RecordedMIDIEvents &log, int target) {
        const auto count = log.published.load(std::memory_order_acquire);
        for (; cursor < count; ++cursor) {
            const auto &event = log.values[cursor];
            if (event.target != target) continue;
            MidiMessage msg(event.bytes.data(), event.length);
            const int channel = msg.getChannel() - 1;
            if (msg.isNoteOnOrOff()) {
                const int pitch = msg.getNoteNumber(), key = channel * 128 + pitch;
                if (msg.isNoteOn()) {
                    release(key, event.frame);
                    held[key] = {notes.size(), false};
                    notes.push_back({pitch, channel+1, msg.getVelocity(), event.frame, -1});
                    low = std::min(low, pitch); high = std::max(high, pitch);
                } else if (auto it = held.find(key); it != held.end()) {
                    if (sustain[channel]) it->second.released = true;
                    else release(key, event.frame);
                }
            } else if (msg.isController()) {
                const bool pedal = msg.getControllerNumber() == 64;
                if (pedal) sustain[channel] = msg.getControllerValue() >= 64;
                if ((pedal && !sustain[channel]) || msg.isAllNotesOff() || msg.isAllSoundOff())
                    for (int key = channel * 128; key < (channel + 1) * 128; ++key) {
                        const auto it = held.find(key);
                        if (it != held.end() && (!pedal || it->second.released)) release(key, event.frame);
                    }
            }
        }
    }
  private:
    unsigned cursor = 0;
    struct Held { size_t index; bool released; };
    std::map<int,Held> held;
    std::array<bool,16> sustain{};
    void release(int key, int64 frame) {
        if (const auto it = held.find(key); it != held.end()) {
            notes[it->second.index].end = frame;
            held.erase(it);
        }
    }
};
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
    std::shared_ptr<const RecordedMIDIEvents> midiLog;
    int midiTarget = -1;
    RecordedMIDINotes midi;
    bool drain() {
        if (midiLog) midi.read(*midiLog, midiTarget);
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
