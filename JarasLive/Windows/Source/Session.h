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
    String message;
    uint64 revision = 0;
    std::function<void()> changed, tick;
    std::function<bool()> canPlay;
    std::function<void(const jaras::TransportState &)> playbackUpdate;
    void newProject(String name = "Untitled");
    void load(const File &);
    void save(const File &);
    void cleanTimelineMedia(std::function<void(String)> completed);
    void command(jaras::CommandKind, const ID &target = {}, double value = 0);
    void configureSetlist(jaras::RegionSetlist);
    void configureTiming(double bpm, int beats, int unit, jaras::ProjectTimeSettings);
    void configureEffects(const ID &, const var &);
    void edit(const std::function<void(jaras::Project &)> &, bool rebuild = true);
    void undo();
    void redo();
    bool canUndo() const { return !undoHistory.empty(); }
    bool canRedo() const { return !redoHistory.empty(); }
    void importAudio(const Array<File> &, double at = 0);
    void exportMix(const File &, int bits = 24);
    void exportAudio(ExportRequest);
    void cancelExport() { exportCancelled = true; }
    void importVideo(const File &, double duration);
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
    std::vector<var> undoHistory, redoHistory;
    std::set<std::string> observedMedia;
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
