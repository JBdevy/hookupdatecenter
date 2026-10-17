#pragma once
#include "AudioEngine.h"
#include "ProjectCodec.h"
#include "AudioExport.h"
namespace catlive {
class Session final : private Timer {
  public:
    Session();
    ~Session() override;
    jaras::Engine core;
    AudioEngine audio;
    const jaras::Project &project() const { return core.project(); }
    const jaras::Song *song() const { return core.currentSong(); }
    const jaras::TransportState &transport() const { return core.transport(); }
    File document, mediaDirectory;
    var original;
    bool dirty = false, busy = false, inspection = false;
    double importProgress = 0;
    double subCursorPreviewUntil = 0;
    bool subCursorVisible() const { return transport().subPlay.playing || Time::getMillisecondCounterHiRes() < subCursorPreviewUntil; }
    static float subCursorOpacity(double seconds) { return std::fmod(seconds, .9) < .45 ? 1.f : .3f; }
    std::optional<ID> focusedRegion;
    uint64 setlistFocusRevision = 0;
    String message;
    uint64 revision = 0;
    std::function<void()> changed, tick;
    std::function<void(String)> transportFadeoutWarning;
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
    void newProject(String name = "Untitled");
    void createRecordingProject(String name, int channels, const File &target);
    void load(const File &);
    void save(const File &);
    void cleanTimelineMedia(std::function<void(String)> completed);
    void command(jaras::CommandKind, const ID &target = {}, double value = 0);
    std::optional<std::pair<double,double>> selectedTimeRange() const;
    void selectTimeRange(double from, double to);
    void clearTimeRange();
    void configureSetlist(jaras::RegionSetlist);
    double tempoBPM() const;
    void setTempo(double bpm);
    void configureTiming(double bpm, int beats, int unit, jaras::ProjectTimeSettings);
    void configureEffects(const ID &, const var &);
    void configureEffects(const std::map<ID, var> &);
    void edit(const std::function<void(jaras::Project &)> &, bool rebuild = true, bool allowTimingEdit = false);
    std::vector<ID> duplicateTracks(const std::set<ID> &);
    void undo();
    void redo();
    bool canUndo() const { return !undoHistory.empty(); }
    bool canRedo() const { return !redoHistory.empty(); }
    void importAudio(const Array<File> &, double at = 0);
    void importMedia(const Array<File> &, double at, ID targetTrack, bool sameTrack, double gap);
    void exportMix(const File &, int bits = 24);
    void exportAudio(ExportRequest);
    void renderItems(std::set<ID>, bool glue = false, int midiChannels = 0);
    void detectRegionBPM(std::set<ID>);
    void cancelExport() { exportCancelled = true; }
    void toggleRecording();
    int recordArm(const ID &id) const {
        auto at = recordArms.find(id);
        return at == recordArms.end() ? 0 : at->second;
    }
    bool recordingArmed(const ID &id) const {
        return recordArm(id) == 1 || (recordArm(id) == 2 && recordSelection == id);
    }
    void cycleRecordArm(const ID &);
    void setRecordingSelection(const ID &);
    void addTrack(String name = "Audio", String role = "other");
    void addSong(String);
    void renameTrack(ID, String);
    void removeTrack(ID);
    void removeClip(ID);
    void addMarker(String, double, bool section = false);
    void addRegion(String, double, double);
    void reorderTrack(ID, ID);
    void reorderSong(ID, int);
    void makeInspectionProject(bool withAudioFixture = false);
    var snapshot() const;
    void restoreSnapshot(const var &);
    void notify();

  private:
    struct TimeSelection { ID project, song; double start, end; };
    std::optional<TimeSelection> timeSelection;
    void focusTimelineRegion(double position, bool force = false);
    struct HistoryEntry {
        var project;
        std::optional<std::map<ID, var>> effects;
        HistoryEntry(var value) : project(std::move(value)) {}
        HistoryEntry(std::map<ID, var> value) : effects(std::move(value)) {}
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
    std::shared_ptr<int> alive = std::make_shared<int>(0);
    ID preparedSong;
    File recordingFile;
    std::map<ID, int> recordArms;
    ID recordSelection, recordingSong;
    void updateRecordArms();
    double recordingStart = 0;
    std::atomic<bool> exportCancelled{false};
    void timerCallback() override;
    void syncClock();
    void publishTransport();
    void prepare();
};
} // namespace catlive
