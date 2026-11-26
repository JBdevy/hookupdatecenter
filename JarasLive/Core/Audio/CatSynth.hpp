#pragma once

#include "RealtimeLatestValue.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>

namespace jaras::audio {

class CatSynth {
public:
    enum Parameter : unsigned {
        wave1, level1, tune1, fine1, wave2, level2, tune2, fine2, wave3, level3, tune3, fine3,
        noise, cutoff, resonance, filterMode, drive, envelopeAmount,
        attack, decay, sustain, release, filterAttack, filterDecay, filterSustain, filterRelease,
        lfoWave, lfoRate, lfoPitch, lfoFilter, glide, spread, volume, mono, parameterCount
    };
    using Patch = std::array<float, parameterCount>;
    static constexpr unsigned presetCount = 8;
    inline static constexpr std::array<const char*, presetCount> names{
        "Violet Lead", "Sub Orbit", "Nebula Pad", "Laser Pluck",
        "Glass Keys", "Deep Motion", "Air Choir", "Pulse Engine"
    };

    static constexpr Patch factory(unsigned index) noexcept {
        Patch p{2,.65f,0,0, 1,.32f,0,9, 3,.16f,-12,0, .01f,2700,.22f,0,.2f,.4f,
            .008f,.32f,.72f,.22f, .011f,.28f,.4f,.24f, 0,4.7f,.05f,.06f,.035f,.36f,.68f,0};
        switch (index) {
        case 1:
            p[wave1]=3; p[wave2]=2; p[tune2]=-12; p[wave3]=0; p[tune3]=-12; p[level3]=.63f;
            p[cutoff]=510; p[resonance]=.45f; p[drive]=.6f; p[mono]=1; break;
        case 2:
            p[wave1]=2; p[wave2]=2; p[fine2]=17; p[wave3]=1; p[tune3]=12; p[attack]=.65f;
            p[release]=1.45f; p[filterAttack]=.8f; p[lfoRate]=.24f; p[lfoFilter]=.27f; p[spread]=.85f; break;
        case 3:
            p[wave1]=4; p[wave2]=2; p[tune2]=12; p[wave3]=0; p[cutoff]=640; p[envelopeAmount]=.86f;
            p[decay]=.15f; p[sustain]=.08f; p[filterDecay]=.12f; p[filterSustain]=0; break;
        case 4:
            p[wave1]=1; p[wave2]=0; p[tune2]=12; p[wave3]=0; p[tune3]=19; p[level3]=.22f;
            p[cutoff]=4800; p[resonance]=.15f; p[decay]=.53f; p[sustain]=.31f; p[release]=.55f; break;
        case 5:
            p[wave1]=2; p[wave2]=3; p[wave3]=0; p[tune3]=-12; p[cutoff]=850; p[resonance]=.57f;
            p[lfoWave]=1; p[lfoRate]=1.15f; p[lfoFilter]=.68f; p[glide]=.11f; break;
        case 6:
            p[wave1]=1; p[wave2]=2; p[wave3]=2; p[fine2]=-13; p[fine3]=16; p[noise]=.13f; p[cutoff]=1950;
            p[filterMode]=1; p[attack]=.48f; p[release]=1.1f; p[lfoRate]=.52f; p[lfoPitch]=.13f; p[spread]=.76f; break;
        case 7:
            p[wave1]=3; p[wave2]=4; p[tune2]=7; p[wave3]=2; p[tune3]=-12; p[cutoff]=1700;
            p[resonance]=.66f; p[filterDecay]=.2f; p[lfoWave]=2; p[lfoRate]=2.5f; p[lfoFilter]=.28f; break;
        default: break;
        }
        return p;
    }

