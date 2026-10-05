#pragma once
#include "../Songs/Song.hpp"
#include "../Transport/TransportState.hpp"
#include "../Mixer/MixerState.hpp"
namespace jaras {
struct Setlist { ID id; std::string name; std::vector<ID> songIds; };
struct RegionPlaylist { ID id; std::string name; ID songId; std::vector<ID> regionIds; };
struct SetlistBlock { ID id; ID songId; std::optional<ID> playlistId; std::string name; unsigned color = 0; std::optional<ID> beforeRegionId; std::optional<bool> symbol; };
struct RegionSetlist { std::vector<RegionPlaylist> playlists; std::optional<ID> selectedId; bool autoAdvance = false; std::optional<std::vector<SetlistBlock>> blocks; std::optional<bool> stopAtRegionEnd; std::optional<bool> prepareWithoutPlayback; std::optional<bool> automaticSubplay; std::optional<double> automaticSubplaySeconds; };
struct Project {
    ID id; std::string name;
    int projectFormatVersion = 1;
    std::string minimumJarasVersion = "1.0.0", createdAt, updatedAt;
    std::vector<Setlist> setlists; std::vector<Song> songs;
    std::optional<RegionSetlist> regionSetlist;
    std::optional<OutputPatch> masterPatch, masterSecondaryPatch;
    std::optional<std::vector<OutputPatch>> masterOutputs;
    std::optional<std::string> masterFXJSON;
    double masterVolume = 1;
    bool masterMute = false, masterSolo = false, masterMono = false;
    std::optional<bool> masterPhaseInverted;
    std::optional<unsigned> masterColor;
};
// Control-thread validation; never called from an audio callback.
void validateRegionSetlist(const Project& project, const RegionSetlist& state);
void validateClipFXJSON(const std::string& json);
void validateClipText(const std::string& text, size_t maximum = 400);
void orderSpecialTracks(Project& project);
void validateRouting(const Song&);
void validate(const Project& project);
void synchronizeTimecode(Project& project);
std::optional<ID> regionOwnerAt(const Song& song, double start, std::optional<double> end = {});
bool regionOwns(const Song& song, const ID& root, const std::optional<ID>& owner);
void synchronizeRegionOwnership(Project& project, const Project* previous = nullptr);
}
