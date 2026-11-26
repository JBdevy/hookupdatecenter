#include "../Source/SoundFontRenderer.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <iostream>
#include <limits>
#include <new>
#include <stdexcept>
#include <string>
#include <vector>
#if defined(_WIN32)
#include <malloc.h>
#endif

// Compile this test and SoundFontRenderer.cpp with
// -DCATLIVE_SOUNDFONT_TEST_ALLOCATOR so C allocations are checked as well.
#if !defined(CATLIVE_SOUNDFONT_TEST_ALLOCATOR)
#error SoundFont tests require CATLIVE_SOUNDFONT_TEST_ALLOCATOR
#endif

namespace allocations {
thread_local bool watched = false;
thread_local std::size_t created = 0, destroyed = 0;
void allocated() noexcept { if (watched) ++created; }
void freed(void* memory) noexcept { if (watched && memory) ++destroyed; }
struct Watch {
    Watch() { created = destroyed = 0; watched = true; }
    ~Watch() { watched = false; }
};
}

void* operator new(std::size_t size) {
    allocations::allocated();
    if (void* memory = std::malloc(size ? size : 1)) return memory;
    throw std::bad_alloc();
}
void* operator new[](std::size_t size) { return ::operator new(size); }
void operator delete(void* memory) noexcept { allocations::freed(memory); std::free(memory); }
void operator delete[](void* memory) noexcept { ::operator delete(memory); }
void operator delete(void* memory, std::size_t) noexcept { ::operator delete(memory); }
void operator delete[](void* memory, std::size_t) noexcept { ::operator delete(memory); }
void* operator new(std::size_t size, std::align_val_t alignment) {
    allocations::allocated();
    void* memory = nullptr;
#if defined(_WIN32)
    memory = _aligned_malloc(size ? size : 1, static_cast<std::size_t>(alignment));
#else
    if (posix_memalign(&memory, static_cast<std::size_t>(alignment), size ? size : 1) != 0)
        memory = nullptr;
#endif
    if (!memory) throw std::bad_alloc();
    return memory;
}
void* operator new[](std::size_t size, std::align_val_t alignment) { return ::operator new(size, alignment); }
void operator delete(void* memory, std::align_val_t) noexcept {
    allocations::freed(memory);
#if defined(_WIN32)
    _aligned_free(memory);
#else
    std::free(memory);
#endif
}
void operator delete[](void* memory, std::align_val_t alignment) noexcept { ::operator delete(memory, alignment); }
void operator delete(void* memory, std::size_t, std::align_val_t alignment) noexcept { ::operator delete(memory, alignment); }
void operator delete[](void* memory, std::size_t, std::align_val_t alignment) noexcept { ::operator delete(memory, alignment); }

extern "C" void* catliveSoundFontAllocate(std::size_t bytes) {
    allocations::allocated();
    return std::malloc(bytes);
}
extern "C" void* catliveSoundFontReallocate(void* memory, std::size_t bytes) {
    allocations::allocated();
    return std::realloc(memory, bytes);
}
extern "C" void catliveSoundFontFree(void* memory) {
    allocations::freed(memory);
    std::free(memory);
}

