#pragma once
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <map>
#include <string>
#include <vector>

namespace catlive::native::vst3 {
struct Description {
    std::filesystem::path path;
    std::string classID, name, vendor, category;
};
struct State { std::vector<std::uint8_t> component, controller; };
struct MIDIEvent { int offset = 0; std::uint8_t status = 0, data1 = 0, data2 = 0; };
struct Transport {
    double seconds = 0, quarterNotes = 0, tempo = 120;
    int numerator = 4, denominator = 4;
    bool playing = false;
};
// Scan in a child process: third-party DLL entry points may crash or hang.
std::vector<Description> scan(const std::filesystem::path &);
// Keep the factory/module loaded for a complete scan/validation session, including
// destroy-and-restore checks. DLL unload/reload is not a processor state round trip.
std::shared_ptr<void> retainModule(const std::filesystem::path &);
class Editor;
// No JUCE dependency. Control methods and destruction belong to the UI thread;
// process() belongs to one audio thread and never acquires locks or allocates.
class Processor final {
public:
    Processor(const Description &, const State &, double rate, int maximumFrames = 4096);
    ~Processor();
    Processor(const Processor &) = delete;
    Processor &operator=(const Processor &) = delete;
    bool process(float *left, float *right, int frames, const Transport &,
                 const MIDIEvent *events = nullptr, int eventCount = 0) noexcept;
    // Audio-thread only, once after the normal item render for this callback.
    // Advances a visible, otherwise idle editor with silence; output is discarded.
    bool processEditorSilence(int frames, const Transport &) noexcept;
    State state() const;
    std::map<int, std::uint32_t> parameterIDs() const;
    // Audio/control safe: queues atomics only; no controller calls or allocations.
    bool automate(std::uint32_t parameter, double value) noexcept;
    bool consumeEdited() noexcept;
    unsigned latency() const noexcept;
    bool isInstrument() const noexcept;
    std::unique_ptr<Editor> openEditor(void *parentHWND, std::function<void(int,int)> resize);
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
    friend class Editor;
};
// Must be destroyed before its Processor; the native plug-in view is attached
// directly to an HWND, never substituted with generic parameter sliders.
class Editor final {
public:
    ~Editor();
    int width() const noexcept;
    int height() const noexcept;
    void resize(int width, int height);
    void setVisible(bool);
private:
    struct Impl;
    explicit Editor(std::unique_ptr<Impl>);
    std::unique_ptr<Impl> impl;
    friend class Processor;
};
}
