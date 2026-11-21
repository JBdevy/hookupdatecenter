#pragma once
#include "Models.hpp"
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <stdexcept>

namespace jaras::matrixPatch {
struct Cell {
    int row, column;
    bool operator==(Cell other) const { return row == other.row && column == other.column; }
};
struct Stroke {
    Cell start, end;
    bool horizontalMajor() const { return std::abs(end.column - start.column) >= std::abs(end.row - start.row); }
    int steps() const { return std::max(std::abs(end.row - start.row), std::abs(end.column - start.column)); }
    Cell cellAt(int step) const {
        const auto length = std::int64_t(std::max(1, steps()));
        const auto coordinate = [&](int a, int b) {
            return int((a * (length - step) + std::int64_t(b) * step + length / 2) / length);
        };
        return {coordinate(start.row, end.row), coordinate(start.column, end.column)};
    }
    bool contains(Cell cell) const {
        const int step = horizontalMajor() ? std::abs(cell.column - start.column) : std::abs(cell.row - start.row);
        return step <= steps() && cellAt(step) == cell;
    }
};
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
        if (to->routing) {
            if (to->receivesMain()) {
                for (auto& slot : to->routing->receives) if (slot == source) slot.reset();
            } else remove(to->routing->receives, source);
        }
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
