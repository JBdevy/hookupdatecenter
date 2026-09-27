#pragma once
#include "../Tracks/Track.hpp"
#include "../Parts/Part.hpp"
namespace jaras { struct Song { ID id; std::string name; double duration = 0, bpm = 120; std::vector<Track> tracks; std::vector<Part> parts; }; }
