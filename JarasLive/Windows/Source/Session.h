#pragma once
#include "AudioEngine.h"
#include "TapTempo.h"
#include "../../Core/Transport/TempoEditGate.hpp"
#include "MediaDropLayout.h"
#include "ProjectCodec.h"
#include "AudioExport.h"
#include "TransportPresentation.h"
#include <deque>
#include "TemporaryProjectSession.h"
namespace catlive {
struct MultitrackExportProject;
class Session final : private Timer {
  public:
    explicit Session(std::shared_ptr<AudioDeviceManager> host = {});
    ~Session() override;
    // Declared before audio: scratch cleanup runs after its readers are destroyed.
    std::unique_ptr<TemporaryProjectSession> temporarySession;
    bool isTemporary() const { return temporarySession && temporarySession->contains(document); }
    void cleanupReplacedTemporary();
    jaras::Engine core;
    AudioEngine audio;
    const jaras::Project &project() const { return core.project(); }
    const jaras::Song *song() const { return core.currentSong(); }
    const jaras::TransportState &transport() const { return core.transport(); }
    jaras::TransportState presentationTransport() const;
    File document, mediaDirectory;
    var original;
    bool dirty = false, busy = false, inspection = false;
    double importProgress = 0;
    struct RecordingItem { ID track; jaras::AudioClip clip; std::shared_ptr<RecordingPreview> preview; double passLimit = std::numeric_limits<double>::infinity(); double captureOffset = 0; };
    std::vector<RecordingItem> recordingItems;
    bool extendRecordingLoops();
    struct RecordingPianoFrame { double position, elapsed, passOffset; };
    std::optional<RecordingPianoFrame> recordingPianoFrame() const;
    bool subCursorVisible() const { return transport().queuedRegionId.has_value(); }
    double subCursorPosition(const jaras::TransportState &state) const {
        if (!state.subPlay.playing && state.queuedRegionId)
            if (const auto *current = song())
                for (const auto &part : current->parts)
                    if (part.id == *state.queuedRegionId) return part.startTime;
        return state.subPlay.position;
    }
    static float subCursorOpacity(double seconds) { return std::fmod(seconds, .9) < .45 ? 1.f : .3f; }
    std::optional<ID> focusedRegion;
    std::optional<ID> smkPart;
    String smkPartPanel; bool smkQueuedParts=false;
    uint64 setlistFocusRevision = 0;
    String message;
    String capacityWarning;
    double capacityWarningUntil = 0;
    bool rejectOverCapacity(std::optional<double> position = {}, bool assumingPlayback = false);
    String liveCapacityWarning() const { return Time::getMillisecondCounterHiRes() < capacityWarningUntil ? capacityWarning : String(); }

