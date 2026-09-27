#include "Engine.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>
namespace jaras {
void Engine::loadProject(Project project) {
    validate(project);
    if (transport_.playing || transport_.subPlay.playing) throw std::logic_error("Stop before loading another project");
    project_ = std::move(project); transport_ = {}; finishCurrent_ = false; playStart_.reset(); subPlayStart_.reset();
    auto ids = order(); if (!ids.empty()) transport_.songId = ids.front();
}
std::vector<ID> Engine::order() const {
    if (!project_.setlists.empty()) return project_.setlists.front().songIds;
    std::vector<ID> result; for (const auto& song : project_.songs) result.push_back(song.id); return result;
}
const Song* Engine::currentSong() const noexcept {
    for (const auto& song : project_.songs) if (transport_.songId == song.id) return &song;
    return nullptr;
}
void Engine::select(const ID& id) {
    auto found = std::find_if(project_.songs.begin(), project_.songs.end(), [&](const auto& s) { return s.id == id; });
    if (found == project_.songs.end()) throw std::invalid_argument("Unknown song");
    playStart_ = transport_.playing ? std::optional<double>(0) : std::nullopt; subPlayStart_.reset();
    transport_.songId = id; transport_.position = 0; transport_.queue.songId.reset(); transport_.subPlay = {};
}
std::optional<ID> Engine::nextSongId() const {
    if (transport_.queue.songId) return transport_.queue.songId;
    auto ids = order(); auto it = std::find(ids.begin(), ids.end(), transport_.songId.value_or(""));
    if (it != ids.end() && ++it != ids.end()) return *it;
    return {};
}
void Engine::move(int direction) {
    if (direction > 0) { if (auto next = nextSongId()) select(*next); else { transport_.playing = false; transport_.position = 0; } return; }
    auto ids = order(); auto it = std::find(ids.begin(), ids.end(), transport_.songId.value_or(""));
    if (it != ids.end() && it != ids.begin()) select(*--it);
    else transport_.position = 0;
}
void Engine::addTrack(ID id, std::string name, TrackRole role) {
    if (!currentSong() || id.empty() || name.empty() || role.id.empty()) throw std::invalid_argument("Invalid track");
    Project next = project_;
    for (auto& song : next.songs) if (song.id == transport_.songId) {
        Track track; track.id = std::move(id); track.name = std::move(name); track.role = std::move(role); song.tracks.push_back(std::move(track)); break;
    }
    validate(next); project_ = std::move(next);
}
void Engine::execute(const Command& c) {
    if (!std::isfinite(c.value)) throw std::invalid_argument("Non-finite control value");
    switch (c.kind) {
    case CommandKind::play: if (currentSong()) { if (transport_.position >= currentSong()->duration) transport_.position = 0; if (!transport_.playing) playStart_ = transport_.position; transport_.playing = true; } break;
    case CommandKind::subPlay: if (currentSong()) { if (transport_.subPlay.position >= currentSong()->duration) transport_.subPlay.position = 0; if (!transport_.subPlay.playing) subPlayStart_ = transport_.subPlay.position; transport_.subPlay.playing = true; } break;
    case CommandKind::subStop: transport_.subPlay.playing = false; if (subPlayStart_) transport_.subPlay.position = *subPlayStart_; subPlayStart_.reset(); break;
    case CommandKind::subSeek: if (currentSong()) transport_.subPlay.position = std::clamp(c.value, 0.0, currentSong()->duration); break;
    case CommandKind::stopAll: execute({CommandKind::stop}); execute({CommandKind::subStop}); break;
    case CommandKind::stop: transport_.playing = false; if (playStart_) transport_.position = *playStart_; playStart_.reset(); break;
    case CommandKind::next: move(1); break;
    case CommandKind::previous: move(-1); break;
    case CommandKind::select: select(c.target); break;
    case CommandKind::queue:
        if (std::none_of(project_.songs.begin(), project_.songs.end(), [&](const auto& s) { return s.id == c.target; })) throw std::invalid_argument("Unknown queued song");
        transport_.queue.songId = c.target; break;
    case CommandKind::seek: if (currentSong()) transport_.position = std::clamp(c.value, 0.0, currentSong()->duration); break;
    case CommandKind::toggleLoop: transport_.loop.enabled = !transport_.loop.enabled; break;
    default:
        for (auto& song : project_.songs) for (auto& track : song.tracks) if (track.id == c.target) {
            if (c.kind == CommandKind::volume) track.volume = std::clamp(c.value, 0.0, 1.0);
            if (c.kind == CommandKind::pan) track.pan = std::clamp(c.value, -1.0, 1.0);
            if (c.kind == CommandKind::mute) track.mute = !track.mute;
            if (c.kind == CommandKind::solo) track.solo = !track.solo;
            return;
        }
        throw std::invalid_argument("Unknown track");
    }
}
void Engine::advance(double elapsed) {
    if (!std::isfinite(elapsed) || elapsed <= 0) return;
    if (transport_.subPlay.playing && currentSong()) {
        transport_.subPlay.position = std::min(currentSong()->duration, transport_.subPlay.position + elapsed);
        if (transport_.subPlay.position >= currentSong()->duration) transport_.subPlay.playing = false;
    }
    if (!transport_.playing) return;
    const auto* song = currentSong(); if (!song) return;
    transport_.position += elapsed;
    if (transport_.position < song->duration) return;
    if (finishCurrent_) { transport_.position = song->duration; transport_.playing = false; return; }
    if (transport_.loop.enabled && !transport_.queue.songId) { transport_.position = std::fmod(transport_.position, song->duration); return; }
    // Consume elapsed time across queued songs, without a UI-frame dependency.
    double remainder = transport_.position - song->duration;
    auto next = nextSongId();
    if (!next) { transport_.position = song->duration; transport_.playing = false; return; }
    select(*next);
    advance(remainder);
}
}