    explicit CatSynth(double rate) : rate_(std::clamp(rate, 8000., 192000.)) {}
    void configure(Patch patch) noexcept {
        constexpr Patch minimum{0,0,-24,-100, 0,0,-24,-100, 0,0,-24,-100, 0,20,0,0,0,-1,
            .001f,.005f,0,.006f, .001f,.005f,0,.006f, 0,.05f,0,0,0,0,0,0};
        constexpr Patch maximum{4,1,24,100, 4,1,24,100, 4,1,24,100, 1,18000,.98f,2,1,1,
            4,4,1,8, 4,4,1,8, 2,16,2,1,.8f,1,1,1};
        constexpr auto fallback = factory(0);
        for (unsigned i = 0; i < patch.size(); ++i)
            patch[i] = std::clamp(std::isfinite(patch[i]) ? patch[i] : fallback[i], minimum[i], maximum[i]);
        changes_.publish(patch);
    }
    void setEnabled(bool enabled) noexcept {
        if (enabled_.exchange(enabled, std::memory_order_relaxed) != enabled) reset_.store(true);
    }
    bool enabled() const noexcept { return enabled_.load(std::memory_order_relaxed); }
    void send(unsigned status, unsigned key, unsigned value) noexcept {
        if (!enabled()) return;
        const auto end = written_.load(std::memory_order_relaxed);
        if (end - read_.load(std::memory_order_acquire) >= messages_.size()) { reset_.store(true); return; }
        messages_[end % messages_.size()] = {std::uint8_t(status),std::uint8_t(key),std::uint8_t(value)};
        written_.store(end + 1, std::memory_order_release);
    }
    void screenKey(unsigned key, unsigned velocity) noexcept {
        if (key >= screen_.size()) return;
        auto& keyState = screen_[key];
        const auto previous = keyState.load(std::memory_order_relaxed);
        if (velocity) {
            keyState.store(((previous & ~0xffu) + 0x100u) | 0x80u | std::min(127u, velocity), std::memory_order_relaxed);
        } else {
            keyState.store(previous & ~0x80u, std::memory_order_relaxed);
        }
    }
    bool keyIsActive(unsigned key) const noexcept {
        return key < held_.size() && held_[key].load(std::memory_order_relaxed) != 0;
    }
    bool screenVoiceIsActive() const noexcept { return screenVoiceActive_.load(std::memory_order_relaxed); }
    void publishScreenVoiceActivity() noexcept {
        screenVoiceActive_.store(enabled() && std::any_of(voices_.begin(), voices_.end(),
            [](const auto& voice) { return voice.active && voice.channel == screenChannel; }),
            std::memory_order_relaxed);
    }
    void silence() noexcept { reset_.store(true, std::memory_order_release); }

    // The automation and event paths have a bounded lock-free handoff. Only
    // this audio thread owns voice phases, envelopes and filter history.
    void beginBlock() noexcept {
        Patch update;
        if (changes_.consume(update)) {
            const bool wasMono = patch_[mono] >= .5f;
            patch_ = update;
            if (wasMono != (patch_[mono] >= .5f)) reset_.store(true);
            for (unsigned i = 0; i < 3; ++i)
                ratios_[i] = std::exp2((patch_[i*4+2] + patch_[i*4+3] / 100.f) / 12.f);
        }
        const auto shouldReset = reset_.exchange(false);
        if (shouldReset) {
            for (auto& voice : voices_) voice = {};
            for (auto& key : held_) key.store(0, std::memory_order_relaxed);
            monoKeys_.fill({});
            pedals_.fill(false);
            for (auto& key : screenKeys_) {
                key.sounding = false;
                key.minimumUntil = 0;
            }
            lastNoteHz_ = 0; pitchBend_ = 0; modWheel_ = 0;
        }
        auto cursor = read_.load(std::memory_order_relaxed);
        const auto end = written_.load(std::memory_order_acquire);
        for (; cursor != end; ++cursor) {
            const auto event = messages_[cursor % messages_.size()];
            midi(event.status,event.key,event.value);
        }
        read_.store(cursor, std::memory_order_release);
        if (!enabled()) return;
        for (unsigned i = 0; i < 128; ++i) {
            const auto value = screen_[i].load(std::memory_order_relaxed);
            auto& key = screenKeys_[i];
            const bool pressed = (value & 0x80u) != 0;
            const auto press = value >> 8;
            // A short mouse click can arrive entirely between two render
            // callbacks. Preserve the attack and give it time to sound.
            if (press != key.press || (pressed && !key.sounding)) {
                if (key.sounding) noteOff(screenChannel, i);
                key = {press, renderedFrames_ + std::uint64_t(rate_ * .012), true};
                noteOn(screenChannel, i, value & 0x7fu);
            } else if (key.sounding && !pressed && renderedFrames_ >= key.minimumUntil) {
                noteOff(screenChannel, i);
                key.sounding = false;
            }
        }
    }

