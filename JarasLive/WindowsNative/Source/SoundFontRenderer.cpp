#include "SoundFontRenderer.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <utility>
#include <vector>

// The headless test can account for C allocations inside the synthesizer too.
#if defined(CATLIVE_SOUNDFONT_TEST_ALLOCATOR)
extern "C" void* catliveSoundFontAllocate(std::size_t);
extern "C" void* catliveSoundFontReallocate(void*, std::size_t);
extern "C" void catliveSoundFontFree(void*);
#define TSF_MALLOC catliveSoundFontAllocate
#define TSF_REALLOC catliveSoundFontReallocate
#define TSF_FREE catliveSoundFontFree
#endif
#define TSF_IMPLEMENTATION
#include "../../Core/ThirdParty/TinySoundFont/tsf.h"

namespace catlive::native {
namespace {
constexpr std::size_t maximumBankBytes = 512ULL * 1024 * 1024;
constexpr int maximumVoices = 128;
constexpr double pi = 3.14159265358979323846;

struct FontDeleter {
    void operator()(tsf* font) const noexcept { if (font) tsf_close(font); }
};
using Font = std::unique_ptr<tsf, FontDeleter>;

// Only the loader accesses this TSF instance. Renderers copy it, sharing
// immutable presets/samples but never channels, envelopes or playback voices.
struct Bank {
    Font source;
    std::string name;
};

float finiteClamp(float value, float low, float high, float fallback) noexcept {
    return std::isfinite(value) ? std::clamp(value, low, high) : fallback;
}

SoundFontParameters normalized(SoundFontParameters p) noexcept {
    p.gainDB = finiteClamp(p.gainDB, -24, 12, 0);
    p.controllerVolumeDB = finiteClamp(p.controllerVolumeDB, -96, 0, 0);
    p.attack = finiteClamp(p.attack, 0, 10, 0);
    p.hold = finiteClamp(p.hold, 0, 10, 10);
    p.decay = finiteClamp(p.decay, .001f, 10, 10);
    p.sustain = finiteClamp(p.sustain, 0, 1, 1);
    p.release = finiteClamp(p.release, .001f, 20, p.drums ? 20.f : .3f);
    p.cutoff = finiteClamp(p.cutoff, 20, 20000, 20000);
    p.velocityCutoffMinimum = finiteClamp(p.velocityCutoffMinimum, 20, 20000, 20000);
    p.filterAttack = finiteClamp(p.filterAttack, 0, 10, 0);
    p.filterHold = finiteClamp(p.filterHold, 0, 10, 0);
    p.filterDecay = finiteClamp(p.filterDecay, .001f, 10, .3f);
    p.filterSustain = finiteClamp(p.filterSustain, 0, 1, 1);
    p.filterRelease = finiteClamp(p.filterRelease, .001f, 20, .3f);
    p.filterDepth = finiteClamp(p.filterDepth, 0, 10, 0);
    if (p.velocityCurve != SoundFontParameters::VelocityCurve::soft &&
        p.velocityCurve != SoundFontParameters::VelocityCurve::hard)
        p.velocityCurve = SoundFontParameters::VelocityCurve::medium;
    return p;
}

Font playbackCopy(tsf* bank, double sampleRate) {
    Font font(tsf_copy(bank));
    if (!font || !tsf_set_max_voices(font.get(), maximumVoices))
        throw std::runtime_error("Could not allocate instrument voices.");
    // Preallocate every channel: note/CC/preset changes cannot allocate in audio.
    for (int channel = 0; channel < 16; ++channel)
        if (!tsf_channel_set_presetindex(font.get(), channel, 0))
            throw std::runtime_error("Could not allocate MIDI channels.");
    tsf_set_output(font.get(), TSF_STEREO_INTERLEAVED, static_cast<int>(sampleRate), 0);
    return font;
}
} // namespace

struct SoundFontRenderer::Impl {
    std::shared_ptr<Bank> bank;
    Font font;
    SoundFontParameters parameters;
    double rate = 48000;
    float targetGain = 1, smoothGain = 0;
    std::array<float, 16> modulationValues{{1, 1, 1, 1, 1, 1, 1, 1,
                                          1, 1, 1, 1, 1, 1, 1, 1}};
    std::array<float, 16> bendValues{};
    std::array<int, 16> appliedPitch{{8192, 8192, 8192, 8192, 8192, 8192, 8192, 8192,
                                    8192, 8192, 8192, 8192, 8192, 8192, 8192, 8192}};
    struct FilterVoice {
        double age = 0, releaseAge = 0;
        float level = 0, releaseLevel = 0, frequency = -1;
        bool released = false;
    };
    std::array<FilterVoice, maximumVoices> filters{};
    std::array<std::uint64_t, 2048> held{};
    std::array<std::uint8_t, 2048> heldVelocity{};
    std::array<bool, 2048> pressed{};
    std::array<bool, 16> pedal{};
    std::uint64_t order = 0;
    int monoKey = -1;
    double vibratoPhase = 0;

