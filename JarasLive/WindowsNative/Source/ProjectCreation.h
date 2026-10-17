#pragma once
#include <nlohmann/json.hpp>
#include <cstddef>
#include <functional>
#include <string>
#include <vector>

namespace catlive::native {

inline constexpr std::size_t defaultRecordingChannels = 32;
inline constexpr std::size_t maximumRecordingChannels = 128;

struct ProjectCreationResult {
    nlohmann::json document;
    // Arming is session state on both platforms, not a persisted project field.
    // After installing this document, the host arms these IDs in manual mode.
    std::vector<std::string> armedTrackIDs;
};

// The caller supplies UUIDs and a localized track prefix ("Pista" or "Track").
// This creates document/session intent only: it never opens an input device,
// starts recording or claims that the current device supports the channel count.
ProjectCreationResult createRecordingProject(const std::string& projectName,
    std::size_t channels, const std::function<std::string()>& makeID,
    const std::string& trackNamePrefix = "Pista");

} // namespace catlive::native
