#pragma once
#include <nlohmann/json.hpp>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace catlive::native {

struct TrackDuplicationResult {
    nlohmann::json document;
    // New tracks in their resulting visual order, including selected folders'
    // descendants and the other channel of a selected linked stereo pair.
    std::vector<std::string> trackIDs;
    std::map<std::string, std::string> trackIDMap;
};

// Control-thread edit. The input is never mutated, including on failure. The
// host supplies fresh UUID strings and commits the returned document in one
// history operation. Media and opaque plugin state are copied without rewriting
// their contents. Missing/special selections produce an unchanged document.
TrackDuplicationResult duplicateTracks(const nlohmann::json& document,
    const std::string& songID, const std::vector<std::string>& selectedIDs,
    const std::function<std::string()>& makeID);

} // namespace catlive::native
