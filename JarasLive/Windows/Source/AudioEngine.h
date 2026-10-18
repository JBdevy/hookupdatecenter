#pragma once
#include "../../Core/Tracks/ItemFade.hpp"
#include "Common.h"
#include "../../Core/Transport/PlaybackScope.hpp"
#include "NativeFX.h"
#include "../../WindowsNative/Source/AudioLatency.h"
#include "StreamingReader.h"
#include "Instrument.h"
#include "Automation.h"
#include "ClickProgram.h"
#include "MIDIPlayback.h"
#include "TrackCapture.h"
#include "TimecodeMIDI.h"
#include "TransportFadeout.h"
namespace catlive {
class ClipAudio;
// Prepared readers, buffers and routing live outside the device callback.
class AudioEngine final : public AudioIODeviceCallback, private MidiInputCallback {
  public:
    struct State {
        double position = 0, subPosition = 0;
        bool playing = false, subPlaying = false, loop = false;
        bool preserveLatency = false; // scheduled musical transition, not a manual seek
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
    void configureDeviceChannels(const BigInteger &inputs, const BigInteger &outputs);
    void configureMetronome(const var &);
    void setEffects(const ID &, const var &);
    std::shared_ptr<native::vst3::Processor> externalEffect(const ID &, const String &) const;
    void captureExternalEffects(const ID &, var &) const;
    native::stem::Status stemStatus(const ID &,const String &)const;
    void waitForStems();
    void previewStemMix(const ID &,const String &,const native::stem::Mix &);
    void checkStemErrors()const;
    void refreshStemLatency();
    unsigned exportLatencyFrames()const;
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
    void refreshTiming(const jaras::Song &song);
    void refreshRegionPitch(const jaras::Song &, const ID &);
    void prepareSong(const jaras::Song &, const File &directory, const var &masterSettings = {},
                     const jaras::Project *project = nullptr);
    void transport(const State &);
    int timecodePreferred(const std::optional<ID>& region) const { return timecodeProgram.preferred(region); }
    void previewMIDIItem(const jaras::Song &,const jaras::AudioClip &);
    void setItemControls(const jaras::AudioClip &);
    void setMixer(const jaras::Project &, const jaras::Song &);
    void setOffline(bool enabled);
    void extendOfflineDuration(double end) {
        if (attached || !std::isfinite(end) || end < 0)
            throw std::runtime_error("Invalid offline export end.");
        duration = std::max(duration, end);
    }
    void prepareOffline(double sampleRate) {
        if (attached || !std::isfinite(sampleRate) || sampleRate < 32000 || sampleRate > 192000)
            throw std::runtime_error("Invalid offline sample rate.");
        rate = sampleRate;
        offlineMode=true;
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
    void startTrackFadeout(const std::set<ID> &, double seconds);
    void cancelTrackFadeout() noexcept;
    double trackFadeoutRemainingSeconds() const noexcept;
    float trackFadeoutGain(const ID &) const;
    bool trackFadeoutComplete() const noexcept;
    bool trackFadeoutActive() const noexcept;
    State state() const;
    State presentationState() const;
    unsigned presentationLatencyFrames()const{return presentationDelay.load();}
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
    std::array<float, 2> meterLevels(const ID &id = {}) const {
        if (id.empty()) return {masterLevels[0].load(), masterLevels[1].load()};
        for (const auto &bus : buses) if (bus->id == id)
            return {bus->levels[0].load(), bus->levels[1].load()};
        return {};
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
        put(result, "primedSources", lastPrimedSources);
        put(result, "primeWaitMilliseconds", lastPrimeWaitMilliseconds);
        return result;
    }
    double cpu() const { return devices.getCpuUsage(); }
    void render(float *const *output, int channels, int samples,
                const float *const *input = nullptr, int inputChannels = 0);
    double sampleRate() const { return rate.load(); }
    StringArray missingFiles, unsupported;
    var preparationDiagnostics;

  private:
    NativeFX *effects(const ID &, int head = 0) const;
    int lastPrimedSources = 0;
    double lastPrimeWaitMilliseconds = 0;
    struct Source {
        File file;
        int64 fileSize = 0;
        Time modified;
        std::unique_ptr<StreamingReader> readers[2];
    };
    struct Voice {
        ID track, clipID;
        std::optional<double> playbackStart;
        double start = 0, duration = 0, offset = 0, speed = 1, clipGain = 1, clipPan = 0,
               fadeIn = 0, fadeOut = 0;
        jaras::FadeCurve fadeInShape, fadeOutShape;
        int channelMode = 0;
        std::shared_ptr<Source> source;
        AudioBuffer<float> processed[2];
        AudioBuffer<float> stemInput[2]{{2,4096},{2,4096}};
        std::unique_ptr<ClipAudio> clipAudio;
        NativeFX fx[2];
        var fxSettings;
        AutomationProgram automation;
        float volume = 1, pan = 0;
        bool mute = false, solo = false, itemMuted = false, fxBypassed = false, frozen = false;
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
        std::array<std::atomic<float>, 2> levels{};
        std::atomic<float> fxInput{0}, fxOutput{0};
        AudioBuffer<float> buffer{2, 4096};
        AudioBuffer<float> subBuffer{2, 4096};
        AudioBuffer<float> frozen[2]{{2,4096},{2,4096}};
        AudioBuffer<float> clips[2]{{2,4096},{2,4096}};
        AudioBuffer<float> &head(int index) { return index == 0 ? buffer : subBuffer; }
        NativeFX fx[2];
        AutomationProgram automation;
        var settings;
        std::unique_ptr<ClickProgram> click;
        bool timecode = false;
        std::vector<PlaybackNote> midiNotes;
        std::vector<MIDIPlayback::Event> externalEvents;
        MidiBuffer externalMIDI[2];
        double externalExpected[2]{-1,-1};
        jaras::PlaybackScope externalScopes[2];
        std::unique_ptr<MIDIPlayback> midi;
        MidiBuffer midiMessages;
        int midiSlot = 0, midiChannel = 0;
        int inputFirst = 0, inputChannels = 2;
        bool inputMonitoring = true;
        std::atomic<bool> armed{false};
        std::atomic<bool> fadeoutSelected{false};
    };
    struct LatencyPlan {
        struct Route { int target=-1;native::StereoDelay delay[2]; };
        struct Channel {
            unsigned own=0,input=0,output=0;
            native::StereoDelay direct[2],inputDelay[2],master[2],hardware[2],frozen[2];
            AudioBuffer<float> routed[2];
            std::vector<Route> routes;
        };
        std::vector<Channel> buses;
        std::map<ID,std::array<native::StereoDelay,2>> clips,clipBypass;
        unsigned masterInput=0,total=0;
        native::TimelineDelay timeline[2];
        native::StereoDelay masterLive,masterHardware,metronome;
        AudioBuffer<float> scratch{2,4096},hardwareScratch{2,4096},metronomeBuffer{2,4096};
    };
    std::unique_ptr<LatencyPlan> latencyPlan;
    std::unique_ptr<LatencyPlan> makeLatencyPlan(const ID *replacement=nullptr,const NativeFX *prepared=nullptr)const;
    bool offlineMode=false;
    uint64 stemLatencyFingerprint=0;
    std::atomic<bool> presentationTailing{false};
    std::atomic<unsigned> presentationDelay{0};
    std::atomic<double> presentedPosition[2]{};
    std::atomic<bool> presentedPlaying[2]{};
    unsigned tailFrames[2]{};
    double tailCursor[2]{};
    uint64_t renderClock=0;
    void resetLatencyHead(int head,double at)noexcept;
    void publishLatency()noexcept;
    uint64 stemFingerprint()const;
    void activateStemLatency();
    std::vector<std::unique_ptr<Bus>> buses;
    std::vector<int> busOrder;
    TransportFadeout transportFadeout;
    std::array<float, 4096> trackFadeoutGains{};
    NativeFX masterFX;
    AutomationProgram masterAutomation;
    std::unique_ptr<MIDIPlayback> masterMIDI;
    File instrumentDirectory;
    std::atomic<int> keyboardTarget{-1};
    var masterFXSettings;
    AudioBuffer<float> masterBuffer{2, 4096};
    AudioBuffer<float> readScratch[2]{{2, 131080}, {2, 131080}};
    AudioBuffer<float> liveRecordBuffer{2, 4096};
    std::array<std::array<double, 4096>, 2> timelinePositions{};
    std::array<std::array<bool,4096>,2> timelineRunning{};
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
    std::array<int, 128> outputMapping{};
    std::atomic<double> rate{48000}, position{0}, subPosition{0};
    std::atomic<bool> playing{false}, subPlaying{false};
    std::atomic<uint64> elapsedSamples{0}, underruns{0};
    std::atomic<float> meter{0};
    std::array<std::atomic<float>, 2> masterLevels{};
    std::atomic<float> masterFXInput{0}, masterFXOutput{0};
    struct Update {
        enum Kind { transport, mixer, item } kind = transport;
        bool inputMonitoring=true;
        int midiSlot=0,midiChannel=0;
        State state;
        double itemGain=1, itemPan=0, fadeIn=0, fadeOut=0;
        jaras::FadeCurve fadeInShape, fadeOutShape;
        bool fxBypassed=false;
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