    StringArray projectReadWarnings;
    uint64 revision = 0;
    std::function<void()> changed, tick, selectionChanged, mixerChanged, transportChanged;
    std::function<void(bool)> timingChanged;
    std::function<void(String)> transportFadeoutWarning;
    std::function<void(String)> audioOutputWarning;
    void toggleTransportFadeout(bool enabled, const std::set<ID> &tracks, double seconds);
    void cancelTransportFadeout();
    void updateTransportFadeout();
    bool transportFadeoutActive() const { return fadeoutRequested; }
    double transportFadeoutRemaining() const { return audio.trackFadeoutRemainingSeconds(); }
    double transportFadeoutDuration() const { return fadeoutDuration; }
    const ID &transportFadeoutRunID() const { return fadeoutRunID; }
    double trackDisplayVolume(const ID &id, double volume) const { volume = audio.loopDisplayVolume(id, volume); return fadeoutRequested ? volume * audio.trackFadeoutGain(id) : volume; }
    bool trackDisplayMute(const ID &id, bool mute) const { return audio.loopDisplayMute(id, mute); }
    bool trackDisplaySolo(const ID &id, bool solo) const { return audio.loopDisplaySolo(id, solo); }
    bool trackFaderLocked(const ID &id) const;
    std::function<bool()> canPlay;
    std::function<void(const jaras::TransportState &)> playbackUpdate;
    static jaras::Project makeEmptyProject(String name);
    void newProject(String name = "Untitled");
    void createRecordingProject(String name, int channels, const File &target);
    void load(const File &);
    void loadAsync(const File &, std::function<void(String, double)> progress,
                   std::function<void()> beforeCommit, std::function<void(String)> completed,
                   std::function<void(StringArray)> missingMedia = {});
    void save(const File &);
    void saveAsync(const File &, std::function<void(String)> completed = {});
    bool isSaving() const { return activeSave != nullptr; }
    void waitForSave(std::function<void(String)> completed);
    void setReductionDraft(const var &);
    void saveReductionDraft();
    void renameProject(String);
    void cleanTimelineMedia(std::function<void(String)> completed);
    jaras::projectSync::Frame projectSyncFrame() { syncClock(); return core.projectSyncFrame(); }
    void applyProjectSync(const jaras::projectSync::Frame &, double elapsed, bool first, std::optional<ID> focused = {});
    void command(jaras::CommandKind, const ID &target = {}, double value = 0);
    void focusSetlistRegion(std::optional<ID>, bool force = false);
    void reconcileSetlistSelectionAfterAdvance(const jaras::TransportState &before);

