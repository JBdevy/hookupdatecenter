#pragma once
#include "../Project/Models.hpp"
namespace jaras {
enum class CommandKind { toggleMultiLoopBypass, queueSection, cancelSection, clipFadeIn, clipFadeOut, loopStart, loopEnd, escape, phase, masterMono, ignoreNext, tempo, beatsPerBar, beatUnit, play, stop, next, previous, queue, select, toggleLoop, seek, editSeek, subPlay, subStop, subSeek, stopAll, volume, pan, mute, solo, selectRegion, queueRegion, pause, clipMute, clipGain, clipChannelMode, clipNormalization, clipPitch };
struct Command { CommandKind kind = CommandKind::stop; ID target; double value = 0; };
class Engine {
public:
    void loadProject(Project project);
    void applyProjectEdit(Project project);
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
    void setRegionPitch(const ID& id, int semitones, std::vector<ID> tracks, std::vector<ID> groups);
    void editRegion(const ID& id, std::string name, unsigned color, bool uppercaseName = true);
    void moveClip(const ID& clipId, double start, const ID& destination = {});
    void regionFromClip(const ID& clipId, ID regionId);
    void regionsFromClips(const std::vector<std::pair<ID, ID>>& items);
    void advance(double elapsed);
    // Licensing only requests a safe boundary; it never stops an active callback.
    void finishCurrentSong(bool enabled) noexcept { finishCurrent_ = enabled; }
private:
    void advanceContinuous(double elapsed, const TimelineMarker* sectionDestination = nullptr);
    const Part* sectionRegion(double position) const;
    std::optional<TimelineMarker> sectionDestination(const ID& id) const;
    void resetMultiLoop();
    void refreshMultiLoop();
    bool advanceMultiLoop(double elapsed);
    Project project_;
    TransportState transport_;
    bool finishCurrent_ = false;
    bool resumeSub_ = false;
    std::optional<double> playStart_, subPlayStart_;
    std::vector<ID> order() const;
    void select(const ID& id);
    void move(int direction);
    const Part* region(const std::optional<ID>& id) const;
    const Part* playbackBounds(const Part* part) const;
    void syncRegion();
    void promoteSubPlay(std::optional<ID> preferredRegion = {});
    void autoQueueRegion();
    void clearIgnoreNext();
    void toggleIgnoreNext();
    bool autoRegionQueue_ = false;
    std::optional<ID> automaticSubplayQueue_;
};
}