    void applyEnvelope() noexcept {
        if (!font) return;
        // This override belongs to the playback instance. Never edit shared
        // preset regions, which would change the other transport or keyboard.
        font->hookVolumeEnvelopeOverride = 1;
        font->hookAttackSeconds = parameters.attack;
        font->hookHoldSeconds = parameters.hold;
        font->hookDecaySeconds = parameters.decay;
        font->hookSustain = parameters.sustain;
        font->hookReleaseSeconds = parameters.release;
    }

    void stop() noexcept {
        if (font) {
            for (int i = 0; i < font->voiceNum; ++i) font->voices[i].playingPreset = -1;
            for (int channel = 0; channel < 16; ++channel)
                tsf_channel_midi_control(font.get(), channel, 64, 0);
        }
        held.fill(0);
        heldVelocity.fill(0);
        pressed.fill(false);
        pedal.fill(false);
        monoKey = -1;
        order = 0;
        filters.fill({});
        smoothGain = 0;
    }

    void resetControllers() noexcept {
        modulationValues.fill(1);
        bendValues.fill(0);
        appliedPitch.fill(8192);
        vibratoPhase = 0;
    }

    static bool hiHat(int key) noexcept { return key == 42 || key == 44 || key == 46; }

    void startNote(int channel, int key, std::uint8_t velocity) noexcept {
        if (parameters.drums && hiHat(key))
            for (int i = 0; i < font->voiceNum; ++i) {
                auto& voice = font->voices[i];
                if (voice.playingPreset >= 0 && hiHat(voice.playingKey))
                    tsf_voice_endquick(font.get(), &voice);
            }
        if (parameters.monophonic) {
            for (int i = 0; i < font->voiceNum; ++i)
                if (font->voices[i].playingPreset >= 0)
                    tsf_voice_endquick(font.get(), &font->voices[i]);
            monoKey = channel * 128 + key;
        }
        const auto curve = parameters.velocityCurve;
        const float mapped = std::pow(velocity / 127.f,
            curve == SoundFontParameters::VelocityCurve::soft ? .65f
            : curve == SoundFontParameters::VelocityCurve::hard ? 1.6f : 1.f);
        const auto generation = font->voicePlayIndex;
        tsf_channel_note_on(font.get(), channel, key, std::max(1.f / 127.f, mapped));
        for (int i = 0; i < font->voiceNum && i < maximumVoices; ++i) {
            auto& voice = font->voices[i];
            if (voice.playingPreset < 0 || voice.playIndex != generation) continue;
            voice.hookFilterVelocity = static_cast<std::uint8_t>(
                std::clamp(static_cast<int>(std::round(mapped * 127)), 1, 127));
            filters[static_cast<std::size_t>(i)] = {};
        }
    }

    void noteOn(int channel, int key, std::uint8_t velocity) noexcept {
        const auto index = static_cast<std::size_t>(channel * 128 + key);
        held[index] = ++order;
        heldVelocity[index] = velocity;
        pressed[index] = true;
        startNote(channel, key, velocity);
    }

