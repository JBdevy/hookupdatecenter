#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <vector>

namespace jaras::audio {
struct DrumSample {
    double rate = 48000;
    std::vector<float> left, right;
};

// One render thread per rack. PCM is immutable after publication. Retired PCM
// is released by the control thread; rendering never allocates or takes a lock.
class DrummerPad {
public:
    static constexpr unsigned capacity = 48;
    explicit DrummerPad(unsigned size, double rate) : count(std::min(size, capacity)), outputRate(rate) {
        for (unsigned i = 0; i < count; ++i) pads[i].note = int(36 + i);
    }
    void setSample(unsigned i, std::shared_ptr<const DrumSample> sample) {
        if (i >= count) return;
        auto &pad = pads[i];
        if (pad.owner == sample) return;
        if (pad.owner) retired.push_back(std::move(pad.owner));
        pad.owner = std::move(sample);
        pad.data.store(pad.owner.get());
        pad.generation.fetch_add(1);
        if (!reading.load()) retired.clear();
    }
    void controls(unsigned i, int note, float gain) {
        if (i >= count) return;
        pads[i].note.store(note);
        pads[i].gain.store(std::clamp(gain, 0.f, 1.f));
    }
    void setMaster(float gain) { master.store(std::clamp(gain, 0.f, 1.f)); }
    void hit(unsigned i, unsigned velocity) {
        if (i < count && velocity) pads[i].pending.store(std::min(127u, velocity));
    }
    void midi(unsigned note, unsigned velocity) {
        if (!velocity) return;
        for (unsigned i = 0; i < count; ++i) if (pads[i].note.load() == int(note)) hit(i, velocity);
    }
    void silence() { stopping.store(true); }
    uint64_t flashes() { return lit.exchange(0); }
    void render(float *left, float *right, unsigned frames) {
        reading.store(true);
        const auto masterGain = master.load();
        const bool stop = stopping.exchange(false);
        for (unsigned i = 0; i < count; ++i) {
            auto &p = pads[i];
            const auto generation = p.generation.load();
            const auto *sample = p.data.load();
            if (stop || p.lastGeneration != generation) {
                p.voices = {}; p.lastGeneration = generation;
            }
            const unsigned velocity = p.pending.exchange(0);
            if (velocity && !stop) {
                lit.fetch_or(uint64_t(1) << i);
                p.voices[p.nextVoice++ % p.voices.size()] = {0., float(velocity) / 127.f};
            }
            if (!sample || sample->left.empty()) continue;
            const double step = sample->rate / outputRate;
            const auto gain = masterGain * p.gain.load();
            const bool stereo = sample->right.size() == sample->left.size();
            for (auto &v : p.voices) {
                if (!v.velocity) continue;
                for (unsigned n = 0; n < frames; ++n) {
                    const auto index = size_t(v.position);
                    if (index >= sample->left.size()) { v.velocity = 0; break; }
                    const auto next = std::min(index + 1, sample->left.size() - 1);
                    const float fraction = float(v.position - double(index));
                    const auto interpolate = [&](const std::vector<float> &pcm) {
                        return (pcm[index] + (pcm[next] - pcm[index]) * fraction) * gain * v.velocity;
                    };
                    left[n] += interpolate(sample->left);
                    if (right) right[n] += interpolate(stereo ? sample->right : sample->left);
                    v.position += step;
                }
            }
        }
        reading.store(false);
    }
private:
    struct Voice { double position{}; float velocity{}; };
    struct Pad {
        std::shared_ptr<const DrumSample> owner;
        std::atomic<const DrumSample *> data{nullptr};
        std::atomic<unsigned> generation{0}, pending{0};
        std::atomic<int> note{-1};
        std::atomic<float> gain{1};
        unsigned nextVoice{}, lastGeneration{};
        std::array<Voice, 4> voices{};
    };
    unsigned count;
    double outputRate;
    std::array<Pad, capacity> pads;
    std::vector<std::shared_ptr<const DrumSample>> retired;
    std::atomic<bool> reading{false}, stopping{false};
    std::atomic<float> master{1};
    std::atomic<uint64_t> lit{0};
};
}
