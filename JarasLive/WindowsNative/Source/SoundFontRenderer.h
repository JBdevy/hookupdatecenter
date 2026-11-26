#pragma once

#include "AudioTypes.h"

#include <cstddef>
#include <filesystem>
#include <memory>
#include <string>

namespace catlive::native {

// Units/defaults match the CatLive instrument settings stored in projects.
// The host converts project JSON into this value before sending it to audio.
struct SoundFontParameters {
    enum class VelocityCurve { soft, medium, hard };
    float gainDB = 0, controllerVolumeDB = 0;
    float attack = 0, hold = 10, decay = 10, sustain = 1, release = .3f;
    bool drums = false, monophonic = false;
    VelocityCurve velocityCurve = VelocityCurve::medium;
    bool modulationEnabled = false, pitchVibratoEnabled = false;
    float cutoff = 20000, velocityCutoffMinimum = 20000;
    float filterAttack = 0, filterHold = 0, filterDecay = .3f;
    float filterSustain = 1, filterRelease = .3f, filterDepth = 0;

    static SoundFontParameters defaults(bool drumKit = false) noexcept {
        SoundFontParameters result;
        result.drums = drumKit;
        if (drumKit) result.release = 20;
        return result;
    }
};

// Independent CatLive SF2 playback voice bank. The TinySoundFont implementation
// and its MIT notice remain in Core/ThirdParty/TinySoundFont, shared with macOS.
//
// Lifecycle operations (construct/load/clone/prepare/destroy) run on one
// serialized control/loader thread. They must not race calls on this instance.
// clone() shares an immutable bank; serialize it with source MIDI/config edits
// as well because it snapshots the selected presets and parameters.
// configure(), selectPreset(), stop(), renderAdd() and diagnostics belong to
// the one audio consumer (or control thread while stopped). The host queues
// live edits/MIDI before calling them; this class never takes a mutex.
class SoundFontRenderer final {
  public:
    explicit SoundFontRenderer(double sampleRate = 48000);
    ~SoundFontRenderer();
    SoundFontRenderer(const SoundFontRenderer&) = delete;
    SoundFontRenderer& operator=(const SoundFontRenderer&) = delete;

    // Throws on invalid/oversized/unreadable data; a failed load preserves the
    // previous bank and voices. std::filesystem retains Unicode Windows paths.
    void loadFile(const std::filesystem::path&);
    void loadMemory(const void* data, std::size_t bytes, std::string name = {});
    std::unique_ptr<SoundFontRenderer> clone() const;
    void prepare(double sampleRate);
    bool loaded() const noexcept;
    const std::string& name() const noexcept;
    int presetCount() const noexcept;
    std::string presetName(int index) const;
    double sampleRate() const noexcept;

    // No allocation/file access/locks in the following audio-thread methods.
    void configure(const SoundFontParameters&) noexcept;
    bool selectPreset(int index, int channel = 1) noexcept;
    void stop() noexcept;
    unsigned activeVoices() const noexcept;
    // Adds to existing samples. Invalid views or event order/bounds return
    // false without changing the output or instrument. No loaded bank is silent.
    bool renderAdd(StereoAudioView output, MidiEventSpan events = {}) noexcept;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};

} // namespace catlive::native