    void noteOff(int channel, int key) noexcept {
        const auto index = static_cast<std::size_t>(channel * 128 + key);
        pressed[index] = false;
        if (!pedal[static_cast<std::size_t>(channel)]) held[index] = 0;
        tsf_channel_note_off(font.get(), channel, key);
        if (parameters.monophonic && static_cast<int>(index) == monoKey && !held[index]) {
            int newest = -1;
            std::uint64_t serial = 0;
            for (std::size_t i = 0; i < held.size(); ++i)
                if (held[i] > serial) { serial = held[i]; newest = static_cast<int>(i); }
            monoKey = -1;
            if (newest >= 0)
                startNote(newest / 128, newest % 128, heldVelocity[static_cast<std::size_t>(newest)]);
        }
    }

    void message(MidiMessage message) noexcept {
        if (!font || !message.isChannelMessage()) return;
        const int channel = message.status & 15, type = message.status & 0xf0;
        const auto ch = static_cast<std::size_t>(channel);
        if (type == 0x90 && message.data2 != 0) noteOn(channel, message.data1, message.data2);
        else if (type == 0x80 || type == 0x90) noteOff(channel, message.data1);
        else if (type == 0xb0) {
            const int control = message.data1, value = message.data2;
            if (control == 1) modulationValues[ch] = value / 127.f;
            else {
                tsf_channel_midi_control(font.get(), channel, control, value);
                if (control == 64) {
                    pedal[ch] = value >= 64;
                    if (!pedal[ch]) {
                        for (int key = 0; key < 128; ++key) {
                            const auto index = static_cast<std::size_t>(channel * 128 + key);
                            if (!pressed[index]) held[index] = 0;
                        }
                        if (monoKey >= 0 && monoKey / 128 == channel &&
                            !held[static_cast<std::size_t>(monoKey)])
                            noteOff(channel, monoKey % 128);
                    }
                } else if (control == 120 || control == 123) {
                    for (int key = 0; key < 128; ++key) {
                        const auto index = static_cast<std::size_t>(channel * 128 + key);
                        held[index] = 0;
                        pressed[index] = false;
                    }
                    if (monoKey >= 0 && monoKey / 128 == channel) monoKey = -1;
                }
            }
        } else if (type == 0xe0)
            bendValues[ch] = std::clamp(
                (static_cast<int>(message.data1) + (static_cast<int>(message.data2) << 7) - 8192) / 8192.f,
                -1.f, 1.f);
        else if (type == 0xc0)
            tsf_channel_set_presetnumber(font.get(), channel, message.data1, parameters.drums ? 1 : 0);
    }

    void controllersForBlock(unsigned frames) noexcept {
        const double wave = std::sin(vibratoPhase);
        vibratoPhase = std::fmod(vibratoPhase + 2 * pi * 6.85 * frames / font->outSampleRate, 2 * pi);
        for (int channel = 0; channel < 16; ++channel) {
            const auto ch = static_cast<std::size_t>(channel);
            // Existing CatLive behavior: full wheel gives 50 cents of vibrato.
            const int pitch = 8192 + (parameters.pitchVibratoEnabled
                ? static_cast<int>(wave * std::abs(bendValues[ch]) * 2048) : 0);
            if (appliedPitch[ch] != pitch) {
                tsf_channel_set_pitchwheel(font.get(), channel, pitch);
                appliedPitch[ch] = pitch;
            }
        }
    }