    void midi(unsigned status, unsigned key, unsigned value, bool sequenced = false) noexcept {
        if (!enabled() || key > 127 || value > 127) return;
        const auto channel = (status & 15) + (sequenced ? 16u : 0u);
        const auto type = status & 0xf0;
        if (type == 0x90 && value) noteOn(channel, key, value);
        else if (type == 0x80 || type == 0x90) noteOff(channel, key);
        else if (type == 0xe0) pitchBend_ = (int(key | (value << 7)) - 8192) / 4096.f;
        else if (type == 0xb0) {
            if (key == 1) modWheel_ = float(value) / 127.f;
            else if (key == 64) setPedal(channel, value >= 64);
            else if (key == 120 || key == 123) clearChannel(channel, key == 120);
        }
    }

    void render(float* left, float* right, unsigned frames) noexcept {
        if (!enabled() || !left) return;
        renderedFrames_ += frames;
        const float rate = float(rate_);
        const float glideAmount = patch_[glide] > .001f ? 1.f / (1.f + patch_[glide] * rate * .25f) : 1.f;
        const float lfoStep = patch_[lfoRate] / rate;
        const float basePitch = std::exp2(pitchBend_ / 12.f);
        const float damping = 2.f - 1.88f * patch_[resonance];
        const float distortion = 1.f + 4.f * patch_[drive], output = patch_[volume] * .32f;
        const float levelSum = std::max(1.f, patch_[level1] + patch_[level2] + patch_[level3] + patch_[noise]);
        const float mode = patch_[filterMode];
        for (unsigned n = 0; n < frames; ++n) {
            float mixedL = 0, mixedR = 0;
            const float lfo = wave(lfoPhase_, lfoStep, unsigned(patch_[lfoWave] == 2 ? 3 : patch_[lfoWave]));
            lfoPhase_ = advance(lfoPhase_, lfoStep);
            const float vibrato = basePitch * std::exp2(lfo * (patch_[lfoPitch] + modWheel_ * .7f) / 12.f);
            for (auto& voice : voices_) {
                if (!voice.active) continue;
                const float gain = voice.amp.next(patch_[attack], patch_[decay], patch_[sustain], patch_[release], rate);
                const float env = voice.filter.next(patch_[filterAttack],patch_[filterDecay],patch_[filterSustain],patch_[filterRelease],rate);
                if (voice.amp.stage == Envelope::done) { voice.active = false; continue; }
                voice.hz += (voice.target - voice.hz) * glideAmount;
                float raw = 0;
                for (unsigned i = 0; i < 3; ++i) {
                    const auto step = std::min(.49f, voice.hz * vibrato * ratios_[i] / rate);
                    raw += patch_[i * 4 + 1] * wave(voice.phase[i], step, unsigned(patch_[i * 4]));
                    voice.phase[i] = advance(voice.phase[i], step);
                }
                noiseSeed_ ^= noiseSeed_ << 13; noiseSeed_ ^= noiseSeed_ >> 17; noiseSeed_ ^= noiseSeed_ << 5;
                raw += (float(noiseSeed_ >> 8) / 8388608.f - 1.f) * patch_[noise];
                raw = saturate(raw * distortion / levelSum);
                const float hz = std::clamp(patch_[cutoff] * std::exp2(4.f * env * patch_[envelopeAmount] + 2.f * lfo * patch_[lfoFilter]), 20.f, rate * .41f);
                const float angle = 3.14159265f * hz / rate;
                const float g = std::tan(angle);
                const float h = 1.f / (1.f + g * (g + damping));
                const float band = h * (voice.integrator1 + g * (raw - voice.integrator2));
                const float low = voice.integrator2 + g * band;
                voice.integrator1 = 2 * band - voice.integrator1;
                voice.integrator2 = 2 * low - voice.integrator2;
                const float filtered = mode >= 1.5f ? raw - damping * band - low : mode >= .5f ? band : low;
                const float signal = filtered * gain * voice.velocity;
                const float pan = voice.pan * patch_[spread];
                mixedL += signal * (1.f - std::max(0.f, pan));
                mixedR += signal * (1.f + std::min(0.f, pan));
            }
            left[n] += saturate(mixedL * output);
            if (right) right[n] += saturate(mixedR * output);
        }
    }

private:
    struct Event { std::uint8_t status, key, value; };
    struct Envelope {
        enum Stage { rising, falling, held, releasing, done } stage = rising;
        float level = 0, releaseStart = 0;
        void end() noexcept { if (stage < releasing) { releaseStart = level; stage = releasing; } }
        float next(float attack, float decay, float sustain, float release, float rate) noexcept {
            switch (stage) {
            case rising: level += 1.f / std::max(1.f, attack * rate);
                if (level >= 1.f) { level = 1.f; stage = falling; } break;
            case falling: level -= (1.f - sustain) / std::max(1.f, decay * rate);
                if (level <= sustain) { level = sustain; stage = held; } break;
            case held: level = sustain; break;
            case releasing: level -= releaseStart / std::max(1.f, release * rate);
                if (level <= .00001f) { level = 0; stage = done; } break;
            case done: break;
            }
            return level;
        }
    };
    struct Voice {
        bool active = false, keyDown = false;
        unsigned key = 0, channel = 0;
        std::uint64_t order = 0;
        float hz = 0, target = 0, velocity = 0, pan = 0, integrator1 = 0, integrator2 = 0;
        std::array<float,3> phase{};
        Envelope amp, filter;
    };
    static constexpr unsigned screenChannel = 32;
    struct MonoKey { unsigned channel = 0, key = 0, velocity = 0; std::uint64_t order = 0; };
    double rate_;
    Patch patch_ = factory(0);
    std::array<float,3> ratios_{1.f,1.00521f,.5f};
    std::array<Voice, 16> voices_{};
    std::array<MonoKey, 128> monoKeys_{};
    std::array<bool, screenChannel + 1> pedals_{};
    // The editor is the sole writer. Pack the press serial, down flag and
    // velocity into one atomic so the render thread observes a coherent event.
    std::array<std::atomic<std::uint32_t>,128> screen_{};
    struct ScreenKey { std::uint32_t press = 0; std::uint64_t minimumUntil = 0; bool sounding = false; };
    std::array<ScreenKey,128> screenKeys_{};
    std::array<std::atomic<std::uint8_t>,128> held_{};
    std::uint64_t renderedFrames_ = 0;
    std::atomic<bool> enabled_{true}, reset_{false};
    std::atomic<bool> screenVoiceActive_{false};
    catlive::audio::RealtimeLatestValue<Patch> changes_;
    std::array<Event, 256> messages_{};
    std::atomic<std::uint32_t> read_{0}, written_{0};
    std::uint64_t order_ = 0;
    std::uint32_t noiseSeed_ = 44579;
    float lastNoteHz_ = 0, lfoPhase_ = 0, modWheel_ = 0, pitchBend_ = 0;

