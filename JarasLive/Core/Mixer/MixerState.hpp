#pragma once
#include "../Tracks/Track.hpp"
namespace jaras {
struct AudioRoute { ID trackId; int output = 1; };
struct AudioRouting { std::vector<AudioRoute> routes; };
struct MixerState { std::vector<Track> tracks; AudioRouting routing; };
}