    void filtersForBlock(unsigned frames) noexcept {
        const auto& p = parameters;
        const double step = frames / static_cast<double>(font->outSampleRate);
        for (int i = 0; i < font->voiceNum && i < maximumVoices; ++i) {
            auto& voice = font->voices[i];
            if (voice.playingPreset < 0) continue;
            auto& state = filters[static_cast<std::size_t>(i)];
            if (voice.ampenv.segment >= TSF_SEGMENT_RELEASE) {
                if (!state.released) { state.released = true; state.releaseLevel = state.level; }
                state.releaseAge += step;
                state.level = static_cast<float>(state.releaseLevel *
                    std::max(0.0, 1 - state.releaseAge / p.filterRelease));
            } else {
                state.age += step;
                if (state.age < p.filterAttack && p.filterAttack > 0)
                    state.level = static_cast<float>(state.age / p.filterAttack);
                else if (state.age < p.filterAttack + p.filterHold) state.level = 1;
                else state.level = static_cast<float>(p.filterSustain + (1 - p.filterSustain) *
                    std::max(0.0, 1 - (state.age - p.filterAttack - p.filterHold) / p.filterDecay));
            }
            const float velocityHz = p.velocityCutoffMinimum >= 19999 ? 20000
                : p.velocityCutoffMinimum * std::pow(20000 / p.velocityCutoffMinimum,
                                                    voice.hookFilterVelocity / 127.f);
            const float controllerCeiling = p.modulationEnabled
                ? 20 * std::pow(p.cutoff / 20, modulationValues[static_cast<std::size_t>(voice.playingChannel)])
                : p.cutoff;
            const float base = std::min(controllerCeiling, velocityHz);
            const float desired = std::clamp(p.filterDepth > 0
                ? base * std::pow(2.f, p.filterDepth * (state.level - 1)) : base, 20.f, 20000.f);
            if (state.frequency == desired) continue;
            const float frequency = state.frequency < 0 ? desired
                : state.frequency + (desired - state.frequency) * static_cast<float>(1 - std::exp(-step / .004));
            if (state.frequency >= 0 && std::abs(frequency - state.frequency) < .001f) continue;
            state.frequency = frequency;
            auto& filter = voice.hookCutoff;
            const bool active = frequency < 19999;
            if (active != static_cast<bool>(filter.active)) filter.z1 = filter.z2 = 0;
            filter.active = active;
            filter.QInv = 1.4142135623730951;
            if (active) tsf_voice_lowpass_setup(&filter, std::min(frequency / font->outSampleRate, .45f));
        }
    }

