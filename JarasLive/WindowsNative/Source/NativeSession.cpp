#include "NativeSession.h"
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <limits>
#include <type_traits>

namespace catlive::native {
using nlohmann::json;
namespace {
// Approximate retained allocation sizes, including the large opaque FX states,
// MIDI note vectors and both waveform representations. This walks the model;
// it never serializes a project or reparses plugin state for an edit gesture.
struct MemoryEstimate {
    std::size_t bytes = 0;
    void add(std::size_t value) noexcept {
        const auto maximum = std::numeric_limits<std::size_t>::max();
        bytes = value > maximum - bytes ? maximum : bytes + value;
    }
    void allocation(std::size_t count, std::size_t elementSize) noexcept {
        if (!count) return;
        const auto maximum = std::numeric_limits<std::size_t>::max();
        add(count > maximum / elementSize ? maximum : count * elementSize);
        add(2 * sizeof(void*)); // Allocator bookkeeping; intentionally approximate.
    }
    template<class T> void dynamic(const T&) noexcept {}
    void dynamic(const std::string& value) noexcept { allocation(value.capacity() + 1, 1); }
    template<class T> void dynamic(const std::optional<T>& value) noexcept {
        if (value) dynamic(*value);
    }
    template<class T> void dynamic(const std::vector<T>& values) noexcept {
        allocation(values.capacity(), sizeof(T));
        if constexpr (!std::is_arithmetic_v<T>) for (const auto& value : values) dynamic(value);
    }
    template<class... T> void fields(const T&... values) noexcept { (dynamic(values), ...); }
    void dynamic(const jaras::AudioFile& v) noexcept { fields(v.path, v.sha256); }
    void dynamic(const jaras::TimecodeSettings& v) noexcept { dynamic(v.mode); }
    void dynamic(const jaras::TrackRouting& v) noexcept { fields(v.receives, v.transmitters); }
    void dynamic(const jaras::MIDINote& v) noexcept { dynamic(v.id); }
    void dynamic(const jaras::MIDIItem& v) noexcept { fields(v.notes, v.mode); }
    void dynamic(const jaras::AudioClip& v) noexcept {
        fields(v.id, v.separatedStemTracks, v.name, v.waveform, v.audioFile,
               v.waveformChannels, v.fxJSON, v.text, v.midi, v.timecode,
               v.regionOwnerID, v.automationJSON);
    }
    void dynamic(const jaras::Track& v) noexcept {
        fields(v.id, v.name, v.role.id, v.audioFile, v.clips, v.recordingFormat,
               v.fxJSON, v.automationJSON, v.parentTrackID, v.outputs, v.timecode,
               v.routing, v.stereoLinkPartner, v.stereoLinkJSON, v.clickSound);
    }
    void dynamic(const jaras::MultiLoopTrack& v) noexcept { dynamic(v.id); }
    void dynamic(const jaras::MultiLoop& v) noexcept {
        fields(v.id, v.name, v.marker1, v.marker2, v.tracks);
    }
    void dynamic(const jaras::Part& v) noexcept {
        fields(v.id, v.name, v.parentRegionID, v.pitchTrackIDs, v.pitchGroupIDs, v.multiLoops);
    }
    void dynamic(const jaras::TimelineMarker& v) noexcept {
        fields(v.id, v.name, v.unifiedRegionID, v.sourceRegionID, v.tempoTimebase, v.regionOwnerID);
    }
    void dynamic(const jaras::Song& v) noexcept { fields(v.id, v.name, v.tracks, v.parts, v.markers); }
    void dynamic(const jaras::Setlist& v) noexcept { fields(v.id, v.name, v.songIds); }
    void dynamic(const jaras::RegionPlaylist& v) noexcept { fields(v.id, v.name, v.songId, v.regionIds); }
    void dynamic(const jaras::SetlistBlock& v) noexcept {
        fields(v.id, v.songId, v.playlistId, v.name, v.beforeRegionId);
    }
    void dynamic(const jaras::RegionSetlist& v) noexcept {
        fields(v.playlists, v.selectedId, v.blocks, v.playedLiveRegionIDs);
    }
    void dynamic(const jaras::SavedProjectCursor& v) noexcept { dynamic(v.songID); }
    void dynamic(const jaras::Project& v) noexcept {
        fields(v.savedCursor, v.id, v.name, v.minimumJarasVersion, v.createdAt,
               v.updatedAt, v.setlists, v.songs, v.regionSetlist, v.masterOutputs,
               v.masterFXJSON, v.masterAutomationJSON, v.resolumeJSON);
    }
    void dynamic(const json& value) noexcept {
        if (value.is_object()) {
            const auto& object = value.get_ref<const json::object_t&>();
            add(sizeof(json::object_t));
            // Ordered-map nodes include parent/child links and balancing data.
            allocation(object.size(), sizeof(json::object_t::value_type) + 4 * sizeof(void*));
            for (const auto& entry : object) fields(entry.first, entry.second);
        } else if (value.is_array()) {
            add(sizeof(json::array_t));
            dynamic(value.get_ref<const json::array_t&>());
        } else if (value.is_string()) {
            add(sizeof(json::string_t));
            dynamic(value.get_ref<const json::string_t&>());
        } else if (value.is_binary()) {
            add(sizeof(json::binary_t));
            allocation(value.get_binary().capacity(), 1);
        }
    }
};
template<class T> std::size_t estimatedBytes(const T& value) noexcept {
    MemoryEstimate estimate;
    estimate.add(sizeof(T));
    estimate.dynamic(value);
    return estimate.bytes;
}
static_assert(std::is_nothrow_move_assignable_v<jaras::Engine>,
              "Committing a prepared engine must not allocate or throw");
template<class T> json optional(const std::optional<T>& value) {
    return value ? json(*value) : json(nullptr);
}
bool editsProject(jaras::CommandKind kind) {
    using K = jaras::CommandKind;
    switch (kind) {
        case K::volume: case K::pan: case K::mute: case K::solo:
        case K::phase: case K::masterMono: case K::tempo:
        case K::beatsPerBar: case K::beatUnit: case K::clipMute:
        case K::clipGain: case K::clipPhase: case K::clipPan:
        case K::clipChannelMode: case K::clipNormalization:
        case K::clipPitch: case K::clipFadeIn: case K::clipFadeOut:
        case K::clipFadeInCurve: case K::clipFadeInSCurve:
        case K::clipFadeOutCurve: case K::clipFadeOutSCurve: return true;
        default: return false;
    }
}
}
void NativeSession::loadDocument(const json& document) {
    if (transport().playing || transport().subPlay.playing)
        throw std::runtime_error("Pare a reprodução antes de abrir outro projeto.");
    auto model = ProjectCodec::decode(document);
    jaras::Engine next;
    next.loadProject(model);
    if (model.savedCursor) {
        const auto found = std::any_of(model.songs.begin(), model.songs.end(), [&](const auto& song) {
            return song.id == model.savedCursor->songID;
        });
        if (found) {
            next.execute({jaras::CommandKind::select, model.savedCursor->songID});
            next.execute({jaras::CommandKind::seek, {}, model.savedCursor->position});
            next.execute({jaras::CommandKind::editSeek, {}, model.savedCursor->position});
        }
    }
    // Allocate all preserved unknown fields before committing any state.
    auto original = std::make_shared<const json>(document);
    const auto originalBytes = estimatedBytes(*original);
    engine_ = std::move(next);
    original_ = std::move(original);
    originalBytes_ = originalBytes;
    path_.clear();
    past_.clear(); future_.clear();
    dirty_ = false;
    ++revision_;
}
void NativeSession::open(const std::filesystem::path& file) {
    if (transport().playing || transport().subPlay.playing)
        throw std::runtime_error("Pare a reprodução antes de abrir outro projeto.");
    auto nextPath = file;
    const auto raw = ProjectCodec::read(file);
    loadDocument(raw);
    path_.swap(nextPath);
}
json NativeSession::document() const { return ProjectCodec::encode(project(), *original_); }
void NativeSession::save(const std::filesystem::path& file) {
    // A Save As into another folder must first package/rebase its media. The
    // ordinary save path must never silently break existing relative paths.
    if (!path_.empty() && std::filesystem::absolute(file).parent_path().lexically_normal()
            != std::filesystem::absolute(path_).parent_path().lexically_normal())
        throw std::runtime_error("Salvar em outra pasta exige copiar as mídias do projeto.");
    auto candidate = project();
    if (transport().songId)
        candidate.savedCursor = jaras::SavedProjectCursor{*transport().songId, transport().editPosition};
    auto nextPath = file;
    auto original = std::make_shared<const json>(ProjectCodec::encode(candidate, *original_));
    const auto originalBytes = estimatedBytes(*original);
    auto next = engine_;
    next.applyProjectEdit(std::move(candidate));
    ProjectCodec::write(file, *original);
    engine_ = std::move(next);
    original_ = std::move(original);
    originalBytes_ = originalBytes;
    path_.swap(nextPath);
    dirty_ = false;
    ++revision_;
}
void NativeSession::commit(jaras::Project candidate, bool remember) {
    jaras::validate(candidate);
    jaras::Engine next = engine_;
    next.applyProjectEdit(std::move(candidate));
    commitEngine(std::move(next), remember);
}
void NativeSession::commitEngine(jaras::Engine next, bool remember) {
    jaras::validate(next.project());
    if (remember) {
        past_.push_back(snapshot());
        future_.clear();
        trimHistory();
    }
    engine_ = std::move(next);
    dirty_ = true;
    ++revision_;
}
void NativeSession::edit(const std::function<void(jaras::Project&)>& mutation) {
    auto candidate = project();
    mutation(candidate);
    jaras::synchronizeRegionOwnership(candidate, &project());
    commit(std::move(candidate), true);
}
void NativeSession::editDocument(const json& document) {
    auto candidate = ProjectCodec::decode(document);
    auto original = std::make_shared<const json>(document);
    const auto originalBytes = estimatedBytes(*original);
    auto next = engine_;
    // applyProjectEdit checks the project ID and preserves live transport.
    next.applyProjectEdit(std::move(candidate));
    commitEngine(std::move(next), true);
    original_ = std::move(original);
    originalBytes_ = originalBytes;
}
void NativeSession::editEngine(const std::function<void(jaras::Engine&)>& mutation) {
    auto candidate = engine_;
    mutation(candidate);
    commitEngine(std::move(candidate), true);
}
void NativeSession::command(const jaras::Command& command) {
    if (!std::isfinite(command.value)) throw std::runtime_error("Valor de comando inválido.");
    if (editsProject(command.kind)) {
        editEngine([&](auto& engine) { engine.execute(command); });
    } else {
        auto next = engine_;
        next.execute(command);
        engine_ = std::move(next);
        ++revision_;
    }
}
void NativeSession::advance(double seconds) {
    if (!std::isfinite(seconds) || seconds < 0) throw std::runtime_error("Intervalo inválido.");
    engine_.advance(seconds);
}
void NativeSession::restore(const History& entry) {
    auto next = engine_;
    next.applyProjectEdit(entry.project);
    engine_ = std::move(next);
    original_ = entry.original;
    originalBytes_ = entry.originalBytes;
    dirty_ = true;
    ++revision_;
}
NativeSession::History NativeSession::snapshot() const {
    History entry{project(), original_, 0, originalBytes_};
    entry.projectBytes = estimatedBytes(entry.project);
    return entry;
}
std::size_t NativeSession::historyBytes() const noexcept {
    MemoryEstimate estimate;
    // At most 40 retained entries. Counting shared documents by pointer avoids
    // an allocation here and charges each original JSON only once.
    for (std::size_t i = 0; i < past_.size() + future_.size(); ++i) {
        const auto& entry = i < past_.size() ? past_[i] : future_[i - past_.size()];
        estimate.add(entry.projectBytes);
        estimate.add(sizeof(History) - sizeof(jaras::Project));
        bool counted = false;
        for (std::size_t j = 0; j < i; ++j) {
            const auto& previous = j < past_.size() ? past_[j] : future_[j - past_.size()];
            if (previous.original == entry.original) { counted = true; break; }
        }
        if (!counted) estimate.add(entry.originalBytes);
    }
    return estimate.bytes;
}
void NativeSession::trimHistory() noexcept {
    constexpr std::size_t maxEntries = 40, maxBytes = 256 * 1024 * 1024;
    static_assert(std::is_nothrow_move_assignable_v<History>);
    while (past_.size() + future_.size() > maxEntries || historyBytes() > maxBytes) {
        // Retain the nearest Undo and Redo, even if either snapshot alone is
        // larger than the budget. Evict the farthest action in the longer stack.
        if (past_.size() > 1 && past_.size() >= future_.size()) past_.erase(past_.begin());
        else if (future_.size() > 1) future_.erase(future_.begin());
        else break;
    }
}
bool NativeSession::undo() {
    if (past_.empty()) return false;
    auto current = snapshot();
    // A failed copy, validation or reserve must leave the document and the
    // logical history unchanged. Once restored, moving into reserved space
    // cannot throw.
    future_.reserve(future_.size() + 1);
    static_assert(std::is_nothrow_move_constructible_v<History>);
    restore(past_.back());
    past_.pop_back();
    future_.push_back(std::move(current));
    trimHistory();
    return true;
}
bool NativeSession::redo() {
    if (future_.empty()) return false;
    auto current = snapshot();
    past_.reserve(past_.size() + 1);
    restore(future_.back());
    future_.pop_back();
    past_.push_back(std::move(current));
    trimHistory();
    return true;
}
json NativeSession::state() const {
    const auto& t = transport();
    return {{"revision", revision_}, {"dirty", dirty_}, {"path", path_.u8string()},
        {"timelineMovementLocked", project().timelineMovementLocked.value_or(false)},
        {"canUndo", !past_.empty()}, {"canRedo", !future_.empty()},
        {"transport", {{"playing", t.playing}, {"paused", t.paused},
            {"position", t.position}, {"editPosition", t.editPosition},
            {"songId", optional(t.songId)}, {"regionId", optional(t.regionId)},
            {"queuedRegionId", optional(t.queuedRegionId)},
            {"subPlaying", t.subPlay.playing}, {"subPosition", t.subPlay.position},
            {"ignoreNextRegionId", optional(t.ignoreNextRegionId)},
            {"ignoreNextAfter", optional(t.ignoreNextAfter)}, {"ignoreNextEnd", optional(t.ignoreNextEnd)},
            {"multiLoopsBypassed", t.multiLoopsBypassed},
            {"queuedSectionMarkerId", optional(t.queuedSectionMarkerId)}}}};
}
}
