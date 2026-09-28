#pragma once
#include "../Queue/Queue.hpp"
#include <cstdint>
#include "../Loop/LoopState.hpp"
namespace jaras {
struct SubPlayState { bool playing = false; double position = 0; };
struct TransportState { bool playing = false; std::optional<ID> songId; double position = 0; Queue queue; LoopState loop; SubPlayState subPlay; std::optional<ID> regionId, queuedRegionId; double queueStartedAt = 0; double editPosition = 0; bool paused = false; std::uint64_t subPlayPromotion = 0; std::optional<double> ignoreNextAfter, ignoreNextEnd; std::optional<ID> ignoreNextRegionId; };
}
