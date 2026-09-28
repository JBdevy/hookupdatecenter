#pragma once
#include "../Tracks/Track.hpp"
#include "../Parts/Part.hpp"
namespace jaras { struct TimelineMarker { ID id; std::string name; double position = 0; unsigned color = 0; std::optional<ID> unifiedRegionID; std::optional<ID> sourceRegionID; };
struct Song { ID id; std::string name; double duration = 0, bpm = 120; std::vector<Track> tracks; std::vector<Part> parts; std::optional<std::vector<TimelineMarker>> markers; int beatsPerBar = 4, beatUnit = 4; }; }
