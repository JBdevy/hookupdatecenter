#pragma once
#include "../Queue/Queue.hpp"
#include <cstdint>
#include "../Loop/LoopState.hpp"
#include "../Loop/MultiLoop.hpp"
namespace jaras {
struct SubPlayState { bool playing = false; double position = 0; };
struct TransportState { std::optional<ID> playbackStartRegionId, subPlaybackStartRegionId; std::optional<ID> exclusivePlaybackRegionId, subExclusivePlaybackRegionId; bool multiLoopsBypassed = false; std::optional<ID> queuedSectionMarkerId; std::optional<ID> automaticSectionTriggerId; double sectionQueueStartedAt = 0; std::uint64_t sectionJumpSerial = 0; std::optional<MultiLoopPlayback> multiLoop; bool playing = false; std::optional<ID> songId; double position = 0; Queue queue; LoopState loop; SubPlayState subPlay; std::optional<ID> regionId, queuedRegionId; double queueStartedAt = 0; double editPosition = 0; bool paused = false; std::uint64_t subPlayPromotion = 0; std::optional<double> ignoreNextAfter, ignoreNextEnd; std::optional<ID> ignoreNextRegionId; std::optional<ID> playlistEntryId, queuedPlaylistEntryId; };
}
