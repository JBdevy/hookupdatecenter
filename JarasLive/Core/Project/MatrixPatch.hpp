#pragma once
#include "Models.hpp"
#include <algorithm>
#include <stdexcept>

namespace jaras::matrixPatch {
inline bool same(OutputPatch a, OutputPatch b) { return a.firstChannel == b.firstChannel && a.channelCount == b.channelCount; }
inline bool contains(const std::vector<OutputPatch>& outputs, OutputPatch patch) {
    return std::any_of(outputs.begin(), outputs.end(), [&](auto value) { return same(value, patch); });
}
inline std::vector<OutputPatch> toggled(std::vector<OutputPatch> outputs, OutputPatch patch) {
    const bool remove = contains(outputs, patch);
    outputs.erase(std::remove_if(outputs.begin(), outputs.end(), [&](auto value) {
        return same(value, patch) || (!remove && value.firstChannel == -1);
    }), outputs.end());
    if (!remove) outputs.push_back(patch);
    return outputs;
}
inline bool connection(const Track& source, const Track& destination) {
    auto includes = [](const auto& values, const ID& id) { return std::find(values.begin(), values.end(), std::optional<ID>(id)) != values.end(); };
    return (source.parentTrackID == destination.id && contains(source.outputPatches(), {-2,2})) ||
        (source.routing && includes(source.routing->transmitters, destination.id)) ||
        (destination.routing && includes(destination.routing->receives, source.id));
}
/// Used inside Session's validated, undoable routing transaction.
inline void toggleConnection(Song& song, const ID& source, const ID& destination) {
    auto from = std::find_if(song.tracks.begin(), song.tracks.end(), [&](const auto& t) { return t.id == source; });
    auto to = std::find_if(song.tracks.begin(), song.tracks.end(), [&](const auto& t) { return t.id == destination; });
    if (from == song.tracks.end() || to == song.tracks.end() || from == to ||
        !fixedTrackName(from->role).empty() || !fixedTrackName(to->role).empty())
        throw std::invalid_argument("Invalid track routing");
    if (connection(*from, *to)) {
        auto remove = [](auto& values, const ID& id) { values.erase(std::remove(values.begin(), values.end(), std::optional<ID>(id)), values.end()); };
        if (from->routing) remove(from->routing->transmitters, destination);
        if (to->routing) remove(to->routing->receives, source);
        if (from->parentTrackID == destination) {
            auto outputs = from->outputPatches();
            outputs.erase(std::remove_if(outputs.begin(), outputs.end(), [](auto p) { return p.firstChannel == -2; }), outputs.end());
            from->outputs = outputs; from->patch.reset(); from->secondaryPatch.reset();
        }
    } else if (from->parentTrackID == destination) {
        from->outputs = toggled(from->outputPatches(), {-2,2}); from->patch.reset(); from->secondaryPatch.reset();
    } else {
        if (!from->routing) from->routing = TrackRouting{};
        from->routing->transmitters.push_back(destination);
    }
}
} // namespace jaras::matrixPatch
