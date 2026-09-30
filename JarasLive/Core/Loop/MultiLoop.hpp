#pragma once
#include "../Utils/Identity.hpp"
#include <vector>
namespace jaras {
struct MultiLoopTrack { ID id; double gain = 1; bool autoFader = false, mute = false, solo = false; };
struct MultiLoop { ID id; std::string name; ID marker1, marker2; double fadeSeconds = 3; std::vector<MultiLoopTrack> tracks; };
struct MultiLoopPlayback { ID id; double start = 0, end = 0, amount = 0; bool gates = false, released = false; double releasePosition = 0; MultiLoop config; };
}
