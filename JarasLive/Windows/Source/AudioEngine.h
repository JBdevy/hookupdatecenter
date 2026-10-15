#pragma once
#include "Common.h"
#include "../../Core/Transport/PlaybackScope.hpp"
#include "NativeFX.h"
#include "StreamingReader.h"
#include "Instrument.h"
#include "Automation.h"
#include "ClickProgram.h"
#include "MIDIPlayback.h"
#include "TrackCapture.h"
#include "TimecodeMIDI.h"
namespace catlive {
class ClipAudio;
// Prepared readers, buffers and routing live outside the device callback.
class AudioEngine final : public AudioIODeviceCallback, private MidiInputCallback {
  public:
    struct State {
        double position = 0, subPosition = 0;
        bool playing = false, subPlaying = false, loop = false;
        double loopStart = 0, loopEnd = 0;
        jaras::PlaybackScope scope[2];
        int timecodePreferred = -1;
        double end = std::numeric_limits<double>::infinity();
    };
    AudioEngine();
    ~AudioEngine() override;
    AudioDeviceManager devices;
    AudioFormatManager formats;
    MidiKeyboardState keyboardState;
    Instrument instrument;
    std::atomic<bool> instrumentAllowed{false};
    void loadSoundFont(const File &);
    String openDevice();
    void configureMetronome(const var &);
    void setEffects(const ID &, const var &);
    void setMIDISlot(int, const String &);
    void setKeyboardTarget(const ID &id) {
        int index = -1;
        for (size_t i = 0; i < buses.size(); ++i)
            if (buses[i]->id == id) {
                index = (int)i;
                break;
            }
        keyboardTarget = index;
    }
    std::atomic<bool> metronomeEnabled{false};
    void closeDevice();
    void prepareSong(const jaras::Song &, const File &directory, const var &masterSettings = {},
                     const jaras::Project *project = nullptr);
    void transport(const State &);
    int timecodePreferred(const std::optional<ID>& region) const { return timecodeProgram.preferred(region); }
    void setMixer(const jaras::Project &, const jaras::Song &);
    void setOffline(bool enabled);
    void prepareOffline(double sampleRate) {
        if (attached || !std::isfinite(sampleRate) || sampleRate < 32000 || sampleRate > 192000)
            throw std::runtime_error("Invalid offline sample rate.");
        rate = sampleRate;
    }
    void setExportCapture(const ID &track = {}) {
        exportCapture = true;
        exportBus = -1;
        if (!track.empty()) {
            for (size_t i = 0; i < buses.size(); ++i)
                if (buses[i]->id == track) {
                    exportBus = (int)i;
                    return;
                }
            throw std::runtime_error("Export track no longer exists.");
        }
    }
    void startRecording(const File &, int channels = 2, int bits = 24);
    void stopRecording();
    void startTrackRecording(const std::vector<TrackCapture::Target> &, int bits, double bpm);
    std::vector<TrackCapture::Take> stopTrackRecording();
    uint64 recordingOverflows() const { return recordingDrops.load(); }
    uint64 recordedSamples() const { return recordedFrames.load(); }
    void armTrack(const ID &id, bool enabled) {
        for (auto &bus : buses)
            if (bus->id == id)
                bus->armed.store(enabled);
    }
    bool isRecording() const { return recording.load(); }
    State state() const;
    double takeElapsed();
    float peak() const { return meter.load(std::memory_order_relaxed); }
    std::pair<float, float> fxLevels(const ID &id) const {
        if (id.empty())
            return {masterFXInput.load(), masterFXOutput.load()};
        for (const auto &bus : buses)
            if (bus->id == id)
                return {bus->fxInput.load(), bus->fxOutput.load()};
        return {};
    }
    float trackPeak(const ID &id) const {
        for (const auto &bus : buses)
            if (bus->id == id)
                return bus->peak.load(std::memory_order_relaxed);
        return 0;
    }
    uint64 getUnderruns() const { return underruns.load(); }
    int residentStreams() const {
        std::set<const StreamingReader*> active;
        for (const auto& voice : voices) for (const auto& reader : voice->source->readers)
            if (reader->cached()) active.insert(reader.get());
        return (int)active.size();
    }
    var streamDiagnostics() const {
        std::set<const StreamingReader*> unique;
        uint64 caches = 0, inactive = 0;
        for (const auto& voice : voices) for (const auto& reader : voice->source->readers)
            if (unique.insert(reader.get()).second) {
                caches += reader->cacheMisses.load();
                inactive += reader->inactiveMisses.load();
            }
        auto result = object();
        put(result, "cacheMisses", (int64)caches); put(result, "inactiveMisses", (int64)inactive);
        return result;
    }
    double cpu() const { return devices.getCpuUsage(); }
    void render(float *const *output, int channels, int samples,
                const float *const *input = nullptr, int inputChannels = 0);
    double sampleRate() const { return rate.load(); }
    StringArray missingFiles, unsupported;

