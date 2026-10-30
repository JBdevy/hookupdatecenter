#pragma once
#include "SystemAudioDefaults.h"
#include "NativeAudioDeviceHost.h"
#include "../../Core/Audio/RealtimeCommandQueue.hpp"
#include "../../Core/Audio/PreparedAudioEdits.hpp"
#include "../../Core/Audio/RealtimeLatestValue.hpp"
#include "../../Core/Audio/RealtimeBorrowedPointer.hpp"
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
#include "RealtimeMIDIInput.h"
#include "AudioCallbackMetrics.h"
namespace catlive {
class ClipAudio;
// Prepared readers, buffers and routing live outside the device callback.
class AudioEngine final : public AudioIODeviceCallback, private MidiInputCallback, private MidiKeyboardState::Listener, private Timer {
  public:
    VinhetasAudio vinhetas;

    struct State {
        double position = 0, subPosition = 0;
        bool playing = false, subPlaying = false, loop = false;
        uint64 promotion = 0;
        bool followMainClock = false; // automatic Subplay joins a running main head without seeking it
        bool preserveLatency = false; // scheduled musical transition, not a manual seek
        double loopStart = 0, loopEnd = 0;
        jaras::PlaybackScope scope[2], exclusiveScope[2];
        int timecodePreferred = -1;
        double end = std::numeric_limits<double>::infinity();
    };
    AudioEngine(double preparationRate = 48000, bool preparingOffline = false,
                std::shared_ptr<AudioDeviceManager> host = {});
    ~AudioEngine() override;
    std::shared_ptr<AudioDeviceManager> deviceHost;
    AudioDeviceManager &devices;
    SystemAudioDefaults systemDefaults;
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
    void setMIDIOutputSlot(int slot, const String &device) { timecodeMIDI.setOutputSlot(slot, device); }
    uint64 latestProgramChange(int slot) const {
        if(slot == -1) { uint64 latest=0;for(const auto &packet:midiProgramChanges)latest=std::max(latest,packet.load());return latest; }
        return slot>=1 && slot<=6 ? midiProgramChanges[size_t(slot-1)].load() : 0;
    }
    std::array<std::atomic<uint64>,6> midiProgramChanges{};
    std::atomic<uint64> programChangeSerial{0};
    std::atomic<int> keyboardChannel{0}; // 0 = Omni
    std::atomic<bool> metronomeEnabled{false};
    void closeDevice();
    void refreshTiming(const jaras::Song &song);
    void refreshTempo(const jaras::Song &before, const jaras::Song &after);
    void refreshItemPitch(const jaras::Song &, const ID &);
    void refreshRegionPitch(const jaras::Song &, const ID &);
    struct PreparationControl {
        std::function<void()> checkpoint;
        std::function<void(int, int)> progress;
        NativeFX::Dispatcher pluginDispatcher;
    };
    void prepareSong(const jaras::Song &, const File &directory, const var &masterSettings = {},
                     const jaras::Project *project = nullptr, const PreparationControl *control = nullptr);
    bool preparesOffline() const { return offlineMode; }
    bool hasLiveDevice() const { return attached || externalRenderDriven; }
    // A native host (or the driver-free callback harness) owns render calls.
    // Change only before starting or after joining that external callback.
    void setExternalRenderDriven(bool enabled) {
        if (attached) throw std::runtime_error("An audio device already owns rendering.");
        externalRenderDriven = enabled;
    }
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
    bool cacheSplitItems(const jaras::Song &, const std::map<ID, ID> &);
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
    double changeRecordingTargets(const std::vector<TrackCapture::Target> &, const std::set<ID> &, int bits);
    std::vector<TrackCapture::Take> stopTrackRecording();
    // Control detaches at a completed block. The returned owner may finalize
    // files on a worker without keeping either the UI or audio callback busy.
    std::shared_ptr<TrackCapture> detachTrackRecording();
    void recordingCompleted(uint64 dropped) noexcept { recordingDrops.store(dropped); }
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
    // Registry lookup/handle acquisition belongs to the serialized control/UI
    // thread, never the callback. Retained handles are safe after graph retirement;
    // reacquire after a document graph change to follow its new generation.
    std::shared_ptr<const audio::TrackMeterState> trackMeterState(const ID &id) const {
        const auto found = trackMeters.find(id);
        return found == trackMeters.end() ? nullptr : found->second;
    }
    std::pair<float, float> fxLevels(const ID &id) const {
        if (id.empty()) return {masterFXInput.load(), masterFXOutput.load()};
        const auto found = trackMeters.find(id);
        if (found != trackMeters.end())
            return {found->second->fxInput.load(), found->second->fxOutput.load()};
        return {};
    }
    float trackPeak(const ID &id) const {
        const auto found = trackMeters.find(id);
        return found == trackMeters.end() ? 0 : found->second->peak.load(std::memory_order_relaxed);
    }
    std::array<float, 2> meterLevels(const ID &id = {}) const {
        if (id.empty()) return {masterLevels[0].load(), masterLevels[1].load()};
        const auto found = trackMeters.find(id);
        if (found != trackMeters.end())
            return {found->second->levels[0].load(), found->second->levels[1].load()};
        return {};
    }
    float heldPeak(const ID &id = {}) const {
        if (id.empty()) return masterPeakHold.amplitude();
        const auto found = trackMeters.find(id);
        return found == trackMeters.end() ? 0 : found->second->held.amplitude();
    }
    void clearPeak(const ID &id = {}) {
        if (id.empty()) masterPeakHold.clear();
        else {
            const auto found = trackMeters.find(id);
            if (found != trackMeters.end()) found->second->held.clear();
        }
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
        uint64 caches = 0, inactive = 0, fallbackOpens = 0, transitionOpens = 0;
        for (const auto& voice : voices) if (voice->source) for (const auto& reader : voice->source->readers)
            if (unique.insert(reader.get()).second) {
                caches += reader->cacheMisses.load();
                inactive += reader->inactiveMisses.load();
                fallbackOpens += reader->fallbackOpens.load();
                transitionOpens += reader->transitionOpens.load();
            }
        auto result = object();
        put(result, "cacheMisses", (int64)caches); put(result, "inactiveMisses", (int64)inactive);
        put(result, "fallbackDecoderOpens", (int64)fallbackOpens);
        put(result, "transitionDecoderOpens", (int64)transitionOpens);
        uint64 midiDrops=midiInput.droppedCount()+virtualKeyboardInput.droppedCount();
        uint64 midiUnsupported=midiInput.unsupportedCount()+virtualKeyboardInput.unsupportedCount();
        for(const auto &slot:midiSlots){midiDrops+=slot.droppedCount();midiUnsupported+=slot.unsupportedCount();}
        put(result,"midiInputDroppedEvents",(int64)midiDrops);
        put(result,"midiInputUnsupportedMessages",(int64)midiUnsupported);
        uint64 midiBuilderOverflows=masterMIDI?masterMIDI->builderOverflows():0;
        for(const auto& bus:buses) {
            for(const auto& messages:bus->externalMIDI)midiBuilderOverflows+=messages.overflows();
            if(bus->midi)midiBuilderOverflows+=bus->midi->builderOverflows();
        }
        for(const auto& voice:voices)for(const auto& messages:voice->midiMessages)midiBuilderOverflows+=messages.overflows();
        put(result,"midiBuilderOverflows",(int64)midiBuilderOverflows);
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
            for(size_t i=0;i<std::min(size_t(16),bus->externalSequence.notes.size());++i)pitches.add(bus->externalSequence.notes[i].pitch);
            put(midi,"track",text(bus->id));put(midi,"noteCount",(int64)bus->externalSequence.notes.size());put(midi,"pitches",pitches);trackMIDI.add(midi);
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
    double cpu() const { return audioDeviceCpuUsage(devices); }
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
    uint64 publishedPromotion=0;
    std::array<std::atomic<int>,2> readerHeads{{0,1}};
    bool publishPromotion(const State &);
    void promotePlaybackHeads();
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
    struct Update {
        bool resetElapsed=false;
        uint64 transportSerial=0;
        enum Kind { transport, mixer, item, routing, promotion, preparedEdit } kind = transport;
        audio::PreparedAudioEdits::Ticket* edit = nullptr;
        bool inputMonitoring=true, subplayExclusive=false;
        int midiSlot=0,midiChannel=0;
        State state;
        double itemGain=1, itemPan=0, fadeIn=0, fadeOut=0;
        jaras::FadeCurve fadeInShape, fadeOutShape;
        bool fxBypassed=false;
        int index = -1;
        float volume = 1, pan = 0;
        bool mute = false, solo = false, mono = false, phase = false;
    };
    struct Voice {
        ID track, clipID;
        std::optional<double> playbackStart;
        std::uint32_t regionOwnerIndex=0;
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
        BoundedMIDIBuffer midiMessages[2]{BoundedMIDIBuffer(false),BoundedMIDIBuffer(false)};
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
    const jaras::PlaybackScope& trackScope(const State& state, int head, size_t bus) const {
        return buses[bus]->subplayExclusive ? state.exclusiveScope[head] : state.scope[head];
    }
    void mixMIDIVoice(Voice &, int head, double at, float *const *out, int channels,
                      int dest, int count, bool running);
    struct Bus {
        ID id;
        audio::RealtimeLatestValue<Update> mixerUpdates;
        float volume = 1, pan = 0;
        bool mute = false, solo = false, phase = false;
        // Audio-thread scratch state lives with the bus; no fixed track-count arrays.
        bool renderAudible = false, renderRouteAudible = false;
        int parent = -1;
        std::vector<jaras::OutputPatch> outputs;
        std::vector<int> sends;
        // Allocated during preparation. Rendering never copies/releases this owner.
        std::shared_ptr<audio::TrackMeterState> meters = std::make_shared<audio::TrackMeterState>();
        AudioBuffer<float> buffer{2, 4096};
        AudioBuffer<float> subBuffer{2, 4096};
        AudioBuffer<float> frozen[2]{{2,4096},{2,4096}};
        AudioBuffer<float> clips[2]{{2,4096},{2,4096}};
        AudioBuffer<float> &head(int index) { return index == 0 ? buffer : subBuffer; }
        NativeFX fx[2];
        AutomationProgram automation;
        var settings;
        std::unique_ptr<ClickProgram> click;
        bool timecode = false, vinhetasBus = false, subplayExclusive = false;
        MIDIPlayback::Sequence externalSequence;
        BoundedMIDIBuffer externalMIDI[2];
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
    struct LatencyEdit {
        std::unique_ptr<LatencyPlan> next;
        std::vector<std::pair<native::StereoDelay*,native::StereoDelay*>> retained;
        bool sameTotal=false;
        explicit operator bool()const noexcept{return bool(next);}
    };
    LatencyEdit prepareLatencyEdit(std::unique_ptr<LatencyPlan>);
    std::unique_ptr<LatencyPlan> makeLatencyPlan(const ID *replacement=nullptr,const NativeFX *prepared=nullptr,
                                                std::optional<bool> midiTakeActive={},bool admitReady=false,
                                                bool releaseRemoved=false, const std::vector<Voice *> *itemVoices=nullptr,
                                                const std::vector<TrackRoute> *routes=nullptr, const std::vector<int> *order=nullptr)const;
    // Only explicit playback from Stop; queues, loops and exports retain their attacks.
    double playbackStartRamp[2]{-1, -1};
    uint64 playbackStartFrame[2]{};
    bool offlineMode=false;
    bool offlineRendering=false;
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
    void installLatencyPlan(LatencyEdit &,bool preservePlayback)noexcept;
    uint64 stemFingerprint(bool admitReady=false,bool releaseRemoved=false)const;
    void activateStemLatency(bool releaseRemoved=true);
    std::vector<std::unique_ptr<Bus>> buses;
    // Only the control thread traverses/mutates the registry. Each callback bus
    // already owns its payload; meters do not require traversing DSP objects.
    std::map<ID, std::shared_ptr<audio::TrackMeterState>> trackMeters;
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
    // The control side owns and recycles command blocks. Overflow never makes
    // the producer consume commands under the device callback lock.
    audio::RealtimeCommandQueue<Update> updates;
    audio::RealtimeLatestValue<Update> masterUpdates;
    audio::PreparedAudioEdits preparedEdits;
    State current;
    float masterVolume = 1, masterPan = 0;
    bool masterMute = false, masterMono = false, masterPhase = false, masterSolo = false;
    bool instrumentWasAllowed = false;
    double duration = 0;
    bool attached = false;
    bool externalRenderDriven = false;
    bool exportCapture = false;
    int exportBus = -1;
    TimeSliceThread recordingThread{"CatLive recording"};
    std::unique_ptr<BufferedAudioWriter> recorder;
    audio::RealtimeBorrowedPointer<BufferedAudioWriter> recorderSlot;
    struct RecordingOutput { ID track; std::unique_ptr<NativeFX> fx; };
    struct RecordingState {
        std::unique_ptr<TrackCapture> capture;
        std::vector<RecordingOutput> outputs;
    };
    // Control owns this state and prepared FX tickets may retain it. The audio
    // block borrows a raw pointer; it never acquires/releases shared ownership.
    std::shared_ptr<RecordingState> recordingSession;
    audio::RealtimeBorrowedPointer<RecordingState> recordingSlot;
    std::vector<RecordingOutput> prepareRecordingOutputs(const std::vector<TrackCapture::Target> &);
    std::atomic<uint64> recordedFrames{0};
    std::array<int, 128> inputMapping{};
    std::atomic<bool> recording{false};
    std::atomic<uint64> recordingDrops{0};
    RealtimeMIDIInput midiInput, midiSlots[6], virtualKeyboardInput;
    MidiBuffer slotMessages[6], keyboardMidi;
    String midiDevices[6];
    CriticalSection midiRoutingLock;
    MidiBuffer liveMidi;
    void handleIncomingMidiMessage(MidiInput *, const MidiMessage &) override;
    void handleNoteOn(MidiKeyboardState *, int, int, float) override;
    void handleNoteOff(MidiKeyboardState *, int, int, float) override;
    void enqueue(const Update &);
    template<class Work> audio::PreparedAudioEdits::Ticket* enqueuePreparedEdit(Work&& work) {
        auto* ticket = preparedEdits.prepare(std::forward<Work>(work));
        Update update; update.kind = Update::preparedEdit; update.edit = ticket;
        try { enqueue(update); }
        catch (...) { preparedEdits.cancelUnpublished(ticket); throw; }
        return ticket;
    }
    template<class Work> void commitPreparedEdit(Work&& work) {
        waitPreparedEdit(enqueuePreparedEdit(std::forward<Work>(work)));
    }
    // Control only. Waits for an audio boundary; never takes the device lock.
    // A device failure cancels a not-yet-started edit before its stack expires.
    void waitPreparedEdit(audio::PreparedAudioEdits::Ticket*);
    void applyUpdates(size_t budget = std::numeric_limits<size_t>::max(),
                      TrackCapture* capture = nullptr, bool fromCallback = false);
    void mixVoice(Voice &, int head, double at, float *const *, int channels, int dest, int count);
    void audioDeviceIOCallbackWithContext(const float *const *, int, float *const *, int, int,
                                          const AudioIODeviceCallbackContext &) override;
    void audioDeviceAboutToStart(AudioIODevice *) override;
    bool asioCallbackScheduling = false; // configured before the driver starts callbacks
    void audioDeviceStopped() override;
};
} // namespace catlive
