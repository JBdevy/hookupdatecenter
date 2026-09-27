#pragma once
#include "../Queue/Queue.hpp"
#include "../Loop/LoopState.hpp"
namespace jaras {
struct SubPlayState { bool playing = false; double position = 0; };
struct TransportState { bool playing = false; std::optional<ID> songId; double position = 0; Queue queue; LoopState loop; SubPlayState subPlay; };
}