namespace {
using namespace catlive::native;
void require(bool result, const char* message) { if (!result) throw std::runtime_error(message); }
struct Audio {
    std::vector<float> left, right;
    explicit Audio(std::size_t frames = 8192) : left(frames), right(frames) {}
    StereoAudioView view() { return {left.data(), right.data(), left.size()}; }
    double energy(std::size_t begin = 0) const {
        double sum = 0;
        for (std::size_t i = begin; i < left.size(); ++i) sum += left[i] * left[i] + right[i] * right[i];
        return sum;
    }
    bool finite() const {
        return std::all_of(left.begin(), left.end(), [](float value) { return std::isfinite(value); }) &&
               std::all_of(right.begin(), right.end(), [](float value) { return std::isfinite(value); });
    }
};
Audio render(SoundFontRenderer& synth, std::size_t frames = 8192,
             std::initializer_list<MidiEvent> events = {}) {
    Audio output(frames);
    require(synth.renderAdd(output.view(), {events.begin(), events.size()}), "Valid render was rejected.");
    require(output.finite(), "Non-finite audio.");
    return output;
}
Audio note(SoundFontRenderer& synth, int key = 60, int velocity = 100) {
    return render(synth, 8192, {{0, MidiMessage::noteOn(1, key, velocity)}});
}
bool equal(const Audio& a, const Audio& b) { return a.left == b.left && a.right == b.right; }
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : std::getenv("CATLIVE_TEST_SF2");
    if (!path || !*path) {
        std::cerr << "Pass a real SF2 fixture path or CATLIVE_TEST_SF2. No fixture is bundled or downloaded.\n";
        return 2;
    }
    int passed = 0, failed = 0;
    const auto test = [&](const char* name, const std::function<void()>& body) {
        try { body(); ++passed; std::cout << "PASS " << name << '\n'; }
        catch (const std::exception& error) { ++failed; std::cerr << "FAIL " << name << ": " << error.what() << '\n'; }
    };
    try {
        const auto file = std::filesystem::u8path(path);
        SoundFontRenderer bank;
        bank.loadFile(file);
        std::cout << "SF2 " << bank.name() << ", preset 0: " << bank.presetName(0) << '\n';

        test("real SF2 load and failure preserve the previous bank", [&] {
            require(bank.loaded() && bank.presetCount() > 0 && !bank.presetName(0).empty(), "Missing SF2 metadata.");
            auto synth = bank.clone();
            require(note(*synth).energy() > .00001, "The SF2 did not produce audio.");
            const auto active = synth->activeVoices();
            const std::array<char, 12> invalid{};
            bool rejected = false;
            try { synth->loadMemory(invalid.data(), invalid.size(), "invalid"); }
            catch (const std::exception&) { rejected = true; }
            require(rejected && synth->name() == bank.name() && synth->activeVoices() == active,
                    "A failed bank load replaced the playing instrument.");
            require(render(*synth).energy() > .00001, "A failed bank load silenced the instrument.");
        });

        test("MIDI offsets are sample-exact and block boundaries retain events", [&] {
            auto whole = bank.clone(), split = bank.clone();
            const auto result = render(*whole, 4096, {{321, MidiMessage::noteOn(1, 60, 100)}});
            require(std::all_of(result.left.begin(), result.left.begin() + 321, [](float value) { return value == 0; }),
                    "The MIDI note started before its sample offset.");
            require(result.energy(321) > .00001, "The MIDI note did not start.");
            const auto silence = render(*split, 321, {{321, MidiMessage::noteOn(1, 60, 100)}});
            const auto tail = render(*split, 4096 - 321);
            require(silence.energy() == 0 && std::equal(tail.left.begin(), tail.left.end(), result.left.begin() + 321) &&
                    std::equal(tail.right.begin(), tail.right.end(), result.right.begin() + 321),
                    "Rendering changed at an event/block boundary.");
        });

        test("main sub and keyboard share samples but retain independent voices and envelopes", [&] {
            auto original = std::make_unique<SoundFontRenderer>();
            original->loadFile(file);
            auto main = original->clone(), sub = original->clone(), keyboard = original->clone();
            original.reset(); // Copied instances keep the bank alive.
            auto quiet = SoundFontParameters{};
            quiet.attack = .2f;
            quiet.gainDB = -24;
            keyboard->configure(quiet);
            // The CatLive gain smoother runs even in silence. All three heads
            // have advanced by the same time when comparing their first note.
            render(*main);
            require(render(*sub).energy() == 0 && render(*keyboard).energy() == 0, "Unplayed bank was not silent.");
            const auto expected = note(*main);
            const auto actual = note(*sub);
            require(equal(expected, actual), "Configuring keyboard modified a shared preset.");
            const auto keyboardAudio = note(*keyboard);
            require(keyboardAudio.energy() < expected.energy() * .05, "Keyboard envelope/gain was not independent.");
            main->stop();
            require(render(*main).energy() == 0 && render(*sub).energy() > .00001,
                    "Stopping main stopped sub playback.");
        });

        test("note off velocity zero and sustain release do not leave stuck notes", [&] {
            auto synth = bank.clone();
            auto params = SoundFontParameters{};
            params.release = .01f;
            synth->configure(params);
            render(*synth, 512, {{0, MidiMessage::noteOn(1, 60, 100)}});
            auto released = render(*synth, 8192, {{0, MidiMessage::noteOn(1, 60, 0)}});
            require(synth->activeVoices() == 0 && released.energy(4096) == 0, "Velocity-zero Note On did not release.");
            render(*synth, 512, {{0, MidiMessage::controller(1, 64, 127)}, {0, MidiMessage::noteOn(1, 60, 100)}});
            const auto held = render(*synth, 8192, {{0, MidiMessage::noteOff(1, 60)}});
            require(synth->activeVoices() > 0 && held.energy(4096) > .00001, "Sustain did not retain the released note.");
            released = render(*synth, 8192, {{0, MidiMessage::controller(1, 64, 0)}});
            require(synth->activeVoices() == 0 && released.energy(4096) == 0, "Pedal release left a stuck note.");
        });

        test("mono returns to the previous held key", [&] {
            auto synth = bank.clone();
            auto params = SoundFontParameters{};
            params.monophonic = true;
            params.release = .01f;
            synth->configure(params);
            render(*synth, 2048, {{0, MidiMessage::noteOn(1, 60, 100)}});
            render(*synth, 2048, {{0, MidiMessage::noteOn(1, 67, 100)}});
            const auto recalled = render(*synth, 4096, {{0, MidiMessage::noteOff(1, 67)}});
            require(synth->activeVoices() > 0 && recalled.energy(2048) > .00001, "Mono did not recall the held key.");
            const auto final = render(*synth, 8192, {{0, MidiMessage::noteOff(1, 60)}});
            require(synth->activeVoices() == 0 && final.energy(4096) == 0, "Mono recall left a stuck note.");
        });

        test("drum hi-hat choke removes the old note without choking unrelated notes", [&] {
            auto drums = bank.clone(), poly = bank.clone(), single = bank.clone();
            drums->configure(SoundFontParameters::defaults(true));
            poly->configure(SoundFontParameters::defaults(false));
            render(*drums, 1024, {{0, MidiMessage::noteOn(1, 42, 100)}});
            render(*poly, 1024, {{0, MidiMessage::noteOn(1, 42, 100)}});
            render(*drums, 4096, {{0, MidiMessage::noteOn(1, 46, 100)}});
            render(*poly, 4096, {{0, MidiMessage::noteOn(1, 46, 100)}});
            render(*single, 4096, {{0, MidiMessage::noteOn(1, 46, 100)}});
            require(drums->activeVoices() == single->activeVoices() && poly->activeVoices() > drums->activeVoices(),
                    "The preceding hi-hat remained active or ordinary polyphony was choked.");
            render(*drums, 4096, {{0, MidiMessage::noteOn(1, 60, 100)}});
            require(drums->activeVoices() > single->activeVoices(), "A non-hi-hat note choked the hi-hat.");
        });

        test("velocity curves gain and additive output remain audible and proportional", [&] {
            auto soft = bank.clone(), medium = bank.clone(), hard = bank.clone();
            auto p = SoundFontParameters{};
            p.velocityCurve = SoundFontParameters::VelocityCurve::soft;
            soft->configure(p);
            p.velocityCurve = SoundFontParameters::VelocityCurve::hard;
            hard->configure(p);
            const auto a = note(*soft, 60, 48), b = note(*medium, 60, 48), c = note(*hard, 60, 48);
            require(a.energy() > b.energy() && b.energy() > c.energy(), "Velocity curves have no effect or are reversed.");
            auto unity = bank.clone(), attenuated = bank.clone();
            p = {};
            p.gainDB = -6;
            attenuated->configure(p);
            const auto full = note(*unity), half = note(*attenuated);
            require(std::abs(half.energy() / full.energy() - std::pow(10., -6. / 10)) < .0001,
                    "Instrument gain changed its calibrated dB behavior.");
            auto additive = bank.clone();
            Audio mix;
            std::fill(mix.left.begin(), mix.left.end(), .25f);
            std::fill(mix.right.begin(), mix.right.end(), -.25f);
            const MidiEvent event{0, MidiMessage::noteOn(1, 60, 100)};
            require(additive->renderAdd(mix.view(), {&event, 1}), "Additive render failed.");
            for (std::size_t i = 0; i < mix.left.size(); ++i)
                require(std::abs(mix.left[i] - (full.left[i] + .25f)) < .000001f &&
                        std::abs(mix.right[i] - (full.right[i] - .25f)) < .000001f,
                        "Rendering replaced an existing mixer contribution.");
        });

        test("cutoff velocity filter modulation envelope and wheel vibrato affect audio", [&] {
            auto open = bank.clone(), closed = bank.clone(), modulation = bank.clone();
            auto p = SoundFontParameters{};
            p.cutoff = 100;
            closed->configure(p);
            p = {};
            p.modulationEnabled = true;
            modulation->configure(p);
            const auto baseline = note(*open, 84);
            const auto filtered = note(*closed, 84);
            const auto modulated = render(*modulation, 8192,
                {{0, MidiMessage::controller(1, 1, 0)}, {0, MidiMessage::noteOn(1, 84, 100)}});
            require(filtered.energy() < baseline.energy() * .2 && modulated.energy() < baseline.energy() * .2,
                    "Cutoff or CC1 did not filter the note.");
            auto velocity = bank.clone(), envelope = bank.clone(), wheel = bank.clone();
            p = {};
            p.velocityCutoffMinimum = 20;
            velocity->configure(p);
            p = {};
            p.filterDepth = 8;
            p.filterAttack = .5f;
            envelope->configure(p);
            p = {};
            p.pitchVibratoEnabled = true;
            wheel->configure(p);
            require(note(*velocity, 84).energy() < baseline.energy(), "Velocity cutoff was lost.");
            require(note(*envelope, 84).energy() < baseline.energy(), "Filter envelope was lost.");
            require(!equal(baseline, render(*wheel, 8192,
                {{0, MidiMessage::pitchWheel(1, 16383)}, {0, MidiMessage::noteOn(1, 84, 100)}})),
                "Pitch-wheel vibrato was lost.");
        });

        test("channel routing all-notes-off and stop leave no residual sound", [&] {
            auto synth = bank.clone();
            const auto playing = render(*synth, 4096, {{0, MidiMessage::noteOn(16, 60, 100)}});
            require(playing.energy() > .00001, "Channel 16 did not play.");
            render(*synth, 8192, {{0, MidiMessage::controller(16, 120, 0)}});
            require(synth->activeVoices() == 0, "All-sounds-off did not clear the channel.");
            note(*synth);
            synth->stop();
            require(render(*synth).energy() == 0 && synth->activeVoices() == 0, "Stop left residual audio.");
            require(!synth->selectPreset(-1) && !synth->selectPreset(synth->presetCount()) &&
                    !synth->selectPreset(0, 17) && synth->selectPreset(0, 16), "Preset validation failed.");
        });

        test("invalid blocks fail atomically and non-finite settings remain finite", [&] {
            auto synth = bank.clone();
            Audio output(64);
            const MidiEvent late{65, MidiMessage::noteOn(1, 60, 100)};
            const std::array<MidiEvent, 2> unordered{{{12, MidiMessage::noteOn(1, 60, 100)},
                                                    {3, MidiMessage::noteOff(1, 60)}}};
            require(!synth->renderAdd(output.view(), {&late, 1}) &&
                    !synth->renderAdd(output.view(), {unordered.data(), unordered.size()}) &&
                    !synth->renderAdd(output.view(), {nullptr, 1}) &&
                    !synth->renderAdd({nullptr, nullptr, 64}) &&
                    !synth->renderAdd({output.left.data(), output.left.data(), 64}), "Invalid output/events accepted.");
            require(output.energy() == 0 && synth->activeVoices() == 0, "Invalid block partially changed state.");
            auto p = SoundFontParameters{};
            p.gainDB = p.attack = p.decay = p.filterRelease = p.cutoff = std::numeric_limits<float>::quiet_NaN();
            synth->configure(p);
            require(note(*synth).finite(), "Non-finite settings escaped normalization.");
            bool rejected = false;
            try { synth->prepare(std::numeric_limits<double>::infinity()); }
            catch (const std::invalid_argument&) { rejected = true; }
            require(rejected && synth->sampleRate() == 48000, "Invalid rate changed the renderer.");
            synth->prepare(96000);
            require(synth->sampleRate() == 96000 && note(*synth).energy() > .00001, "Device-rate change failed.");
        });

        test("render configure presets MIDI and stop allocate and free nothing", [&] {
            auto synth = bank.clone();
            Audio output(512);
            std::array<MidiEvent, 320> events{};
            for (std::size_t i = 0; i < 256; ++i)
                events[i] = {i, MidiMessage::noteOn(static_cast<int>(i % 16 + 1),
                                                   static_cast<int>(i % 128), 100)};
            for (std::size_t i = 256; i < events.size(); ++i)
                events[i] = {i, MidiMessage::controller(static_cast<int>(i % 16 + 1),
                    i < 272 ? 64 : i < 288 ? 1 : i < 304 ? 7 : 120, 0)};
            bool ok = true;
            auto p = SoundFontParameters{};
            {
                allocations::Watch guard;
                for (int n = 0; n < 32; ++n) {
                    p.monophonic = n % 2 != 0;
                    p.cutoff = n % 2 ? 3000.f : 20000.f;
                    synth->configure(p);
                    ok = synth->selectPreset(0, n % 16 + 1) && ok;
                    ok = synth->renderAdd(output.view(), {events.data(), events.size()}) && ok;
                    synth->stop();
                }
            }
            require(ok, "A valid callback operation failed.");
            require(allocations::created == 0 && allocations::destroyed == 0,
                    "Heap allocation or destruction occurred in the audio consumer.");
        });
    } catch (const std::exception& error) {
        std::cerr << "Cannot run SF2 tests: " << error.what() << '\n';
        return 2;
    }
    std::cout << passed << " passed, " << failed << " failed\n";
    return failed == 0 ? 0 : 1;
}
