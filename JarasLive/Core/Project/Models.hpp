#pragma once
#include "../Songs/Song.hpp"
#include "../Transport/TransportState.hpp"
#include "../Mixer/MixerState.hpp"
namespace jaras {
struct Setlist { ID id; std::string name; std::vector<ID> songIds; };
struct RegionPlaylistDuplicate {
    ID id, regionId;
    bool operator==(const RegionPlaylistDuplicate& other) const { return id == other.id && regionId == other.regionId; }
};
struct RegionPlaylist {
    ID id; std::string name; ID songId; std::vector<ID> regionIds;
    // regionIds is the ordered list of unique ROW IDs. Originals retain their
    // physical region ID; duplicates resolve to the existing grid via aliases.
    std::optional<std::vector<RegionPlaylistDuplicate>> duplicates;
    ID resolvedRegionId(const ID& entry) const {
        if (duplicates) for (const auto& duplicate : *duplicates) if (duplicate.id == entry) return duplicate.regionId;
        return entry;
    }
    bool isDuplicate(const ID& entry) const {
        if (duplicates) for (const auto& duplicate : *duplicates) if (duplicate.id == entry) return true;
        return false;
    }
    bool containsEntry(const ID& entry) const {
        for (const auto& id : regionIds) if (id == entry) return true;
        return false;
    }
};
struct SetlistBlock { ID id; ID songId; std::optional<ID> playlistId; std::string name; unsigned color = 0; std::optional<ID> beforeRegionId; std::optional<bool> symbol; };
struct RegionSetlist { std::vector<RegionPlaylist> playlists; std::optional<ID> selectedId; bool autoAdvance = false; std::optional<std::vector<SetlistBlock>> blocks; std::optional<bool> stopAtRegionEnd; std::optional<bool> prepareWithoutPlayback; std::optional<bool> automaticSubplay; std::optional<double> automaticSubplaySeconds; std::optional<bool> liveEnabled; std::optional<std::vector<ID>> playedLiveRegionIDs; bool autoUntilBlockEnd = false; std::optional<int> automaticSubplayBars; std::optional<bool> automaticSubplayNext; std::optional<std::vector<ID>> subplayExclusiveTrackIDs; };
struct SavedProjectCursor { ID songID; double position = 0; };
struct Project {
    std::optional<std::string> reductionDraftJSON;
    std::optional<ID> projectSyncID;
    std::optional<SavedProjectCursor> savedCursor;
    ID id; std::string name;
    int projectFormatVersion = 1;
    std::string minimumJarasVersion = "1.0.0", createdAt, updatedAt;
    std::vector<Setlist> setlists; std::vector<Song> songs;
    std::optional<RegionSetlist> regionSetlist;
    std::optional<OutputPatch> masterPatch, masterSecondaryPatch;
    std::optional<std::vector<OutputPatch>> masterOutputs;
    std::optional<std::string> masterFXJSON, masterAutomationJSON, resolumeJSON;
    double masterVolume = 1;
    double masterPan = 0;
    bool masterMute = false, masterSolo = false, masterMono = false;
    std::optional<bool> masterPhaseInverted;
    std::optional<unsigned> masterColor;
    std::optional<bool> timelineMovementLocked;
    std::optional<int> timelineLockOptions;
    int configuredTimelineLocks() const noexcept { return timelineLockOptions.value_or(7) & 7; }
    int effectiveTimelineLocks() const noexcept { return timelineMovementLocked.value_or(false) ? configuredTimelineLocks() : 0; }
    // Preserve imported timing through engine snapshots and project saves.
    std::optional<bool> importedTimeline;
    std::optional<std::vector<ID>> partialImportIDs;
};
// Control-thread validation; never called from an audio callback.
void validateRegionSetlist(const Project& project, const RegionSetlist& state);
void validateClipFXJSON(const std::string& json);
void validateClipText(const std::string& text);
void orderSpecialTracks(Project& project);
void validateRouting(const Song&);
void validate(const Project& project);
void synchronizeTimecode(Project& project);
std::optional<ID> regionOwnerAt(const Song& song, double start, std::optional<double> end = {});
bool regionOwns(const Song& song, const ID& root, const std::optional<ID>& owner);
std::optional<ID> regionMovementOwner(const Song&, double start, std::optional<double> end = {},
                                    const std::optional<ID>& preferred = {});
bool markerMovesWithRegion(const Song&, const TimelineMarker&, const ID& root);
void synchronizeRegionOwnership(Project& project, const Project* previous = nullptr);
}
