#pragma once
#include "../Utils/Identity.hpp"
#include <optional>
#include "../Loop/MultiLoop.hpp"
#include <vector>
namespace jaras { struct Part { ID id; std::string name; double startTime = 0, endTime = 0; std::optional<unsigned> color; std::optional<bool> uppercaseName; std::optional<ID> parentRegionID; std::optional<int> pitchSemitones; std::optional<std::vector<ID>> pitchTrackIDs, pitchGroupIDs; std::vector<MultiLoop> multiLoops; std::optional<bool> totalLoop; }; }