    std::optional<std::pair<double,double>> selectedTimeRange() const;
    void selectTimeRange(double from, double to);
    void clearTimeRange();
    void configureSetlist(jaras::RegionSetlist);
    void editTimeline(const std::function<void(jaras::Project &)> &, bool allowTimingEdit = false);
    void editTrackSettings(const std::function<void(jaras::Project &)> &, bool routing = false);
    void refreshProjectionAudio();
    void editItemControls(const std::function<void(jaras::Project &)> &);
    void moveMarker(const ID &, double);
    std::function<void()> setlistChanged;
    ID duplicatePlaylistRegion(const ID &playlist, const ID &entry);
    double tempoBPM() const;
    std::pair<int, int> transportMeter() const;
    bool meterInputAllowed() const;
    void setTempo(double bpm);
    void resetTapTempo() { tempoTaps = {}; }
    void tapTempo(double time = Time::getMillisecondCounterHiRes() / 1000., const ID& source = {});
    bool tempoInputAllowed() const { return !transport().playing && !transport().subPlay.playing; }
    void setTypedTempo(double bpm) { if (tempoInputAllowed()) setTempo(bpm); }
    std::function<double()> tempoEditClock = [] { return Time::getMillisecondCounterHiRes() / 1000.; };
    void configureTiming(double bpm, int beats, int unit, jaras::ProjectTimeSettings);
    std::optional<int> firstAvailableMIDIInputSlot();
    void configureEffects(const ID &, const var &);
    void configureEffects(const std::map<ID, var> &);
    String copyEffect(const ID &source, const String &effect, const ID &destination, const String &before = {});
    String insertLibraryEffect(const ID &destination, const String &identity, const String &presetID,
                               const String &before = {}, bool itemTarget = false);
    void edit(const std::function<void(jaras::Project &)> &, bool rebuild = true, bool allowTimingEdit = false, bool regionOperation = false);
    void setTrackMixerComponents(const std::map<ID, int> &);
    std::function<void()> trackMixerComponentsChanged;
    void setTrackInstrumentIcon(const std::set<ID> &, std::optional<std::string>);
    void resizeItem(const ID &, double start, double end);
    void resizeItems(const std::map<ID, std::pair<double, double>> &);
    void setTrackInputMonitoring(const ID &, bool);
    void resizeSharedItemBoundary(const ID &, const ID &, double, std::optional<double> = {}, std::optional<double> = {});
    void resizeTeleprompterBoundary(const std::set<ID> &, const ID &, const ID &, double);
    std::vector<ID> duplicateTracks(const std::set<ID> &, const var *copiedDocument = nullptr,
                                  const std::map<ID, ID> &insertingAfter = {}, std::map<ID, ID> *createdMapping = nullptr);
    void editTrackHierarchy(const ID &, const std::function<void(jaras::Song &)> &);
    void undo();
    void redo();
    bool canUndo() const { return !undoHistory.empty(); }
    bool canRedo() const { return !redoHistory.empty(); }
    void importAudio(const Array<File> &, double at = 0);
    void importMedia(const Array<File> &, double at, ID targetTrack, MediaDropLayout layout, double gap,
                     std::function<void(String)> completion = {}, bool deferWaveform = false);
    void exportMix(const File &, int bits = 24);
    void exportAudio(ExportRequest);
    void exportMultitrack(std::vector<MultitrackExportProject>, std::function<void()> onCompleted);
    AudioExportProgress exportProgress() const { const ScopedLock guard(exportProgressLock); return exportPreview; }
    bool exportFailed = false;
    void renderItems(std::set<ID>, bool glue = false, int midiChannels = 0, std::function<void(std::set<ID>)> completed = {});
    void separateAudioItem(ID, std::function<void(std::set<ID>)> completed = {}, std::set<int> instruments = {});
    void detectRegionBPM(std::set<ID>);
    void detectSelectionBPM(double start, double end, std::shared_ptr<std::atomic<double>> progress,
                            std::function<void(String)> result);
    bool isDetectingBPM() const { return bpmCancellation != nullptr; }
    void cancelBPMDetection();
    void cancelExport() { exportCancelled = true; if(loadCancellation)loadCancellation->store(true); }
    void toggleRecording(bool stopPlayback = false);
    bool recordingCountInActive() const { return countingIn; }
    void updateRecordingTargets(bool starting = false);
    int recordArm(const ID &id) const {
        auto at = recordArms.find(id);
        return at == recordArms.end() ? 0 : at->second;
    }
    bool recordingArmed(const ID &id) const {
        return recordArm(id) == 1 || (recordArm(id) == 2 && recordSelections.count(id) != 0);
    }
    void cycleRecordArm(const ID &, const std::set<ID> &targets = {}, bool automatic = false);
    void mixerCommand(jaras::CommandKind, const ID &, const std::set<ID> &, double value = 0, bool clearAll = false);
    void soloTrackExclusively(const ID &);
    void beginMixerGesture(jaras::CommandKind kind, ID source) {
        mixerGestureSource = std::move(source); mixerGestureProject = project().id; mixerGestureKind = kind;
        mixerGestureTracks.clear();
        if(const auto* current=song()) {
            mixerGestureTracks.reserve(current->tracks.size());
            for(const auto& track:current->tracks) {
                jaras::Track state;state.id=track.id;state.role=track.role;
                state.volume=track.volume;state.pan=track.pan;state.mute=track.mute;state.solo=track.solo;
                state.phaseInverted=track.phaseInverted;state.stereoLinkPartner=track.stereoLinkPartner;
                mixerGestureTracks.push_back(std::move(state));
            }
        }
    }
    void endMixerGesture() { mixerGestureSource.clear(); mixerGestureTracks.clear(); }
    void setRecordingSelection(const ID &, const std::set<ID> &targets = {});
    void addTrack(String name = "Audio", String role = "other");
    void addSong(String);
    void renameTrack(ID, String);
    std::optional<jaras::ProgramChangeMarker> scanProgramChange(const ID&);
    ID insertProgramChange(const ID&, jaras::ProgramChangeMarker);
    bool copyProgramChange();
    bool pasteProgramChange();
    void selectProgramChange(const ID &id) { selectedProgramChange=id; if(!id.empty())programChangePasteReady=false; }
    const jaras::ProgramChangeMarker *selectedProgramMarker() const;
    ID selectedProgramChange;
    std::optional<jaras::ProgramChangeMarker> programChangeClipboard;
    bool programChangePasteReady=false;
    void removeProgramChange(const ID&, const ID&);
    ID programChangeScanTrack, programChangeScanProject;
    uint64 programChangeScanBaseline=0;
    bool scanningProgramChange(const ID &id) const { return programChangeScanProject==project().id && programChangeScanTrack==id; }
    uint64 scannedProgramChangePacket(const ID &id) const {
        if(scanningProgramChange(id) && song())for(const auto &track:song()->tracks)if(track.id==id) {
            const auto packet=audio.latestProgramChange(track.midiInput.value_or(0));
            return packet==programChangeScanBaseline?0:packet;
        }
        return 0;
    }
    void removeTrack(ID);
    void removeTracks(const std::set<ID> &);
    void setItemPitch(const ID &, double);
    void setRegionPitch(const ID &, int, std::vector<ID>, std::vector<ID>);
    void setMeter(int beats, int unit);
    void removeClip(ID);
    void removeClips(const std::set<ID> &);
    std::set<ID> splitClips(const std::set<ID> &, double);
    void addMarker(String, double, bool section = false);
    void addRegion(String, double, double);
    void reorderTrack(ID, ID);
    void reorderSong(ID, int);
    void makeInspectionProject(bool withAudioFixture = false);
    var snapshot() const;
    void restoreSnapshot(const var &);
    void notify();
    void notifyMixer();
    bool preparingLiveAudio() const { return graphCancellation != nullptr; }