    void noteOn(unsigned channel, unsigned key, unsigned value) noexcept {
        if (patch_[mono] >= .5f) {
            auto* slot = &monoKeys_.front();
            for (auto& entry : monoKeys_) {
                if (entry.velocity && entry.channel == channel && entry.key == key) { slot = &entry; break; }
                if (!entry.velocity || (slot->velocity && entry.order < slot->order)) slot = &entry;
            }
            *slot = {channel, key, value, ++order_};
            startVoice(voices_.front(), channel, key, value, true);
            return;
        }
        auto* voice = &voices_.front();
        for (auto& entry : voices_) {
            if (!entry.active) { voice = &entry; break; }
            if (entry.keyDown != voice->keyDown ? !entry.keyDown : entry.order < voice->order) voice = &entry;
        }
        startVoice(*voice, channel, key, value, false);
    }
    void startVoice(Voice& voice, unsigned channel, unsigned key, unsigned value, bool monophonic) noexcept {
        const bool legato = monophonic && voice.active && voice.amp.stage < Envelope::releasing;
        if (voice.keyDown) decrement(voice.key);
        const auto frequency = 440.f * std::exp2((int(key) - 69) / 12.f);
        if (!legato) {
            voice = {};
            voice.hz = lastNoteHz_ > 0 && monophonic ? lastNoteHz_ : frequency;
        }
        voice.active = true; voice.keyDown = true;
        voice.channel = channel; voice.key = key; voice.order = ++order_;
        voice.target = frequency; voice.velocity = float(value) / 127.f;
        voice.pan = monophonic ? 0 : (float((key * 17) % 19) / 9.f - 1.f) * .87f;
        lastNoteHz_ = frequency;
        held_[key].fetch_add(1, std::memory_order_relaxed);
    }
    void noteOff(unsigned channel, unsigned key) noexcept {
        if (patch_[mono] >= .5f) {
            for (auto& entry : monoKeys_)
                if (entry.channel == channel && entry.key == key) entry = {};
            auto& voice = voices_.front();
            if (voice.keyDown && voice.channel == channel && voice.key == key) resumeMono(voice);
            return;
        }
        Voice* first = nullptr;
        for (auto& voice : voices_)
            if (voice.keyDown && voice.channel == channel && voice.key == key &&
                (!first || voice.order < first->order)) first = &voice;
        if (first) liftKey(*first);
    }
    void resumeMono(Voice& voice) noexcept {
        const auto last = std::max_element(monoKeys_.begin(), monoKeys_.end(),
            [](const MonoKey& a, const MonoKey& b) { return a.order < b.order; });
        if (last->velocity) startVoice(voice, last->channel, last->key, last->velocity, true);
        else if (voice.keyDown) liftKey(voice);
    }
    void liftKey(Voice& voice) noexcept {
        decrement(voice.key);
        voice.keyDown = false;
        if (!pedals_[voice.channel]) releaseVoice(voice);
    }
    void releaseVoice(Voice& voice) noexcept {
        voice.amp.end();
        voice.filter.end();
    }
    void setPedal(unsigned channel, bool down) noexcept {
        pedals_[channel] = down;
        if (!down)
            for (auto& voice : voices_)
                if (voice.active && voice.channel == channel && !voice.keyDown) releaseVoice(voice);
    }
    void clearChannel(unsigned channel, bool immediately) noexcept {
        if (immediately) setPedal(channel, false);
        if (patch_[mono] >= .5f) {
            for (auto& entry : monoKeys_) if (entry.channel == channel) entry = {};
            auto& voice = voices_.front();
            if (voice.active && voice.channel == channel) {
                if (immediately && voice.keyDown) { decrement(voice.key); voice.keyDown = false; }
                if (immediately) voice.active = false;
                resumeMono(voice);
            }
            return;
        }
        for (auto& voice : voices_) {
            if (voice.channel != channel || !voice.active) continue;
            if (voice.keyDown) liftKey(voice);
            if (immediately) voice = {};
        }
    }
    void decrement(unsigned key) noexcept {
        if (held_[key].load(std::memory_order_relaxed)) held_[key].fetch_sub(1, std::memory_order_relaxed);
    }
    static float advance(float phase, float step) noexcept {
        phase += step;
        return phase >= 1.f ? phase - 1.f : phase;
    }
    static float blep(float phase, float step) noexcept {
        if (phase < step) { const auto x = phase / step; return 2*x - x*x - 1; }
        if (phase > 1.f-step) { const auto x = (phase - 1.f) / step; return x*x + 2*x + 1; }
        return 0;
    }
    static float wave(float phase, float step, unsigned shape) noexcept {
        if (shape == 0) return std::sin(phase * 6.2831853f);
        if (shape == 1) return 1.f - 4.f * std::abs(phase - .5f);
        if (shape == 2) return 2.f*phase - 1.f - blep(phase,step);
        const float pulse = shape == 3 ? .5f : .25f;
        const float shifted = phase < pulse ? phase + 1.f - pulse : phase - pulse;
        return (phase < pulse ? 1.f : -1.f) + blep(phase,step) - blep(shifted,step);
    }
    static float saturate(float x) noexcept {
        // Smooth bounded output without an expensive sample-rate tanh call.
        return x / (1.f + std::abs(x));
    }
};

} // namespace jaras::audio
