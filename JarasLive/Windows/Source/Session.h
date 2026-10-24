#pragma once
#include "AudioEngine.h"
#include "MediaDropLayout.h"
#include "ProjectCodec.h"
#include "AudioExport.h"
#include "TransportPresentation.h"
namespace catlive {
class Session final : private Timer {
  public:
    explicit Session(std::shared_ptr<AudioDeviceManager> host = {});
    ~Session() override;
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
    struct RecordingItem { ID track; jaras::AudioClip clip; std::shared_ptr<RecordingPreview> preview; };
    std::vector<RecordingItem> recordingItems;
    double subCursorPreviewUntil = 0;
    bool subCursorVisible() const { return presentationTransport().subPlay.playing || Time::getMillisecondCounterHiRes() < subCursorPreviewUntil; }
    static float subCursorOpacity(double seconds) { return std::fmod(seconds, .9) < .45 ? 1.f : .3f; }
    std::optional<ID> focusedRegion;
    uint64 setlistFocusRevision = 0;
    String message;
    uint64 revision = 0;
    std::function<void()> changed, tick, selectionChanged;
    std::function<void(String)> transportFadeoutWarning;
    std::function<void(String)> audioOutputWarning;
    void toggleTransportFadeout(bool enabled, const std::set<ID> &tracks, double seconds);
    void cancelTransportFadeout();
    void updateTransportFadeout();
    bool transportFadeoutActive() const { return fadeoutRequested; }
    double transportFadeoutRemaining() const { return audio.trackFadeoutRemainingSeconds(); }
    double transportFadeoutDuration() const { return fadeoutDuration; }
    double trackDisplayVolume(const ID &id, double volume) const { return fadeoutRequested ? volume * audio.trackFadeoutGain(id) : volume; }
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
    void renameProject(String);
    void cleanTimelineMedia(std::function<void(String)> completed);
    jaras::projectSync::Frame projectSyncFrame() { syncClock(); return core.projectSyncFrame(); }
    void applyProjectSync(const jaras::projectSync::Frame &, double elapsed, bool first, std::optional<ID> focused = {});
    void command(jaras::CommandKind, const ID &target = {}, double value = 0);
    std::optional<std::pair<double,double>> selectedTimeRange() const;
    void selectTimeRange(double from, double to);
    void clearTimeRange();
    void configureSetlist(jaras::RegionSetlist);
    ID duplicatePlaylistRegion(const ID &playlist, const ID &entry);
    double tempoBPM() const;
    void setTempo(double bpm);
    void configureTiming(double bpm, int beats, int unit, jaras::ProjectTimeSettings);
    void configureEffects(const ID &, const var &);
    void configureEffects(const std::map<ID, var> &);
    String copyEffect(const ID &source, const String &effect, const ID &destination, const String &before = {});
    void edit(const std::function<void(jaras::Project &)> &, bool rebuild = true, bool allowTimingEdit = false);
    void setTrackInstrumentIcon(const std::set<ID> &, std::optional<std::string>);
    void resizeItem(const ID &, double start, double end);
    std::vector<ID> duplicateTracks(const std::set<ID> &);
    void undo();
    void redo();
    bool canUndo() const { return !undoHistory.empty(); }
    bool canRedo() const { return !redoHistory.empty(); }
    void importAudio(const Array<File> &, double at = 0);
    void importMedia(const Array<File> &, double at, ID targetTrack, MediaDropLayout layout, double gap,
                     std::function<void(String)> completion = {}, bool deferWaveform = false);
    void exportMix(const File &, int bits = 24);
    void exportAudio(ExportRequest);
    void renderItems(std::set<ID>, bool glue = false, int midiChannels = 0, std::function<void(std::set<ID>)> completed = {});
    void detectRegionBPM(std::set<ID>);
    bool isDetectingBPM() const { return bpmCancellation != nullptr; }
    void cancelBPMDetection();
    void cancelExport() { exportCancelled = true; if(loadCancellation)loadCancellation->store(true); }
    void toggleRecording();
    int recordArm(const ID &id) const {
        auto at = recordArms.find(id);
        return at == recordArms.end() ? 0 : at->second;
    }
    bool recordingArmed(const ID &id) const {
        return recordArm(id) == 1 || (recordArm(id) == 2 && recordSelections.count(id) != 0);
    }
    void cycleRecordArm(const ID &, const std::set<ID> &targets = {});
    void mixerCommand(jaras::CommandKind, const ID &, const std::set<ID> &, double value = 0);
    void beginMixerGesture(jaras::CommandKind kind, ID source) {
        mixerGestureSource = std::move(source); mixerGestureProject = project().id; mixerGestureKind = kind;
        mixerGestureTracks = song() ? song()->tracks : std::vector<jaras::Track>{};
    }
    void endMixerGesture() { mixerGestureSource.clear(); mixerGestureTracks.clear(); }
    void setRecordingSelection(const ID &, const std::set<ID> &targets = {});
    void addTrack(String name = "Audio", String role = "other");
    void addSong(String);
    void renameTrack(ID, String);
    void removeTrack(ID);
    void removeTracks(const std::set<ID> &);
    void setRegionPitch(const ID &, int, std::vector<ID>, std::vector<ID>);
    void setMeter(int beats, int unit);
    void removeClip(ID);
    void addMarker(String, double, bool section = false);
    void addRegion(String, double, double);
    void reorderTrack(ID, ID);
    void reorderSong(ID, int);
    void makeInspectionProject(bool withAudioFixture = false);
    var snapshot() const;
    void restoreSnapshot(const var &);
    void notify();
    bool preparingLiveAudio() const { return graphCancellation != nullptr; }

