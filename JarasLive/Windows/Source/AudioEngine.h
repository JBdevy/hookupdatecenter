#pragma once
#include "VinhetasAudio.h"
#include "../../Core/Tracks/ItemFade.hpp"
#include "Common.h"
#include "MeterDisplay.h"
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
#include "AudioCallbackMetrics.h"
namespace catlive {
class ClipAudio;
// Prepared readers, buffers and routing live outside the device callback.
class AudioEngine final : public AudioIODeviceCallback, private MidiInputCallback, private Timer {
  public:
    VinhetasAudio vinhetas;

    struct State {
        double position = 0, subPosition = 0;
        bool playing = false, subPlaying = false, loop = false;
        bool preserveLatency = false; // scheduled musical transition, not a manual seek
        double loopStart = 0, loopEnd = 0;
        jaras::PlaybackScope scope[2];
        int timecodePreferred = -1;
        double end = std::numeric_limits<double>::infinity();
    };
    AudioEngine(double preparationRate = 48000, bool preparingOffline = false,
                std::shared_ptr<AudioDeviceManager> host = {});
    ~AudioEngine() override;
    std::shared_ptr<AudioDeviceManager> deviceHost;
    AudioDeviceManager &devices;
    AudioCallbackMetrics callbackMetrics;
    AudioFormatManager formats;
    MidiKeyboardState keyboardState;
    Instrument instrument;
    std::atomic<bool> instrumentAllowed{false};
    std::atomic<bool> liveInputEnabled{true};
    void loadSoundFont(const File &);
    // Enforced only for a real device session; offline rendering stays independent.
    bool deviceSessionRequested = false;
    String outputAvailabilityError() const;
    String openDevice();
    void configureDeviceChannels(const BigInteger &inputs, const BigInteger &outputs);
    void configureMetronome(const var &);
    void setEffects(const ID &, const var &);
    std::shared_ptr<native::vst3::Processor> externalEffect(const ID &, const String &) const;
    void captureExternalEffects(const ID &, var &) const;
    native::stem::Status stemStatus(const ID &,const String &)const;
    std::array<std::shared_ptr<analysis::Capture>, 2> eqAnalysis(const ID &, const String &key) const;
    void waitForStems();
    void previewDynamics(const ID &, const String &, const var &);
    void previewNativeParameters(const ID &, const String &key, const String &kind, const var &, const var &chainSettings = {});
    void previewStemMix(const ID &,const String &,const native::stem::Mix &);
    void checkStemErrors()const;
    void refreshStemLatency();
    unsigned exportLatencyFrames()const;
    void setMIDISlot(int, const String &);
    std::atomic<int> keyboardChannel{0}; // 0 = Omni
    std::atomic<bool> metronomeEnabled{false};
    void closeDevice();
    void refreshTiming(const jaras::Song &song);
    void refreshTempo(const jaras::Song &before, const jaras::Song &after);
    void refreshRegionPitch(const jaras::Song &, const ID &);
    struct PreparationControl {
        std::function<void()> checkpoint;
        std::function<void(int, int)> progress;
        NativeFX::Dispatcher pluginDispatcher;
    };
    void prepareSong(const jaras::Song &, const File &directory, const var &masterSettings = {},
                     const jaras::Project *project = nullptr, const PreparationControl *control = nullptr);
    bool preparesOffline() const { return offlineMode; }
    bool hasLiveDevice() const { return attached; }
    // Message thread only: swaps a fully prepared, unattached engine's graph.
    // The argument receives the retired graph and must be disposed off the UI.
    void adoptPreparedSong(AudioEngine &, bool preservePlayback = false);
    void transport(const State &);
    // Interactive transport prepares disk reads off the message thread. Offline
    // rendering retains the synchronous entry point above.
    void transportAsync(const State &);
    void prewarmTransportDestination(const std::optional<State> &);
    bool preparingTransport() const;
    bool transportClockPending() const {
        return preparingTransport() || appliedTransportSerial.load() != transportSerial;
    }
    void updateTransportRouting(const State &);
    void primeLoop(const State &);
    int timecodePreferred(const std::optional<ID>& region) const { return timecodeProgram.preferred(region); }
    void previewMIDIItem(const jaras::Song &,const jaras::AudioClip &);
    void refreshItemTiming(const jaras::Song &, const jaras::AudioClip &);
    bool refreshItemPresence(const jaras::Song &);
    void setItemControls(const jaras::AudioClip &);
    void setMixer(const jaras::Project &, const jaras::Song &);
    bool refreshTrackRouting(const jaras::Song &);
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
    float heldPeak(const ID &id = {})const {
        if(id.empty())return masterPeakHold.amplitude();
        for(const auto &bus:buses)if(bus->id==id)return bus->held.amplitude();
        return 0;
    }
    void clearPeak(const ID &id = {}) {
        if(id.empty())masterPeakHold.clear();
        else for(auto &bus:buses)if(bus->id==id){bus->held.clear();break;}
    }
    uint64 getUnderruns() const { return underruns.load(); }
    std::set<String> activeMediaPaths() const {
        std::set<String> paths;
        for (const auto &voice : voices) if (voice->source)
            paths.insert(unicodeCase(voice->source->file.getFullPathName(), false));
        for (const auto &voice : removedItemVoices) if (voice->source)
            paths.insert(unicodeCase(voice->source->file.getFullPathName(), false));
        for (const auto &source : retiredSources) if (source)
            paths.insert(unicodeCase(source->file.getFullPathName(), false));
        return paths;
    }
    int residentStreams() const {
        std::set<const StreamingReader*> active;
        for (const auto& voice : voices) if (voice->source) for (const auto& reader : voice->source->readers)
            if (reader->cached()) active.insert(reader.get());
        return (int)active.size();
    }
    var streamDiagnostics() const {
        std::set<const StreamingReader*> unique;
        uint64 caches = 0, inactive = 0;
        for (const auto& voice : voices) if (voice->source) for (const auto& reader : voice->source->readers)
            if (unique.insert(reader.get()).second) {
                caches += reader->cacheMisses.load();
                inactive += reader->inactiveMisses.load();
            }
        auto result = object();
        put(result, "cacheMisses", (int64)caches); put(result, "inactiveMisses", (int64)inactive);
        put(result, "primedSources", lastPrimedSources);
        put(result, "primeWaitMilliseconds", lastPrimeWaitMilliseconds);
        put(result, "preparingTransport", preparingTransport());
        put(result, "transportCommitPending", appliedTransportSerial.load()!=transportSerial);
        put(result, "transportCommits", (int64)transportSerial);
        put(result, "transportRepositions", (int64)transportRepositions);
        put(result, "voiceCount", (int)voices.size()); put(result, "busCount", (int)buses.size());
        int processors = 0;
        Array<var> trackEffects, itemEffects, trackMIDI;
        for (const auto &bus : buses) {
            const auto inserted = get(bus->settings, "inserted");
            if (!list(inserted).isEmpty()) { auto entry=object();put(entry,"track",text(bus->id));put(entry,"effects",inserted);trackEffects.add(entry); }
            // Bounded MIDI samples make identity/routing regressions observable
            // without dumping a whole score or walking all of its notes.
            auto midi=object();Array<var> pitches;
            for(size_t i=0;i<std::min(size_t(16),bus->midiNotes.size());++i)pitches.add(bus->midiNotes[i].pitch);
            put(midi,"track",text(bus->id));put(midi,"noteCount",(int64)bus->midiNotes.size());put(midi,"pitches",pitches);trackMIDI.add(midi);
        }
        for (const auto &voice : voices) {
            processors += voice->clipAudio ? 1 : 0;
            const auto inserted = get(voice->fxSettings, "inserted");
            if (!list(inserted).isEmpty()) {auto entry=object();put(entry,"item",text(voice->clipID));put(entry,"effects",inserted);itemEffects.add(entry);}
        }
        put(result, "clipProcessors", processors); put(result, "trackEffects", trackEffects); put(result,"trackMIDI",trackMIDI);
        put(result, "itemEffects", itemEffects); put(result, "masterEffects", get(masterFXSettings,"inserted"));
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
    struct ReaderContext;
    std::shared_ptr<ReaderContext> readerContext;
    struct Source {
        File file;
        int64 fileSize = 0;
        Time modified;
        // Declared before readers: their thread/format references outlive them,
        // including after an isolated graph moves into the active device.
        std::shared_ptr<ReaderContext> context;
        std::unique_ptr<StreamingReader> readers[2];
    };
    struct TransportRead {
        std::shared_ptr<Source> source;
        int head; int64 position; int count; bool loop;
        StreamingReader &reader() const { return *source->readers[head]; }
    };
    struct TransportPreparation {
        State state;
        std::vector<TransportRead> reads;
        std::atomic<bool> cancelled{false}, done{false};
        bool sendTransport=false, routingOnly=false, destinationOnly=false;
        double milliseconds=0;
    };
    std::unique_ptr<ThreadPool> transportWorker;
    std::shared_ptr<TransportPreparation> transportPreparation;
    std::shared_ptr<TransportPreparation> queuedPreparation;
    bool asynchronousTransport=false;
    uint64 transportRepositions=0; // Message-thread diagnostics for full head updates.
    uint64 transportSerial=0; // Message-thread writer; carried to the callback.
    std::atomic<uint64> appliedTransportSerial{0};
    std::vector<TransportRead> transportReads(const State &);
    void cancelTransportPreparation(bool all=true);
    void scheduleTransportPreparation(const State &, bool routingOnly);
    void runTransportPreparation(const std::shared_ptr<TransportPreparation> &);
    void commitPreparedTransport(const State &, bool routingOnly=false);
    void timerCallback() override;
    // Unused prepared readers retire with the outgoing graph on its worker.
    std::vector<std::shared_ptr<Source>> retiredSources;
    struct Voice {
        ID track, clipID;
        std::optional<double> playbackStart;
        double start = 0, duration = 0, offset = 0, speed = 1, clipGain = 1, clipPan = 0,
               fadeIn = 0, fadeOut = 0;
        jaras::FadeCurve fadeInShape, fadeOutShape;
        int channelMode = 0;
        std::shared_ptr<Source> source;
        // MIDI items have no disk reader. Each take owns two independent FX
        // chains and clocks, while unowned notes keep using the track instrument.
        bool midiItem = false, midiInstrument = false;
        MIDIPlayback::Sequence midiSequence;
        std::vector<PlaybackNote> sharedMIDINotes;
        MidiBuffer midiMessages[2];
        double midiExpected[2]{-1, -1};
        jaras::PlaybackScope midiScopes[2];
        std::unique_ptr<ClipTempo> midiTiming;
        bool ownsMIDI() const { return midiItem && midiInstrument && !fxBypassed; }
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
    struct SharedMIDIUpdate {
        MIDIPlayback::Sequence external, synth;
        explicit SharedMIDIUpdate(std::vector<PlaybackNote> notes)
            : external(MIDIPlayback::sequence(std::move(notes))), synth(external) {}
    };
    SharedMIDIUpdate sharedMIDISequence(size_t bus, const Voice *replacement = nullptr,
                                       bool ownsReplacement = false) const;
    void replaceSharedMIDI(size_t bus, SharedMIDIUpdate &);
    void mixMIDIVoice(Voice &, int head, double at, float *const *out, int channels,
                      int dest, int count, bool running);
    struct Bus {
        ID id;
        float volume = 1, pan = 0;
        bool mute = false, solo = false, phase = false;
        // Audio-thread scratch state lives with the bus; no fixed track-count arrays.
        bool renderAudible = false, renderRouteAudible = false;
        int parent = -1;
        std::vector<jaras::OutputPatch> outputs;
        std::vector<int> sends;
        std::atomic<float> peak{0};
        meterDisplay::PeakHold held;
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
        bool timecode = false, vinhetasBus = false;
        std::vector<PlaybackNote> midiNotes;
        std::vector<MIDIPlayback::Event> externalEvents;
        MidiBuffer externalMIDI[2];
        double externalExpected[2]{-1,-1};
        jaras::PlaybackScope externalScopes[2];
        std::unique_ptr<MIDIPlayback> midi;
        MidiBuffer midiMessages;
        VirtualKeyboardRoute keyboardRoute;
        int midiSlot = 0, midiChannel = 0;
        int inputFirst = 0, inputChannels = 2;
        bool inputMonitoring = true;
        std::atomic<bool> armed{false};
        std::atomic<bool> fadeoutSelected{false};
    };
    struct TrackRoute { int parent=-1; std::vector<jaras::OutputPatch> outputs; };
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
    std::unique_ptr<LatencyPlan> makeLatencyPlan(const ID *replacement=nullptr,const NativeFX *prepared=nullptr,
                                                std::optional<bool> midiTakeActive={},bool admitReady=false,
                                                bool releaseRemoved=false, const std::vector<Voice *> *itemVoices=nullptr,
                                                const std::vector<TrackRoute> *routes=nullptr, const std::vector<int> *order=nullptr)const;
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
    void installLatencyPlan(std::unique_ptr<LatencyPlan> &,bool preservePlayback)noexcept;
    uint64 stemFingerprint(bool admitReady=false,bool releaseRemoved=false)const;
    void activateStemLatency(bool releaseRemoved=true);
    std::vector<std::unique_ptr<Bus>> buses;
    std::vector<int> busOrder;
    TransportFadeout transportFadeout;
    std::array<float, 4096> trackFadeoutGains{};
    NativeFX masterFX;
    AutomationProgram masterAutomation;
    std::unique_ptr<MIDIPlayback> masterMIDI;
    File instrumentDirectory;
    var masterFXSettings;
    AudioBuffer<float> masterBuffer{2, 4096};
    AudioBuffer<float> readScratch[2]{{2, 131080}, {2, 131080}};
    AudioBuffer<float> liveRecordBuffer{2, 4096};
    AudioBuffer<float> outputRecordBuffers[4]{{2,4096},{2,4096},{2,4096},{2,4096}};
    AudioBuffer<float> outputRecordScratch{2,4096};
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
    std::vector<std::unique_ptr<Voice>> voices;
    // Deleted items retain their existing readers/FX for immediate Undo. A full
    // project/graph replacement retires this cache with its owning engine.
    std::vector<std::unique_ptr<Voice>> removedItemVoices;
    std::set<ID> preparedItemIDs;
    std::array<int, 128> outputMapping{};
    std::atomic<double> rate{48000}, position{0}, subPosition{0};
    std::atomic<bool> playing{false}, subPlaying{false};
    std::atomic<uint64> elapsedSamples{0}, underruns{0};
    std::atomic<float> meter{0};
    meterDisplay::PeakHold masterPeakHold;
    ID peakProject;
    std::array<std::atomic<float>, 2> masterLevels{};
    std::atomic<float> masterFXInput{0}, masterFXOutput{0};
    struct Update {
        bool resetElapsed=false;
        uint64 transportSerial=0;
        enum Kind { transport, mixer, item, routing } kind = transport;
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
    // Allocate once when constructing the engine, outside the audio callback.
    // Embedding 1024 transport/mixer commands made nested offline render engines
    // exceed the Windows thread stack during export/re-render integration tests.
    std::unique_ptr<Update[]> updates = std::make_unique<Update[]>(1024);
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