    void audio(StereoAudioView output, std::size_t start, std::size_t count) noexcept {
        float interleaved[128];
        for (std::size_t offset = 0; offset < count;) {
            const auto frames = static_cast<unsigned>(std::min<std::size_t>(64, count - offset));
            controllersForBlock(frames);
            filtersForBlock(frames);
            tsf_render_float(font.get(), interleaved, static_cast<int>(frames), 0);
            for (unsigned n = 0; n < frames; ++n) {
                smoothGain += (targetGain - smoothGain) * .005f;
                output.left[start + offset + n] += interleaved[n * 2] * smoothGain;
                if (output.right) output.right[start + offset + n] += interleaved[n * 2 + 1] * smoothGain;
            }
            offset += frames;
        }
    }
};

SoundFontRenderer::SoundFontRenderer(double rate) : impl(std::make_unique<Impl>()) { prepare(rate); }
SoundFontRenderer::~SoundFontRenderer() = default;

void SoundFontRenderer::loadFile(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error("Unable to read SoundFont.");
    const auto length = input.tellg();
    if (length <= 0 || static_cast<std::uintmax_t>(length) > maximumBankBytes)
        throw std::runtime_error("Invalid SoundFont file size.");
    std::vector<char> data(static_cast<std::size_t>(length));
    input.seekg(0);
    if (!input.read(data.data(), static_cast<std::streamsize>(data.size())))
        throw std::runtime_error("Unable to read SoundFont.");
    loadMemory(data.data(), data.size(), path.stem().u8string());
}

void SoundFontRenderer::loadMemory(const void* data, std::size_t bytes, std::string name) {
    if (!data || bytes < 12 || bytes > maximumBankBytes ||
        bytes > static_cast<std::size_t>(std::numeric_limits<int>::max()))
        throw std::runtime_error("Invalid SoundFont data size.");
    auto bank = std::make_shared<Bank>();
    bank->source.reset(tsf_load_memory(data, static_cast<int>(bytes)));
    if (!bank->source || tsf_get_presetcount(bank->source.get()) == 0)
        throw std::runtime_error("Invalid SoundFont file.");
    auto voice = playbackCopy(bank->source.get(), impl->rate);
    bank->name = std::move(name);
    impl->font = std::move(voice);
    impl->bank = std::move(bank);
    impl->stop();
    impl->resetControllers();
    impl->applyEnvelope();
}

std::unique_ptr<SoundFontRenderer> SoundFontRenderer::clone() const {
    auto result = std::make_unique<SoundFontRenderer>(impl->rate);
    if (impl->bank) {
        result->impl->font = playbackCopy(impl->bank->source.get(), impl->rate);
        result->impl->bank = impl->bank;
        for (int channel = 0; channel < 16; ++channel)
            tsf_channel_set_presetindex(result->impl->font.get(), channel,
                tsf_channel_get_preset_index(impl->font.get(), channel));
    }
    result->configure(impl->parameters);
    return result;
}

void SoundFontRenderer::prepare(double rate) {
    if (!std::isfinite(rate) || rate < 8000 || rate > 384000 || rate != std::floor(rate))
        throw std::invalid_argument("Invalid SoundFont sample rate.");
    impl->stop();
    impl->rate = rate;
    if (impl->font)
        tsf_set_output(impl->font.get(), TSF_STEREO_INTERLEAVED, static_cast<int>(rate), 0);
}

bool SoundFontRenderer::loaded() const noexcept { return static_cast<bool>(impl->font); }
const std::string& SoundFontRenderer::name() const noexcept {
    static const std::string empty;
    return impl->bank ? impl->bank->name : empty;
}
int SoundFontRenderer::presetCount() const noexcept {
    return impl->font ? tsf_get_presetcount(impl->font.get()) : 0;
}
std::string SoundFontRenderer::presetName(int index) const {
    const auto* result = impl->font ? tsf_get_presetname(impl->font.get(), index) : nullptr;
    return result ? result : "";
}
double SoundFontRenderer::sampleRate() const noexcept { return impl->rate; }

void SoundFontRenderer::configure(const SoundFontParameters& value) noexcept {
    const auto next = normalized(value);
    if (impl->parameters.monophonic != next.monophonic) impl->stop();
    impl->parameters = next;
    impl->targetGain = std::pow(10.f, (next.gainDB + next.controllerVolumeDB) / 20.f);
    impl->applyEnvelope();
}
bool SoundFontRenderer::selectPreset(int index, int channel) noexcept {
    return impl->font && channel >= 1 && channel <= 16 && index >= 0 && index < presetCount()
        && tsf_channel_set_presetindex(impl->font.get(), channel - 1, index) != 0;
}
void SoundFontRenderer::stop() noexcept { impl->stop(); }
unsigned SoundFontRenderer::activeVoices() const noexcept {
    return impl->font ? static_cast<unsigned>(tsf_active_voice_count(impl->font.get())) : 0;
}
bool SoundFontRenderer::renderAdd(StereoAudioView output, MidiEventSpan events) noexcept {
    if ((output.frames != 0 && !output.left) || (output.right && output.left == output.right) ||
        (events.size != 0 && !events.data)) return false;
    std::size_t previous = 0;
    for (std::size_t i = 0; i < events.size; ++i) {
        const auto at = events.data[i].sampleOffset;
        if (at < previous || at > output.frames) return false;
        previous = at;
    }
    if (!impl->font) return true;
    std::size_t offset = 0;
    for (std::size_t i = 0; i < events.size; ++i) {
        const auto& event = events.data[i];
        impl->audio(output, offset, event.sampleOffset - offset);
        impl->message(event.message);
        offset = event.sampleOffset;
    }
    impl->audio(output, offset, output.frames - offset);
    return true;
}

} // namespace catlive::native