  private:
    void loadPrepared(const File &, var, jaras::Project);
    struct TimeSelection { ID project, song; double start, end; };
    std::optional<TimeSelection> timeSelection;
    void focusTimelineRegion(double position, bool force = false);
    void focusSetlistRegion(std::optional<ID>, bool force = false);
    struct MarkerHistory { ID song; std::optional<std::vector<jaras::TimelineMarker>> markers; };
    struct ItemTimingHistory { ID song; jaras::AudioClip clip; double songDuration; };
    ItemTimingHistory itemTimingHistory(const ID &) const;
    void applyItemTiming(const ItemTimingHistory &, bool recordHistory);
    void commitItemTiming(jaras::Project, const ID &, bool recordHistory);
    MarkerHistory markerHistory(const ID &) const;
    void applyMarkerHistory(const MarkerHistory &, bool recordHistory);
    struct HistoryEntry {
        var project;
        std::optional<MarkerHistory> markers;
        std::optional<std::map<ID, var>> effects;
        std::optional<ItemTimingHistory> itemTiming;
        HistoryEntry(var value) : project(std::move(value)) {}
        HistoryEntry(MarkerHistory value) : markers(std::move(value)) {}
        HistoryEntry(std::map<ID, var> value) : effects(std::move(value)) {}
        HistoryEntry(ItemTimingHistory value) : itemTiming(std::move(value)) {}
    };
    std::vector<HistoryEntry> undoHistory, redoHistory;
    std::map<ID, var> currentEffects(const std::map<ID, var> &) const;
    void applyEffects(const std::map<ID, var> &, bool recordHistory);
    std::set<std::string> observedMedia;
    bool fadeoutRequested = false, completingFadeout = false;
    double fadeoutDuration = 3;
    std::set<ID> fadeoutTracks;
    void warnTransportFadeout(String);
    ThreadPool worker{1};
    ThreadPool bpmWorker{1};
    std::shared_ptr<std::atomic<bool>> bpmCancellation;
    std::shared_ptr<std::atomic<bool>> loadCancellation;
    std::shared_ptr<std::atomic<bool>> graphCancellation;
    std::shared_ptr<int> alive = std::make_shared<int>(0);
    ID preparedSong;
    File recordingFile;
    std::map<ID, int> recordArms;
    std::set<ID> recordSelections;
    ID recordingSong;
    ID mixerGestureSource, mixerGestureProject;
    jaras::CommandKind mixerGestureKind = jaras::CommandKind::volume;
    std::vector<jaras::Track> mixerGestureTracks;
    void updateRecordArms();
    double recordingStart = 0;
    std::atomic<bool> exportCancelled{false};
    TransportPresentationQueues presentationQueues;
    void timerCallback() override;
    void syncClock();
    void publishTransport(bool preserveLatency = false, bool routingOnly = false);
    void prepare();
    void prepareLiveGraph();
};
} // namespace catlive
