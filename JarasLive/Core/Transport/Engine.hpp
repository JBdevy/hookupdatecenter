#pragma once
#include "../Project/Models.hpp"
#include "../ProjectSync/ProjectSync.hpp"
#include <utility>
namespace jaras {
enum class CommandKind { toggleMultiLoopBypass, queueSection, cancelSection, clipFadeIn, clipFadeOut, loopStart, loopEnd, escape, phase, masterMono, ignoreNext, tempo, beatsPerBar, beatUnit, play, stop, next, previous, queue, select, toggleLoop, seek, editSeek, subPlay, subStop, subSeek, stopAll, volume, pan, mute, solo, selectRegion, queueRegion, pause, clipMute, clipGain, clipPhase, clipPan, clipChannelMode, clipNormalization, clipPitch, clipFadeInCurve, clipFadeInSCurve, clipFadeOutCurve, clipFadeOutSCurve };
struct Command { CommandKind kind = CommandKind::stop; ID target; double value = 0; };
class Engine {
public:
    void loadProject(Project project);
    void setProjectSyncID(ID id) { if (!project_.projectSyncID) project_.projectSyncID = std::move(id); }
    projectSync::Frame projectSyncFrame() const {
        projectSync::Frame frame{project_.projectSyncID.value_or(""), transport_, project_.regionSetlist, syncRevision_,
            resumeSub_,manualSubCursor_,autoRegionQueue_,automaticSubplayActive_,playStart_,subPlayStart_,automaticSubplayQueue_};
        frame.mixer={project_.masterVolume,project_.masterPan,project_.masterMute,project_.masterSolo,{}};
        for(const auto &song:project_.songs) for(const auto &track:song.tracks)
            frame.mixer.tracks.push_back({track.id,track.volume,track.pan,track.mute,track.solo});
        return frame;
    }
    bool applyProjectSync(projectSync::Frame frame, double elapsed, bool first, bool *mixerChanged=nullptr);
    void applyProjectEdit(Project project);
    // Control-thread timing history excludes immutable decoded peak arrays.
    Project timingSnapshot();
    void restoreTimingSnapshot(Project project);
    void setRegionPitchState(const ID&, std::optional<int>, std::optional<std::vector<ID>>, std::optional<std::vector<ID>>);
    const Project& project() const noexcept { return project_; }
    const TransportState& transport() const noexcept { return transport_; }
    const Song* currentSong() const noexcept;
    std::optional<ID> nextSongId() const;
    void execute(const Command& command);
    void configureRegionSetlist(RegionSetlist state);
    void setTrackRouting(const std::vector<std::pair<ID, TrackRouting>>& routes);
    void setOutputPatch(const ID& track, int firstChannel, int channelCount, int slot = 0);
    void setOutputPatches(const ID& track, const std::vector<OutputPatch>& patches);
    void groupTracks(const std::vector<ID>& tracks);
    void reorderTrack(const ID& track, const ID& before);
    void addTrack(ID id, std::string name, TrackRole role);
    void resizeRegion(const ID& id, double start, double end);
    void moveRegion(const ID& id, double start);
    void setFX(const ID& track, std::string json);
    void setClipFX(const ID& clip, std::string json);
    void setClipFXBypass(const ID& clip, bool bypassed);
    void setClipName(const ID& clip, std::string name);
    void setClipText(const ID& clip, std::string text);
    void setMIDIInput(const ID& track, int slot);
    void setMIDIChannel(const ID& track, int channel);
    void setInputMonitoring(const ID& track, bool enabled);
    void setRecordingChannels(const ID& track, int channel);
    void setRecording(const ID& id, int first, int count, std::string format);
    void pasteItems(const ID& song, std::vector<Track> tracks, bool moving);
    void insertAudioTracks(const ID& song, std::vector<Track> tracks);
    void addRecordedClip(const ID& track, AudioClip clip, bool replacing = false);
    void setTimecode(const ID& track, TimecodeSettings settings);
    void editTrack(const ID& id, std::string name, unsigned color);
    void editMasterColor(unsigned color);
    void setMarkers(const std::vector<TimelineMarker>& markers, const std::vector<ID>& removing = {}, bool retime = false);
    void setMarker(ID id, std::string name, double position, unsigned color, std::optional<double> bpm = {}, std::optional<int> beats = {}, std::optional<int> unit = {}, std::optional<std::string> timebase = {}, std::optional<bool> section = {}, std::optional<bool> loopSection = {});
    void setProjectTiming(double bpm, int beats, int unit, std::optional<ProjectTimeSettings> settings);
    void deleteManualMarker(const ID& id);
    void setRegionInit(const ID& id, int count, bool bars);
    void setRegionPitch(const ID& id, int semitones, std::vector<ID> tracks, std::vector<ID> groups);
    void editRegion(const ID& id, std::string name, unsigned color, bool uppercaseName = true);
    void moveClip(const ID& clipId, double start, const ID& destination = {});
    void regionFromClip(const ID& clipId, ID regionId);
    void regionsFromClips(const std::vector<std::pair<ID, ID>>& items);
    void advance(double elapsed);
    // Licensing only requests a safe boundary; it never stops an active callback.
    void finishCurrentSong(bool enabled) noexcept { finishCurrent_ = enabled; }
    // The Parts display uses the same owner and boundary as the audio jump.
    const Part* sectionPlaybackRegion() const;
    std::optional<double> nextSectionTrigger() const;
private:
    void commitProjectEdit(Project project);
    void advanceWithoutLiveTracking(double elapsed);
    std::vector<ID> automaticSectionHandled_;
    double automaticSectionLastPosition_ = -1;
    std::optional<ID> automaticSectionSong_;
    void recordLivePlayback(const TransportState& before, double elapsed);
    void normalizeLiveMarks();
    std::vector<std::pair<ID, double>> liveElapsedByRegion_;
    void advanceContinuous(double elapsed, const TimelineMarker* sectionDestination = nullptr);
    const Part* sectionRegion(double position) const;
    std::optional<TimelineMarker> sectionDestination(const ID& id) const;
    void resetMultiLoop();
    void refreshMultiLoop();
    bool advanceMultiLoop(double elapsed);
    std::uint64_t syncRevision_ = 0, receivedSyncRevision_ = 0;
    Project project_;
    TransportState transport_;
    bool finishCurrent_ = false;
    bool resumeSub_ = false;
    bool manualSubCursor_ = false;
    std::optional<double> playStart_, subPlayStart_;
    std::vector<ID> order() const;
    void select(const ID& id);
    void move(int direction);
    const Part* region(const std::optional<ID>& id) const;
    const Part* playbackBounds(const Part* part) const;
    void syncRegion();
    void promoteSubPlay(std::optional<ID> preferredRegion = {});
    const RegionPlaylist* selectedRegionPlaylist() const;
    std::optional<ID> entryForRegion(const std::optional<ID>& regionID, const std::optional<ID>& preferred = {}) const;
    void syncPlaylistEntries();
    // Returns an occurrence ID; queue transport still stores physical regions.
    std::optional<ID> automaticRegionQueueTarget() const;
    void refreshAutomaticRegionQueue();
    void autoQueueRegion();
    void clearIgnoreNext();
    void toggleIgnoreNext();
    bool autoRegionQueue_ = false;
    std::optional<ID> automaticSubplayQueue_;
    bool automaticSubplayActive_ = false;
};
}