  private:
    struct Source {
        std::unique_ptr<StreamingReader> readers[2];
    };
    struct Voice {
        ID track;
        std::optional<double> playbackStart;
        double start = 0, duration = 0, offset = 0, speed = 1, clipGain = 1, clipPan = 0,
               fadeIn = 0, fadeOut = 0;
        int channelMode = 0;
        std::shared_ptr<Source> source;
        AudioBuffer<float> processed[2];
        std::unique_ptr<ClipAudio> clipAudio;
        NativeFX fx[2];
        var fxSettings;
        AutomationProgram automation;
        float volume = 1, pan = 0;
        bool mute = false, solo = false;
        int firstOutput = 0, outputChannels = 2;
        size_t bus = 0;
    };
    struct Bus {
        ID id;
        float volume = 1, pan = 0;
        bool mute = false, solo = false, phase = false;
        int parent = -1;
        std::vector<jaras::OutputPatch> outputs;
        std::vector<int> sends;
        std::atomic<float> peak{0};
        std::atomic<float> fxInput{0}, fxOutput{0};
        AudioBuffer<float> buffer{2, 4096};
        AudioBuffer<float> subBuffer{2, 4096};
        AudioBuffer<float> &head(int index) { return index == 0 ? buffer : subBuffer; }
        NativeFX fx[2];
        AutomationProgram automation;
        var settings;
        std::unique_ptr<ClickProgram> click;
        bool timecode = false;
        std::vector<PlaybackNote> midiNotes;
        std::unique_ptr<MIDIPlayback> midi;
        MidiBuffer midiMessages;
        int midiSlot = 0, midiChannel = 0;
        int inputFirst = 0, inputChannels = 2;
        bool inputMonitoring = true;
        std::atomic<bool> armed{false};
    };
    std::vector<std::unique_ptr<Bus>> buses;
    std::vector<int> busOrder;
    NativeFX masterFX;
    std::unique_ptr<MIDIPlayback> masterMIDI;
    File instrumentDirectory;
    std::atomic<int> keyboardTarget{-1};
    var masterFXSettings;
    AudioBuffer<float> masterBuffer{2, 4096};
    AudioBuffer<float> readScratch[2]{{2, 131080}, {2, 131080}};
    AudioBuffer<float> liveRecordBuffer{2, 4096};
    std::array<std::array<double, 4096>, 2> timelinePositions{};
    jaras::TimecodeProgram timecodeProgram;
    jaras::LTCWaveform timecodeWaveform;
    TimecodeMIDI timecodeMIDI;
    float timecodeGain = 1;
    ClickProgram metronome;
    var metronomeSettings;
    int metronomeMode = 0, metronomeOutput = 1, metronomeChannels = 2;
    float metronomeGainA = 1, metronomeGainB = 1;
    std::vector<jaras::OutputPatch> masterOutputs{{1, 2}};
    TimeSliceThread readAhead{"CatLive media read-ahead"};
    std::vector<std::unique_ptr<Voice>> voices;
    std::atomic<double> rate{48000}, position{0}, subPosition{0};
    std::atomic<bool> playing{false}, subPlaying{false};
    std::atomic<uint64> elapsedSamples{0}, underruns{0};
    std::atomic<float> meter{0};
    std::atomic<float> masterFXInput{0}, masterFXOutput{0};
    struct Update {
        enum Kind { transport, mixer } kind = transport;
        State state;
        int index = -1;
        float volume = 1, pan = 0;
        bool mute = false, solo = false, mono = false, phase = false;
    };
    AbstractFifo fifo{1024};
    std::array<Update, 1024> updates;
    State current;
    float masterVolume = 1, masterPan = 0;
    bool masterMute = false, masterMono = false, masterPhase = false, masterSolo = false;
    bool instrumentWasAllowed = false;
    double duration = 0;
    bool attached = false;
    bool exportCapture = false;
    int exportBus = -1;
    TimeSliceThread recordingThread{"CatLive recording"};
    std::unique_ptr<AudioFormatWriter::ThreadedWriter> recorder;
    std::unique_ptr<TrackCapture> trackCapture;
    std::atomic<uint64> recordedFrames{0};
    std::array<int, 128> inputMapping{};
    std::atomic<bool> recording{false};
    std::atomic<uint64> recordingDrops{0};
    MidiMessageCollector midiInput;
    MidiMessageCollector midiSlots[3];
    MidiBuffer slotMessages[3], keyboardMidi;
    String midiDevices[3];
    CriticalSection midiRoutingLock;
    MidiBuffer liveMidi;
    void handleIncomingMidiMessage(MidiInput *, const MidiMessage &) override;
    void enqueue(const Update &);
    void applyUpdates();
    void mixVoice(Voice &, int head, double at, float *const *, int channels, int dest, int count);
    void audioDeviceIOCallbackWithContext(const float *const *, int, float *const *, int, int,
                                          const AudioIODeviceCallbackContext &) override;
    void audioDeviceAboutToStart(AudioIODevice *) override;
    void audioDeviceStopped() override;
};
} // namespace catlive
