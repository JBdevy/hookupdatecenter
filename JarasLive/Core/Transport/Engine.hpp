#pragma once
#include "../Project/Models.hpp"
namespace jaras {
enum class CommandKind { play, stop, next, previous, queue, select, toggleLoop, seek, subPlay, subStop, subSeek, stopAll, volume, pan, mute, solo };
struct Command { CommandKind kind = CommandKind::stop; ID target; double value = 0; };
class Engine {
public:
    void loadProject(Project project);
    const Project& project() const noexcept { return project_; }
    const TransportState& transport() const noexcept { return transport_; }
    const Song* currentSong() const noexcept;
    std::optional<ID> nextSongId() const;
    void execute(const Command& command);
    void addTrack(ID id, std::string name, TrackRole role);
    void advance(double elapsed);
    // Licensing only requests a safe boundary; it never stops an active callback.
    void finishCurrentSong(bool enabled) noexcept { finishCurrent_ = enabled; }
private:
    Project project_;
    TransportState transport_;
    bool finishCurrent_ = false;
    std::optional<double> playStart_, subPlayStart_;
    std::vector<ID> order() const;
    void select(const ID& id);
    void move(int direction);
};
}