  private:
    void loadPrepared(const File &, var, jaras::Project);
    struct TimeSelection { ID project, song; double start, end; };
    std::optional<TimeSelection> timeSelection;
    void focusTimelineRegion(double position, bool force = false);
    struct PitchHistory { ID region; std::optional<int> semitones; std::optional<std::vector<ID>> tracks, groups; };
    PitchHistory pitchHistory(const ID&) const;
    void applyPitchHistory(PitchHistory, bool recordHistory);
    struct ItemPitchHistory { ID song, item; std::optional<double> semitones; };
    ItemPitchHistory itemPitchHistory(const ID &) const;
    void applyItemPitchHistory(ItemPitchHistory, bool recordHistory);
    void notifyTiming(bool geometry);
    struct TimelineHistory { jaras::Project project; bool tempo = false, itemControls = false, mixerControls = false, routingControls = false; };
    void applyTimelineHistory(const TimelineHistory &, bool recordHistory);
    struct MarkerHistory { ID song; std::optional<std::vector<jaras::TimelineMarker>> markers; };
    struct ItemHistory { std::map<ID, std::vector<jaras::AudioClip>> tracks; };
    ItemHistory itemHistory(const ItemHistory &) const;
    void applyItemHistory(const ItemHistory &, bool recordHistory, const std::map<ID, ID> &splitSources = {});
    struct ItemTimingHistory { ID song; jaras::AudioClip clip; double songDuration; };
    ItemTimingHistory itemTimingHistory(const ID &) const;
    void applyItemTiming(const ItemTimingHistory &, bool recordHistory);
    void commitItemTiming(jaras::Project, const ID &, bool recordHistory);
    MarkerHistory markerHistory(const ID &) const;
    void applyMarkerHistory(const MarkerHistory &, bool recordHistory);
    struct TrackHierarchyHistory {
        struct Row { ID id; std::optional<ID> parent; std::optional<jaras::OutputPatch> patch,secondary; std::optional<std::vector<jaras::OutputPatch>> outputs; };
        ID song; std::vector<Row> rows;
    };
    TrackHierarchyHistory trackHierarchyHistory(const ID &) const;
    void applyTrackHierarchy(const TrackHierarchyHistory &, bool recordHistory);
    struct SetlistHistory { std::optional<jaras::RegionSetlist> state; };
    void applySetlistHistory(const SetlistHistory &, bool recordHistory);
    struct TrackMixerComponentsHistory { ID song; std::map<ID, int> masks; };
    TrackMixerComponentsHistory applyTrackMixerComponents(const TrackMixerComponentsHistory &);
    void notifyTrackMixerComponents();
    struct HistoryEntry {
        var project;
        std::optional<TimelineHistory> timeline;
        std::optional<PitchHistory> pitch;
        std::optional<ItemPitchHistory> itemPitch;
        std::optional<SetlistHistory> setlist;
        std::optional<MarkerHistory> markers;
        std::optional<std::map<ID, var>> effects;
        std::optional<ItemTimingHistory> itemTiming;
        std::optional<ItemHistory> items;
        std::optional<TrackHierarchyHistory> hierarchy;
        std::optional<TrackMixerComponentsHistory> components;
        HistoryEntry(ItemPitchHistory value) : itemPitch(std::move(value)) {}
        HistoryEntry(PitchHistory value) : pitch(std::move(value)) {}
        HistoryEntry(TimelineHistory value) : timeline(std::move(value)) {}
        HistoryEntry(SetlistHistory value) : setlist(std::move(value)) {}
        HistoryEntry(var value) : project(std::move(value)) {}
        HistoryEntry(MarkerHistory value) : markers(std::move(value)) {}
        HistoryEntry(std::map<ID, var> value) : effects(std::move(value)) {}
        HistoryEntry(ItemTimingHistory value) : itemTiming(std::move(value)) {}
        HistoryEntry(ItemHistory value) : items(std::move(value)) {}
        HistoryEntry(TrackHierarchyHistory value) : hierarchy(std::move(value)) {}
        HistoryEntry(TrackMixerComponentsHistory value) : components(std::move(value)) {}
    };
    // Appending an edit must not copy every prior project snapshot.
    std::deque<HistoryEntry> undoHistory, redoHistory;
    std::map<ID, var> currentEffects(const std::map<ID, var> &) const;
    void applyEffects(const std::map<ID, var> &, bool recordHistory);
    std::set<std::string> observedMedia;
    bool fadeoutRequested = false, completingFadeout = false;
    double fadeoutDuration = 3;
    ID fadeoutRunID;
    std::set<ID> fadeoutTracks;
    void warnTransportFadeout(String);
    struct ProjectSave;
    std::shared_ptr<ProjectSave> captureSave(const File &);
    static void writeSave(ProjectSave &);
    bool controlAllowedDuringSave(jaras::CommandKind) const;
    std::shared_ptr<ProjectSave> activeSave;
    ThreadPool saveWorker{1};
    ThreadPool worker{1};
    ThreadPool bpmWorker{1};
    std::shared_ptr<std::atomic<bool>> bpmCancellation;
    std::shared_ptr<std::atomic<bool>> loadCancellation;
    TapTempo tempoTaps;
    jaras::LiveTempoEditGate liveTempoEdits;
    std::shared_ptr<std::atomic<bool>> graphCancellation;
    std::shared_ptr<int> alive = std::make_shared<int>(0);
    ID preparedSong;
    File recordingFile;
    std::map<ID, int> recordArms;
    std::set<ID> recordSelections;
    std::set<ID> recordingActiveTracks;
    bool recordingFinalizing = false;
    enum class RecordingResume { none, play, record } recordingResume = RecordingResume::none;
    void resumeAfterRecordingPreparation();
    ID recordingSong;
    ID mixerGestureSource, mixerGestureProject;
    jaras::CommandKind mixerGestureKind = jaras::CommandKind::volume;
    std::vector<jaras::Track> mixerGestureTracks;
    void updateRecordArms();
    double recordingStart = 0;
    bool countingIn = false;
    void startRecording();
    void cancelRecordingCountIn();
    std::optional<std::pair<double,double>> recordingLoop;
    std::atomic<bool> exportCancelled{false};
    mutable CriticalSection exportProgressLock;
    AudioExportProgress exportPreview;
    TransportPresentationQueues presentationQueues;
    void timerCallback() override;
    void syncClock();
    void publishTransport(bool preserveLatency = false, bool routingOnly = false, bool followMainClock = false);
    void prepare();
    void prepareLiveGraph();
};
} // namespace catlive
