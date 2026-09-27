#pragma once
#include "../Songs/Song.hpp"
#include "../Transport/TransportState.hpp"
#include "../Mixer/MixerState.hpp"
namespace jaras {
struct Setlist { ID id; std::string name; std::vector<ID> songIds; };
struct Project {
    ID id; std::string name;
    int projectFormatVersion = 1;
    std::string minimumJarasVersion = "1.0.0", createdAt, updatedAt;
    std::vector<Setlist> setlists; std::vector<Song> songs;
};
// Control-thread validation; never called from an audio callback.
void validate(const Project& project);
}
