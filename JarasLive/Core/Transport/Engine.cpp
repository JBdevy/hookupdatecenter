#include "Engine.hpp"
#include "PlaybackScope.hpp"
#include "../Songs/TempoEditMap.hpp"
#include <algorithm>
#include <cmath>
#include <cctype>
#include <stdexcept>
#include <random>
#include <set>
#include <limits>
#include <map>
#include <unordered_set>
namespace jaras {
void Engine::loadProject(Project project) {
    orderSpecialTracks(project); synchronizeTimecode(project); synchronizeRegionOwnership(project); validate(project);
    if (transport_.playing || transport_.subPlay.playing) throw std::logic_error("Stop before loading another project");
    const bool bypassed = transport_.multiLoopsBypassed;
    project_ = std::move(project); transport_ = {}; manualSubCursor_ = false; transport_.multiLoopsBypassed = bypassed; automaticSubplayQueue_.reset(); automaticSubplayActive_ = false; finishCurrent_ = false; resumeSub_ = false; playStart_.reset(); subPlayStart_.reset();
    liveElapsedByRegion_.clear(); normalizeLiveMarks();
    auto ids = order(); if (!ids.empty()) transport_.songId = ids.front();
}
void Engine::applyProjectEdit(Project project) {
    projectSync::requireWritable();
    if (project.id != project_.id) throw std::invalid_argument("Cannot edit another project");
    orderSpecialTracks(project); synchronizeTimecode(project); synchronizeRegionOwnership(project, &project_); validate(project);
    if (project_.projectSyncID) project.projectSyncID = project_.projectSyncID;
    const bool liveChanged = project_.regionSetlist && project_.regionSetlist->liveEnabled.value_or(false) !=
        (project.regionSetlist && project.regionSetlist->liveEnabled.value_or(false));
    project_ = std::move(project);
    if (liveChanged) liveElapsedByRegion_.clear();
    normalizeLiveMarks();
    if (!currentSong()) { const bool bypassed = transport_.multiLoopsBypassed; transport_ = {}; manualSubCursor_ = false; transport_.multiLoopsBypassed = bypassed; auto ids = order(); if (!ids.empty()) transport_.songId = ids.front(); }
    if (!region(transport_.regionId)) { transport_.regionId.reset(); transport_.loop.enabled = false; }
    refreshAutomaticRegionQueue();
    if (!region(transport_.queuedRegionId)) { transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); autoRegionQueue_ = false; }
    syncRegion(); autoQueueRegion(); refreshMultiLoop();
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
    transport_.queuedSectionMarkerId.reset();
    transport_.paused = false; resumeSub_ = false;
    playStart_ = transport_.playing ? std::optional<double>(0) : std::nullopt; subPlayStart_.reset();
    clearIgnoreNext();
    transport_.regionId.reset(); transport_.playlistEntryId.reset(); transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); autoRegionQueue_ = false;
    transport_.songId = id; transport_.playbackStartRegionId = playbackEntryRegion(*found, 0); transport_.subPlaybackStartRegionId.reset(); transport_.position = 0; transport_.editPosition = 0; transport_.queue.songId.reset(); transport_.subPlay = {}; manualSubCursor_ = false; automaticSubplayActive_ = false;
}
std::optional<ID> Engine::nextSongId() const {
    if (transport_.queue.songId) return transport_.queue.songId;
    auto ids = order(); auto it = std::find(ids.begin(), ids.end(), transport_.songId.value_or(""));
    if (it != ids.end() && ++it != ids.end()) return *it;
    return {};
}
void Engine::move(int direction) {
    if (direction > 0) { if (auto next = nextSongId()) select(*next); else { execute({CommandKind::subStop}); transport_.playing = false; transport_.position = 0; } return; }
    auto ids = order(); auto it = std::find(ids.begin(), ids.end(), transport_.songId.value_or(""));
    if (it != ids.end() && it != ids.begin()) select(*--it);
    else transport_.position = 0;
}
const Part* Engine::region(const std::optional<ID>& id) const {
    if (const auto* song = currentSong()) for (const auto& part : song->parts) if (id == part.id) return &part;
    return nullptr;
}
const RegionPlaylist* Engine::selectedRegionPlaylist() const {
    if (project_.regionSetlist && currentSong())
        for (const auto& list : project_.regionSetlist->playlists)
            if (list.id == project_.regionSetlist->selectedId && list.songId == currentSong()->id) return &list;
    return nullptr;
}
std::optional<ID> Engine::entryForRegion(const std::optional<ID>& physical, const std::optional<ID>& preferred) const {
    const auto* list = selectedRegionPlaylist();
    const auto* bounds = playbackBounds(region(physical));
    if (!list || !bounds) return {};
    const auto matches = [&](const ID& id) {
        const auto* source = playbackBounds(region(list->resolvedRegionId(id)));
        return list->containsEntry(id) && source && source->id == bounds->id;
    };
    if (preferred && matches(*preferred)) return preferred;
    if (matches(bounds->id)) return bounds->id;
    for (const auto& id : list->regionIds) if (matches(id)) return id;
    return {};
}
void Engine::syncPlaylistEntries() {
    const auto* list = selectedRegionPlaylist();
    transport_.playlistEntryId = entryForRegion(transport_.regionId, transport_.playlistEntryId);
    if (!transport_.queuedRegionId) { transport_.queuedPlaylistEntryId.reset(); return; }
    if (transport_.queuedPlaylistEntryId && (!list || !list->containsEntry(*transport_.queuedPlaylistEntryId))) {
        // Removing the queued occurrence cancels that request, even when its
        // source still exists elsewhere in the playlist/grid. Retract only a
        // pre-roll started by Auto; a manually running secondary head is free.
        if (automaticSubplayQueue_ == transport_.queuedRegionId) {
            if (automaticSubplayActive_) { execute({CommandKind::subStop}); resumeSub_ = false; }
            automaticSubplayQueue_.reset();
        }
        transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset();
        autoRegionQueue_ = false; return;
    }
    transport_.queuedPlaylistEntryId = entryForRegion(transport_.queuedRegionId, transport_.queuedPlaylistEntryId);
}
void Engine::configureRegionSetlist(RegionSetlist state) {
    projectSync::requireWritable();
    validateRegionSetlist(project_, state);
    const auto& previous = project_.regionSetlist;
    const auto previousTarget = automaticRegionQueueTarget();
    const bool playbackChanged = !previous || previous->selectedId != state.selectedId || previous->autoAdvance != state.autoAdvance ||
        previous->autoUntilBlockEnd != state.autoUntilBlockEnd || previous->playlists.size() != state.playlists.size() ||
        !std::equal(previous->playlists.begin(), previous->playlists.end(), state.playlists.begin(), [](const auto& a, const auto& b) {
            return a.id == b.id && a.songId == b.songId && a.regionIds == b.regionIds && a.duplicates == b.duplicates;
        });
    if (!state.liveEnabled.value_or(false) || !previous ||
        previous->liveEnabled.value_or(false) != state.liveEnabled.value_or(false)) liveElapsedByRegion_.clear();
    project_.regionSetlist = std::move(state);
    normalizeLiveMarks();
    syncPlaylistEntries();
    // A cosmetic edit must not resolve a stopped cursor at an exact boundary
    // into the physically adjacent region. Block edits matter only if they
    // change the next automatic destination.
    if (!playbackChanged && previousTarget == automaticRegionQueueTarget()) return;
    refreshAutomaticRegionQueue();
    syncRegion();
}
std::optional<ID> Engine::automaticRegionQueueTarget() const {
    if (!project_.regionSetlist || !project_.regionSetlist->autoAdvance || !transport_.regionId) return {};
    const auto* song = currentSong(); if (!song) return {};
    const auto& state = *project_.regionSetlist;
    const auto* active = region(transport_.regionId);
    const auto listID = active && active->parentRegionID ? *active->parentRegionID : *transport_.regionId;
    std::optional<ID> target;
    if (const auto* list = selectedRegionPlaylist()) {
        const auto occurrence = entryForRegion(transport_.regionId, transport_.playlistEntryId);
        auto it = std::find(list->regionIds.begin(), list->regionIds.end(), occurrence.value_or(listID));
        if (it != list->regionIds.end()) for (++it; it != list->regionIds.end(); ++it) {
            // A block boundary is a boundary even if the following row resolves
            // to the current physical song and would otherwise be skipped.
            if (state.autoUntilBlockEnd && state.blocks && std::any_of(state.blocks->begin(),state.blocks->end(),[&](const auto& b) {
                return b.songId == song->id && b.playlistId == state.selectedId && b.beforeRegionId == *it;
            })) return {};
            const auto* part = region(list->resolvedRegionId(*it));
            if (part && !part->parentRegionID && part->id != listID) { target = *it; break; }
        }
    } else {
        std::vector<const Part*> parts;
        for (const auto& part : song->parts) if (!part.parentRegionID) parts.push_back(&part);
        std::sort(parts.begin(), parts.end(), [](const auto* a, const auto* b) { return a->startTime == b->startTime ? a->id < b->id : a->startTime < b->startTime; });
        auto it = std::find_if(parts.begin(), parts.end(), [&](const auto* part) { return part->id == listID; });
        if (it != parts.end() && ++it != parts.end()) target = (*it)->id;
    }
    if (!target) return {};
    if (state.autoUntilBlockEnd && state.blocks) {
        for (const auto& block : *state.blocks)
            if (block.songId == song->id && block.playlistId == state.selectedId && block.beforeRegionId == target) return {};
    }
    return target;
}
void Engine::refreshAutomaticRegionQueue() {
    const auto occurrence = transport_.queuedPlaylistEntryId ? transport_.queuedPlaylistEntryId : transport_.queuedRegionId;
    if (!autoRegionQueue_ || occurrence == automaticRegionQueueTarget()) return;
    // A manual override owns its queue and Sub Play. Only retract playback that
    // this automatic queue started; cosmetic edits preserve its countdown.
    if (automaticSubplayQueue_ && automaticSubplayQueue_ == transport_.queuedRegionId) {
        if (automaticSubplayActive_) { execute({CommandKind::subStop}); resumeSub_ = false; }
        automaticSubplayQueue_.reset();
    }
    transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); transport_.queueStartedAt = 0; autoRegionQueue_ = false;
}
void Engine::autoQueueRegion() {
    if (!transport_.playing || transport_.queuedRegionId) return;
    if (auto target = automaticRegionQueueTarget()) {
        const auto* list = selectedRegionPlaylist();
        transport_.queuedRegionId = list ? list->resolvedRegionId(*target) : *target;
        transport_.queuedPlaylistEntryId = list ? target : std::nullopt;
        transport_.queueStartedAt = transport_.position; autoRegionQueue_ = true;
    }
}
void Engine::clearIgnoreNext() {
    transport_.ignoreNextAfter.reset(); transport_.ignoreNextEnd.reset(); transport_.ignoreNextRegionId.reset();
}
void Engine::toggleIgnoreNext() {
    if (transport_.ignoreNextAfter) { clearIgnoreNext(); return; }
    if (!transport_.playing) return;
    const auto* song = currentSong(); const auto* root = playbackBounds(region(transport_.regionId));
    if (!song || !root) return;
    const Part* current = nullptr; const Part* next = nullptr;
    const Part* latest = nullptr;
    // The previous song can still have an audible tail after the next marker.
    // A fresh toggle must target that song until its actual audio has ended.
    for (const auto& child : song->parts) if (child.parentRegionID == root->id && child.startTime <= transport_.position) {
        if (!latest || child.startTime > latest->startTime) latest = &child;
        const auto scope = playbackScope(*song, transport_);
        if (child.startTime < scope.minimum - 1e-6) continue;
        double boundary = root->endTime;
        for (const auto& following : song->parts) if (following.parentRegionID == root->id && following.startTime > child.startTime)
            boundary = std::min(boundary, following.startTime);
        double audioEnd = child.startTime;
        for (const auto& track : song->tracks) if (fixedTrackName(track.role).empty())
            for (const auto& clip : track.clips) if ((clip.audioFile || track.audioFile) && PlaybackScope{child.startTime, boundary}.allows(playbackItemStart(*song, clip)) && playbackItemStart(*song, clip).has_value())
                audioEnd = std::max(audioEnd, clip.startTime + clip.duration);
        if (audioEnd > transport_.position && (!current || child.startTime < current->startTime)) current = &child;
    }
    if (!current) current = latest;
    if (current) for (const auto& child : song->parts) if (child.parentRegionID == root->id && child.startTime > current->startTime && (!next || child.startTime < next->startTime)) next = &child;
    if (!current || !next) return;
    double end = current->startTime; bool hasAudio = false;
    for (const auto& track : song->tracks) {
        if (!fixedTrackName(track.role).empty()) continue;
        for (const auto& clip : track.clips) if ((clip.audioFile || track.audioFile) &&
            PlaybackScope{current->startTime, next->startTime}.allows(playbackItemStart(*song, clip)) && playbackItemStart(*song, clip).has_value()) {
            end = std::max(end, clip.startTime + clip.duration); hasAudio = true;
        }
    }
    transport_.ignoreNextAfter = next->startTime;
    transport_.ignoreNextEnd = hasAudio ? end : current->endTime;
    transport_.ignoreNextRegionId = current->id;
}
void Engine::promoteSubPlay(std::optional<ID> preferredRegion) {
    clearIgnoreNext();
    transport_.position = transport_.subPlay.position;
    transport_.editPosition = transport_.position;
    transport_.playing = true;
    transport_.paused = false;
    const auto* queued = playbackBounds(region(transport_.queuedRegionId));
    const auto queuedEntry = queued && transport_.position >= queued->startTime && transport_.position < queued->endTime
        ? transport_.queuedPlaylistEntryId : std::nullopt;
    transport_.regionId = std::move(preferredRegion);
    transport_.playlistEntryId = queuedEntry;
    playStart_ = subPlayStart_.value_or(transport_.position);
    transport_.playbackStartRegionId = transport_.subPlaybackStartRegionId;
    transport_.subPlaybackStartRegionId.reset();
    transport_.subPlay.playing = false;
    automaticSubplayActive_ = false;
    subPlayStart_.reset(); resumeSub_ = false;
    ++transport_.subPlayPromotion;
    transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); autoRegionQueue_ = false;
    syncRegion();
    if (const auto* active = region(transport_.regionId)) {
        playStart_ = active->startTime;
        // Only the edit cue returns to the incoming song's beginning. The
        // promoted audio head must keep its already-consumed Subplay position.
        const auto* entry = region(transport_.playbackStartRegionId);
        const bool entryInActive = entry && (entry->id == active->id || entry->parentRegionID == active->id);
        transport_.editPosition = entryInActive && currentSong()
            ? playbackRegionStart(*currentSong(), *entry) : active->startTime;
    }
}
const Part* Engine::playbackBounds(const Part* part) const {
    if (part && part->parentRegionID) {
        if (const auto* parent = region(part->parentRegionID)) return parent;
    }
    return part;
}
void Engine::syncRegion() {
    const auto* active = playbackBounds(region(transport_.regionId));
    if (!active || transport_.position < active->startTime || transport_.position >= active->endTime) {
        transport_.regionId.reset();
        if (const auto* song = currentSong()) {
            const Part* candidate = nullptr;
            for (const auto& part : song->parts)
                if (!part.parentRegionID && transport_.position >= part.startTime && transport_.position < part.endTime &&
                    (!candidate || part.endTime - part.startTime < candidate->endTime - candidate->startTime)) candidate = &part;
            if (candidate) {
                transport_.regionId = candidate->id;
                if (transport_.playing && playStart_ &&
                    (*playStart_ < candidate->startTime || *playStart_ >= candidate->endTime))
                    playStart_ = candidate->startTime;
            }
        }
        if (autoRegionQueue_) { transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); }
        autoRegionQueue_ = false;
    }
    syncPlaylistEntries();
    autoQueueRegion();
}
void Engine::addTrack(ID id, std::string name, TrackRole role) {
    projectSync::requireWritable();
    if (!currentSong() || id.empty() || name.empty() || role.id.empty()) throw std::invalid_argument("Invalid track");
    Project next = project_;
    for (auto& song : next.songs) if (song.id == transport_.songId) {
        Track track; track.id = std::move(id); track.name = fixedTrackName(role).empty() ? std::move(name) : fixedTrackName(role); track.role = std::move(role);
        // Match Swift Track.defaultStandardColor without recoloring decoded tracks.
        if (fixedTrackName(track.role).empty()) track.color = 0x828282;
        if (track.role.id == "timecode") { track.timecode.emplace(); track.patch = OutputPatch{-1,2}; }
        song.tracks.push_back(std::move(track)); break;
    }
    orderSpecialTracks(next); synchronizeTimecode(next); validate(next); project_ = std::move(next);
}
void Engine::resizeRegion(const ID& id, double start, double end) {
    projectSync::requireWritable();
    if (!std::isfinite(start) || !std::isfinite(end) || start < 0 || end <= start)
        throw std::invalid_argument("Invalid region bounds");
    Project next = project_;
    for (auto& song : next.songs) if (song.id == transport_.songId) {
        for (auto& region : song.parts) if (region.id == id) {
            if (region.parentRegionID) throw std::invalid_argument("Unified songs cannot be resized independently");
            if (std::any_of(song.parts.begin(), song.parts.end(), [&](const auto& child) { return child.parentRegionID == id; }))
                throw std::invalid_argument("Unified regions cannot be resized");
            region.startTime = start; region.endTime = end;
            song.duration = std::max(song.duration, end);
            orderSpecialTracks(next); synchronizeTimecode(next); validate(next); project_ = std::move(next); return;
        }
    }
    throw std::invalid_argument("Unknown region");
}
// Commit-time counterpart of RegionMarkerRepulsion. The grid uses a larger
// zoom-aware margin; direct/native callers still cannot stack marker points.
static double repelRegionMarkers(const Song& song, const Part& region, double proposed) {
    constexpr double gap = 0.01;
    std::vector<double> offsets, stationary;
    double minimumStart = 0;
    if (song.markers) for (const auto& marker : *song.markers) {
        const bool owned = regionOwns(song, region.id, marker.regionOwnerID) || marker.unifiedRegionID == region.id;
        if (owned) { offsets.push_back(marker.position - region.startTime); minimumStart = std::max(minimumStart, region.startTime - marker.position); }
        else stationary.push_back(marker.position);
    }
    std::vector<std::pair<double,double>> ranges, merged;
    for (const auto offset : offsets) for (const auto point : stationary) {
        const double center = point - offset;
        if (center + gap > minimumStart) ranges.emplace_back(center - gap, center + gap);
    }
    std::sort(ranges.begin(), ranges.end());
    for (const auto& range : ranges) {
        if (!merged.empty() && range.first < merged.back().second) merged.back().second = std::max(merged.back().second, range.second);
        else merged.push_back(range);
    }
    const double start = std::max(minimumStart, proposed);
    for (const auto& range : merged) if (start > range.first + 1e-9 && start < range.second - 1e-9) {
        if (range.first < minimumStart) return range.second;
        const double left = start - range.first, right = range.second - start;
        if (std::abs(left - right) <= 1e-9) return proposed >= region.startTime ? range.second : range.first;
        return left < right ? range.first : range.second;
    }
    return start;
}
void Engine::moveRegion(const ID& id, double start) {
    projectSync::requireWritable();
    if (!std::isfinite(start) || start < 0) throw std::invalid_argument("Invalid region position");
    Project next = project_;
    for (auto& song : next.songs) if (song.id == transport_.songId) {
        for (auto& region : song.parts) if (region.id == id) {
            if (region.parentRegionID) throw std::invalid_argument("Unified songs cannot be moved independently");
            start = repelRegionMarkers(song, region, start);
            const double oldStart = region.startTime, oldEnd = region.endTime, delta = start - oldStart;
            for (auto& track : song.tracks) for (auto& clip : track.clips)
                if (regionOwns(song, id, clip.regionOwnerID)) {
                    clip.startTime = std::max(0.0, clip.startTime + delta);
                    song.duration = std::max(song.duration, clip.startTime + clip.duration);
                }
            for (auto& child : song.parts) if (child.parentRegionID == id) { child.startTime += delta; child.endTime += delta; }
            // Follow persisted membership, including a special region's children.
            if (song.markers) for (auto& marker : *song.markers) {
                const bool owned = regionOwns(song, id, marker.regionOwnerID) || marker.unifiedRegionID == id;
                if (owned) {
                    marker.position = std::max(0.0, marker.position + delta);
                    song.duration = std::max(song.duration, marker.position);
                }
            }
            region.startTime = start; region.endTime = oldEnd + delta;
            song.duration = std::max(song.duration, region.endTime);
            orderSpecialTracks(next); synchronizeTimecode(next); validate(next); project_ = std::move(next); return;
        }
    }
    throw std::invalid_argument("Unknown region");
}
void Engine::setRegionInit(const ID& id, int count, bool bars) {
    projectSync::requireWritable();
    if(count<1 || count>5) throw std::invalid_argument("Invalid Config Init count");
    for(auto& song:project_.songs) if(song.id==transport_.songId)
        for(auto& part:song.parts) if(part.id==id) {
            if(bars) part.subplayInitBars=count;
            else {part.subplayInitBars.reset();part.subplayInitSeconds=count;}
            return;
        }
    throw std::invalid_argument("Unknown region");
}
void Engine::setRegionPitch(const ID& id, int semitones, std::vector<ID> tracks, std::vector<ID> groups) {
    projectSync::requireWritable();
    if (semitones < -12 || semitones > 12) throw std::invalid_argument("Invalid region pitch");
    for (auto& song : project_.songs) if (song.id == transport_.songId) {
        for (const auto& identifiers : {tracks, groups}) for (const auto& target : identifiers)
            if (std::none_of(song.tracks.begin(), song.tracks.end(), [&](const auto& t) { return t.id == target && fixedTrackName(t.role).empty(); })) throw std::invalid_argument("Invalid pitch track");
        for (auto& part : song.parts) if (part.id == id) {
            part.pitchSemitones = semitones; part.pitchTrackIDs = std::move(tracks); part.pitchGroupIDs = std::move(groups); return;
        }
    }
    throw std::invalid_argument("Unknown region");
}
void Engine::editRegion(const ID& id, std::string name, unsigned color, bool uppercaseName) {
    projectSync::requireWritable();
    if (name.empty() || color > 0xFFFFFF) throw std::invalid_argument("Invalid region settings");
    for (auto& song : project_.songs) if (song.id == transport_.songId)
        for (auto& part : song.parts) if (part.id == id) {
            part.name = std::move(name); part.color = color; part.uppercaseName = uppercaseName;
            if (song.markers) for (auto& marker : *song.markers) if (marker.sourceRegionID == id) {
                marker.name = part.name; marker.color = color;
            }
            return;
        }
    throw std::invalid_argument("Unknown region");
}
void Engine::moveClip(const ID& clipId, double start, const ID& destination) {
    projectSync::requireWritable();
    if (!std::isfinite(start) || start < 0) throw std::invalid_argument("Invalid clip position");
    Project next = project_;
    for (auto& song : next.songs) if (song.id == transport_.songId) {
        for (auto& track : song.tracks) for (auto it = track.clips.begin(); it != track.clips.end(); ++it) if (it->id == clipId) {
            auto target = std::find_if(song.tracks.begin(), song.tracks.end(), [&](const auto& t) { return t.id == (destination.empty() ? track.id : destination); });
            if (target == song.tracks.end()) throw std::invalid_argument("Unknown destination track");
            const bool projectionMedia = it->audioFile && it->audioFile->path.rfind("Videos/", 0) == 0;
            const bool mediaTransfer = projectionMedia;
            if (!mediaTransfer && !fixedTrackName(track.role).empty() && target->id != track.id) throw std::invalid_argument("Special items can only move horizontally on their own track");
            if (!mediaTransfer && fixedTrackName(track.role) != fixedTrackName(target->role)) throw std::invalid_argument("Items must stay on a compatible track");
            if (track.role.id == "timecode" && !projectionMedia) throw std::invalid_argument("Timecode items follow their regions");
            auto clip = *it;
            clip.startTime = start;
            clip.regionOwnerID = regionOwnerAt(song, start);
            track.clips.erase(it);
            target->clips.push_back(clip);
            song.duration = std::max(song.duration, start + clip.duration);
            orderSpecialTracks(next); synchronizeTimecode(next); validate(next); project_ = std::move(next); return;
        }
    }
    throw std::invalid_argument("Unknown clip");
}
void Engine::deleteManualMarker(const ID& id) {
    projectSync::requireWritable();
    auto song = std::find_if(project_.songs.begin(), project_.songs.end(), [&](const auto& value) { return value.id == transport_.songId; });
    if (song == project_.songs.end() || !song->markers) throw std::invalid_argument("Unknown marker");
    auto marker = std::find_if(song->markers->begin(), song->markers->end(), [&](const auto& value) { return value.id == id; });
    if (marker == song->markers->end()) throw std::invalid_argument("Unknown marker");
    if (marker->unifiedRegionID || marker->sourceRegionID) throw std::invalid_argument("Unified song markers cannot be deleted");
    song->markers->erase(marker);
    for (auto& part : song->parts) {
        auto& loops = part.multiLoops;
        loops.erase(std::remove_if(loops.begin(), loops.end(), [&](const auto& loop) {
            return loop.marker1 == id || loop.marker2 == id;
        }), loops.end());
    }
    refreshMultiLoop();
}
void Engine::setProjectTiming(double bpm, int beats, int unit, std::optional<ProjectTimeSettings> settings) {
    projectSync::requireWritable();
    if (!std::isfinite(bpm) || bpm < 60 || bpm > 300 || beats < 1 || beats > 32 ||
        unit < 1 || unit > 64 || (unit & (unit - 1)) != 0 ||
        (settings && !validProjectTimeSettings(*settings))) throw std::invalid_argument("Invalid project timing");
    auto* song = const_cast<Song*>(currentSong());
    if (!song) throw std::invalid_argument("No current arrangement");
    const bool relative = settings.value_or(ProjectTimeSettings{}).timebase == ProjectTimebase::relative;
    const double speed = relative ? bpm / song->bpm : 1, scale = 1 / speed;
    if (relative && bpm != song->bpm) {
        for (const auto& track : song->tracks) for (const auto& clip : track.clips)
            if (clip.playbackRate * speed < 1.0/32 || clip.playbackRate * speed > 32)
                throw std::invalid_argument("Audio stretch range exceeded");
        song->duration *= scale;
        for (auto& track : song->tracks) for (auto& clip : track.clips) {
            const double end = (clip.startTime + clip.duration) * scale;
            if (!clip.tempoBasePlaybackRate) clip.tempoBasePlaybackRate = clip.playbackRate;
            clip.startTime *= scale; clip.duration = end - clip.startTime; clip.playbackRate *= speed;
            if (clip.timecodeStartOffset) *clip.timecodeStartOffset *= scale;
            if (clip.timecodeEndOffset) *clip.timecodeEndOffset *= scale;
            song->duration = std::max(song->duration, clip.startTime + clip.duration);
        }
        for (auto& part : song->parts) { part.startTime *= scale; part.endTime *= scale; }
        if (song->markers) for (auto& marker : *song->markers) marker.position *= scale;
        transport_.position *= scale; transport_.editPosition *= scale;
        transport_.subPlay.position *= scale; transport_.queueStartedAt *= scale;
        if (playStart_) *playStart_ *= scale;
        if (subPlayStart_) *subPlayStart_ *= scale;
        if (transport_.ignoreNextAfter) *transport_.ignoreNextAfter *= scale;
        if (transport_.ignoreNextEnd) *transport_.ignoreNextEnd *= scale;
    }
    song->bpm = bpm; song->beatsPerBar = beats; song->beatUnit = unit; song->timeSettings = settings;
}
void Engine::setMarker(ID id, std::string name, double position, unsigned color, std::optional<double> bpm, std::optional<int> beats, std::optional<int> unit, std::optional<std::string> timebase, std::optional<bool> section, std::optional<bool> loopSection) {
    projectSync::requireWritable();
    Project next = project_;
    auto song = std::find_if(next.songs.begin(), next.songs.end(), [&](const auto& value) { return value.id == transport_.songId; });
    if (song == next.songs.end()) throw std::invalid_argument("No current arrangement");
    const Song& beforeTempoEdit = *currentSong();
    if (!song->markers) song->markers.emplace();
    auto found = std::find_if(song->markers->begin(), song->markers->end(), [&](const auto& marker) { return marker.id == id; });
    if(found==song->markers->end() && std::any_of(song->markers->begin(),song->markers->end(),[&](const auto& marker){
        return marker.tempoBPM.has_value()==bpm.has_value() && std::abs(marker.position-position)<0.000001;
    })) throw std::invalid_argument("A marker already exists at this position.");
    const bool retime = bpm && (found == song->markers->end() || found->tempoBPM != bpm || found->tempoTimebase != timebase);
    TimelineMarker marker{std::move(id), std::move(name), position, color};
    if (found != song->markers->end()) marker.unifiedRegionID = found->unifiedRegionID;
    if (found != song->markers->end()) marker.sourceRegionID = found->sourceRegionID;
    marker.regionOwnerID = found != song->markers->end() && found->position == position ? found->regionOwnerID : regionOwnerAt(*song, position);
    if (bpm && found != song->markers->end()) marker.tempoReferenceBPM = found->tempoReferenceBPM;
    marker.section = section ? section : (found != song->markers->end() ? found->section : std::nullopt);
    marker.loopSection = loopSection ? loopSection : (found != song->markers->end() ? found->loopSection : std::nullopt);
    if (marker.section.value_or(false) && !std::any_of(song->parts.begin(), song->parts.end(), [&](const auto& part) { return position >= part.startTime && position <= part.endTime; })) throw std::invalid_argument("Section markers can only be created inside a song.");
    marker.tempoBPM = bpm; marker.tempoBeats = beats; marker.tempoUnit = unit;
    marker.tempoTimebase = std::move(timebase);
    if (std::isfinite(position)) song->duration = std::max(song->duration, position);
    if (marker.sourceRegionID) for (auto& part : song->parts) if (part.id == *marker.sourceRegionID) {
        part.name = marker.name; part.color = marker.color;
    }
    if (found == song->markers->end()) song->markers->push_back(std::move(marker)); else *found = std::move(marker);
    const TempoEditMap map(beforeTempoEdit,*song);
    if(retime) map.apply(*song);
    orderSpecialTracks(next); synchronizeTimecode(next); validate(next); project_ = std::move(next);
    if(retime && map.changesTime()) {
        transport_.position=map.position(transport_.position); transport_.editPosition=map.position(transport_.editPosition);
        transport_.subPlay.position=map.position(transport_.subPlay.position); transport_.queueStartedAt=map.position(transport_.queueStartedAt);
        if(transport_.loop.start) *transport_.loop.start=map.position(*transport_.loop.start);
        if(transport_.loop.end) *transport_.loop.end=map.position(*transport_.loop.end);
        if(transport_.ignoreNextAfter) *transport_.ignoreNextAfter=map.position(*transport_.ignoreNextAfter);
        if(transport_.ignoreNextEnd) *transport_.ignoreNextEnd=map.position(*transport_.ignoreNextEnd);
        if(playStart_) *playStart_=map.position(*playStart_);
        if(subPlayStart_) *subPlayStart_=map.position(*subPlayStart_);
        if(transport_.queuedSectionMarkerId) transport_.sectionQueueStartedAt=map.position(transport_.sectionQueueStartedAt);
        if(transport_.multiLoop) {transport_.multiLoop->start=map.position(transport_.multiLoop->start);transport_.multiLoop->end=map.position(transport_.multiLoop->end);}
    }
}
namespace {
// Tempo edits change item timing, never their already-validated peak samples.
// Park the large arrays while copying/validating metadata, and move them back
// without reallocating. An exception restores the original project intact.
class TempoWaveformStorage {
    struct Entry {
        AudioClip* original;
        std::vector<double> overview;
        std::vector<std::vector<double>> channels;
    };
    std::vector<Entry> entries;
public:
    explicit TempoWaveformStorage(Project& project) {
        for(auto& song:project.songs) for(auto& track:song.tracks) for(auto& clip:track.clips)
            if(!clip.waveform.empty() || !clip.waveformChannels.empty()) entries.push_back({&clip,{},{}});
        // All potentially throwing allocations above finish before touching data.
        for(auto& entry:entries) {
            entry.overview.swap(entry.original->waveform);
            entry.channels.swap(entry.original->waveformChannels);
        }
    }
    ~TempoWaveformStorage() {
        for(auto& entry:entries) {
            entry.overview.swap(entry.original->waveform);
            entry.channels.swap(entry.original->waveformChannels);
        }
    }
    void transfer(Project& next) {
        std::unordered_map<ID,AudioClip*> clips;
        for(auto& song:next.songs) for(auto& track:song.tracks) for(auto& clip:track.clips) clips.emplace(clip.id,&clip);
        for(const auto& entry:entries)
            if(!clips.count(entry.original->id)) throw std::logic_error("Tempo edit removed an audio item");
        for(auto& entry:entries) {
            auto* target=clips.at(entry.original->id);
            entry.overview.swap(target->waveform);
            entry.channels.swap(target->waveformChannels);
        }
        entries.clear();
    }
};
}
void Engine::setMarkers(const std::vector<TimelineMarker>& markers, const std::vector<ID>& removing, bool retime) {
    projectSync::requireWritable();
    TempoWaveformStorage waveforms(project_);
    Project next = project_;
    auto song = std::find_if(next.songs.begin(), next.songs.end(), [&](const auto& value) { return value.id == transport_.songId; });
    if (song == next.songs.end()) throw std::invalid_argument("No current arrangement");
    const Song& beforeTempoEdit = *currentSong();
    const auto originalTiming = song->timeSettings;
    auto freeTiming = originalTiming.value_or(ProjectTimeSettings{});
    freeTiming.timebase = ProjectTimebase::free;
    song->timeSettings = freeTiming;
    if (!song->markers) song->markers.emplace();
    song->markers->erase(std::remove_if(song->markers->begin(), song->markers->end(), [&](const auto& marker) {
        return marker.tempoBPM && std::find(removing.begin(), removing.end(), marker.id) != removing.end();
    }), song->markers->end());
    for (auto marker : markers) {
        auto found = std::find_if(song->markers->begin(), song->markers->end(), [&](const auto& item) { return item.id == marker.id; });
        // Match single-marker placement before retiming. In-place edits retain
        // explicit nil ownership, even when a region has moved over the marker.
        marker.regionOwnerID = found != song->markers->end() && found->position == marker.position
            ? found->regionOwnerID : regionOwnerAt(*song, marker.position);
        if (found == song->markers->end()) song->markers->push_back(marker); else *found = marker;
        if (std::isfinite(marker.position)) song->duration = std::max(song->duration, marker.position);
    }
    song->timeSettings = originalTiming;
    std::optional<TempoEditMap> map;
    if (retime) { map.emplace(beforeTempoEdit, *song); map->apply(*song); }
    orderSpecialTracks(next); synchronizeTimecode(next); validate(next); waveforms.transfer(next); project_ = std::move(next);
    if(map && map->changesTime()) {
        transport_.position=map->position(transport_.position); transport_.editPosition=map->position(transport_.editPosition);
        transport_.subPlay.position=map->position(transport_.subPlay.position); transport_.queueStartedAt=map->position(transport_.queueStartedAt);
        if(transport_.loop.start) *transport_.loop.start=map->position(*transport_.loop.start);
        if(transport_.loop.end) *transport_.loop.end=map->position(*transport_.loop.end);
        if(transport_.ignoreNextAfter) *transport_.ignoreNextAfter=map->position(*transport_.ignoreNextAfter);
        if(transport_.ignoreNextEnd) *transport_.ignoreNextEnd=map->position(*transport_.ignoreNextEnd);
        if(playStart_) *playStart_=map->position(*playStart_);
        if(subPlayStart_) *subPlayStart_=map->position(*subPlayStart_);
        if(transport_.queuedSectionMarkerId) transport_.sectionQueueStartedAt=map->position(transport_.sectionQueueStartedAt);
        if(transport_.multiLoop) {transport_.multiLoop->start=map->position(transport_.multiLoop->start);transport_.multiLoop->end=map->position(transport_.multiLoop->end);}
    }
}
void Engine::regionFromClip(const ID& clipId, ID regionId) {
    projectSync::requireWritable();
    regionsFromClips({{clipId, std::move(regionId)}});
}
void Engine::regionsFromClips(const std::vector<std::pair<ID, ID>>& items) {
    projectSync::requireWritable();
    if (items.empty()) return;
    Project next = project_;
    auto song = std::find_if(next.songs.begin(), next.songs.end(), [&](const auto& value) { return value.id == transport_.songId; });
    if (song == next.songs.end()) throw std::invalid_argument("No current arrangement");
    static std::mt19937 colors(std::random_device{}());
    std::uniform_int_distribution<unsigned> channel(70, 235);
    for (const auto& [clipId, regionId] : items) {
        const AudioClip* source = nullptr;
        for (const auto& track : song->tracks) for (const auto& clip : track.clips) if (clip.id == clipId) {
            if (track.role.id == "timecode" && !(clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0)) throw std::invalid_argument("Timecode items cannot create regions");
            source = &clip;
        }
        if (!source) throw std::invalid_argument("Unknown clip");
        if (std::any_of(song->parts.begin(), song->parts.end(), [&](const auto& part) { return std::abs(part.startTime - source->startTime) < 0.000001; })) continue;
        std::string name = source->name;
        const auto dot = name.find_last_of('.');
        if (dot != std::string::npos) {
            auto extension = name.substr(dot);
            std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char c) { return std::tolower(c); });
            for (const auto* audioExtension : {".wav", ".wave", ".mp3", ".aif", ".aiff", ".m4a", ".aac", ".caf", ".flac"}) {
                if (extension == audioExtension) { name.resize(dot); break; }
            }
        }
        if (name.empty()) name = source->name;
        const unsigned rgb = (channel(colors) << 16) | (channel(colors) << 8) | channel(colors);
        song->parts.push_back({regionId, name, source->startTime, source->startTime + source->duration, rgb});
        for (auto& track : song->tracks) for (auto& clip : track.clips) if (clip.id == clipId) clip.regionOwnerID = regionId;
    }
    orderSpecialTracks(next); synchronizeTimecode(next); synchronizeRegionOwnership(next, &project_); validate(next); project_ = std::move(next);
}
void Engine::setTimecode(const ID& id, TimecodeSettings settings) {
    projectSync::requireWritable();
    if ((settings.mode != "mtc" && settings.mode != "ltc") ||
        (settings.frameRate != 24 && settings.frameRate != 25 && settings.frameRate != 29.97 && settings.frameRate != 30) ||
        !std::isfinite(settings.offset) || settings.offset < 0 || settings.offset >= 86400)
        throw std::invalid_argument("Invalid timecode settings");
    for (auto& song : project_.songs) for (auto& track : song.tracks) if (track.id == id && track.role.id == "timecode") {
        const auto previous = track.timecode.value_or(TimecodeSettings{});
        for (auto& clip : track.clips) if (clip.timecode) {
            if (settings.mode != previous.mode) clip.timecode->mode = settings.mode;
            if (settings.frameRate != previous.frameRate) clip.timecode->frameRate = settings.frameRate;
            if (settings.offset != previous.offset) clip.timecode->offset = settings.offset;
            if (settings.regionRelative != previous.regionRelative) clip.timecode->regionRelative = settings.regionRelative;
            if (settings.midiDestination != previous.midiDestination) clip.timecode->midiDestination = settings.midiDestination;
        }
        track.timecode = std::move(settings);
        for (auto& clip : track.clips) if (!clip.audioFile) clip.name = "TIMECODE";
        return;
    }
    throw std::invalid_argument("Unknown Timecode track");
}
void Engine::setFX(const ID& id, std::string json) {
    projectSync::requireWritable();
    // Track/Master VST3 presets need the same capacity as item FX snapshots.
    if(json.empty() || json.size()>32 * 1024 * 1024) throw std::invalid_argument("Invalid FX data");
    if(id.empty()) { project_.masterFXJSON=std::move(json); return; }
    for(auto& song:project_.songs) for(auto& track:song.tracks) if(track.id==id) { if (isTeleprompterRole(track.role) || track.role.id == "chords" || track.role.id == "generatedClick") throw std::invalid_argument("This special track cannot contain FX"); track.fxJSON=std::move(json); return; }
    throw std::invalid_argument("Unknown FX track");
}
void Engine::setClipFX(const ID& id, std::string json) {
    projectSync::requireWritable();
    validateClipFXJSON(json);
    for (auto& song : project_.songs) for (auto& track : song.tracks) for (auto& clip : track.clips) if (clip.id == id) {
        if (!fixedTrackName(track.role).empty() && !(clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0)) throw std::invalid_argument("Item FX requires an audio item");
        clip.fxJSON = std::move(json); return;
    }
    throw std::invalid_argument("Unknown FX item");
}
void Engine::setClipFXBypass(const ID& id, bool bypassed) {
    projectSync::requireWritable();
    for (auto& song : project_.songs) for (auto& track : song.tracks) for (auto& clip : track.clips) if (clip.id == id) {
        if (!fixedTrackName(track.role).empty() && !(clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0)) throw std::invalid_argument("Item FX requires an audio item");
        clip.fxBypassed = bypassed; return;
    }
    throw std::invalid_argument("Unknown FX item");
}
void Engine::setClipText(const ID& id, std::string text) {
    projectSync::requireWritable();
    validateClipText(text);
    for (auto& song : project_.songs) for (auto& track : song.tracks) for (auto& clip : track.clips) if (clip.id == id) {
        if (!isTeleprompterRole(track.role) && track.role.id != "chords") throw std::invalid_argument("Text items require a Teleprompter or Chords track");
        if (clip.audioFile) throw std::invalid_argument("Media items do not contain editable text");
        clip.text = std::move(text); return;
    }
    throw std::invalid_argument("Unknown text item");
}
void Engine::setMIDIInput(const ID& id, int slot) {
    projectSync::requireWritable();
    if(slot < 0 || slot > 3) throw std::invalid_argument("Invalid MIDI input");
    for(auto& song : project_.songs) for(auto& track : song.tracks) if(track.id == id) {
        if (isTeleprompterRole(track.role) || track.role.id == "chords" || track.role.id == "generatedClick") throw std::invalid_argument("This special track cannot contain FX");
        track.midiInput = slot == 0 ? std::nullopt : std::optional<int>(slot); return;
    }
    throw std::invalid_argument("Unknown MIDI track");
}
void Engine::setMIDIChannel(const ID& id, int channel) {
    projectSync::requireWritable();
    if(channel < 0 || channel > 16) throw std::invalid_argument("Invalid MIDI channel");
    for(auto& song : project_.songs) for(auto& track : song.tracks) if(track.id == id) {
        if (isTeleprompterRole(track.role) || track.role.id == "chords" || track.role.id == "generatedClick") throw std::invalid_argument("This special track cannot contain FX");
        track.midiChannel = channel == 0 ? std::nullopt : std::optional<int>(channel); return;
    }
    throw std::invalid_argument("Unknown MIDI track");
}
void Engine::setInputMonitoring(const ID& id, bool enabled) {
    projectSync::requireWritable();
    for(auto& song : project_.songs) for(auto& track : song.tracks) if(track.id == id) { track.inputMonitoring = enabled; return; }
    throw std::invalid_argument("Unknown track");
}
void Engine::setRecordingChannels(const ID& id, int channel) {
    projectSync::requireWritable();
    if(channel < 0 || channel > 2) throw std::invalid_argument("Invalid recording channel mode");
    for(auto& song : project_.songs) for(auto& track : song.tracks) if(track.id == id) {
        if (isTeleprompterRole(track.role) || track.role.id == "chords" || track.role.id == "generatedClick") throw std::invalid_argument("This special track cannot contain FX");
        track.recordingChannels = channel; return;
    }
    throw std::invalid_argument("Unknown MIDI track");
}
void Engine::setRecording(const ID& id, int first, int count, std::string format) {
    projectSync::requireWritable();
    if(first < 1 || count < 1 || count > 2 || (format != "wav" && format != "wav32" && format != "mp3")) throw std::invalid_argument("Invalid recording settings");
    for(auto& song : project_.songs) for(auto& track : song.tracks) if(track.id == id) { if (isTeleprompterRole(track.role) || track.role.id == "chords" || track.role.id == "generatedClick") throw std::invalid_argument("This special track cannot contain FX"); if (track.stereoLinkPartner) {
        const int top = std::clamp(first - (track.stereoLinkLeft ? 0 : 1), 1, 1023);
        track.inputPatch = OutputPatch{top + (track.stereoLinkLeft ? 0 : 1), 1};
        for (auto& other : song.tracks) if (other.id == *track.stereoLinkPartner && other.stereoLinkPartner == track.id)
            other.inputPatch = OutputPatch{top + (track.stereoLinkLeft ? 1 : 0), 1};
    } else track.inputPatch = OutputPatch{first,count}; track.recordingFormat = std::move(format); return; }
    throw std::invalid_argument("Unknown track");
}
void Engine::pasteItems(const ID& songID, std::vector<Track> tracks, bool moving) {
    projectSync::requireWritable();
    if (tracks.empty()) throw std::invalid_argument("No items to paste");
    Project next = project_;
    auto song = std::find_if(next.songs.begin(), next.songs.end(), [&](const auto& value) { return value.id == songID; });
    if (song == next.songs.end()) throw std::invalid_argument("Unknown destination grid");
    std::set<ID> identifiers;
    for (const auto& source : tracks) {
        auto target = std::find_if(song->tracks.begin(), song->tracks.end(), [&](const auto& track) { return track.id == source.id; });
        if (target == song->tracks.end() || source.clips.empty()) throw std::invalid_argument("Invalid destination track");
        if (target->role.id == "timecode" && std::any_of(source.clips.begin(), source.clips.end(), [](const auto& clip) { return !clip.audioFile || clip.audioFile->path.rfind("Videos/", 0) != 0; })) throw std::invalid_argument("Timecode items cannot be pasted");
        for (const auto& clip : source.clips) {
            if (!identifiers.insert(clip.id).second) throw std::invalid_argument("Duplicate pasted item");
            if (moving) {
                auto item = std::find_if(target->clips.begin(), target->clips.end(), [&](const auto& value) { return value.id == clip.id; });
                if (item == target->clips.end()) throw std::invalid_argument("An item to move no longer exists");
                target->clips.erase(item);
            }
        }
    }
    for (auto& source : tracks) {
        auto target = std::find_if(song->tracks.begin(), song->tracks.end(), [&](const auto& track) { return track.id == source.id; });
        for (auto& clip : source.clips) { song->duration = std::max(song->duration, clip.startTime + clip.duration); target->clips.push_back(std::move(clip)); }
    }
    validate(next); project_ = std::move(next);
}
void Engine::insertAudioTracks(const ID& songID, std::vector<Track> tracks) {
    projectSync::requireWritable();
    if (tracks.empty()) throw std::invalid_argument("No audio files to import");
    Project next = project_;
    auto song = std::find_if(next.songs.begin(), next.songs.end(), [&](const auto& value) { return value.id == songID; });
    if (song == next.songs.end()) throw std::invalid_argument("Unknown destination grid");
    for (auto& imported : tracks) {
        const bool projectionMedia = !imported.clips.empty() && std::all_of(imported.clips.begin(), imported.clips.end(), [](const auto& clip) { return clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0; });
        if (!projectionMedia && (imported.role.id == "timecode" || imported.role.id == "chords")) throw std::invalid_argument("Audio requires an audio track");
        if (imported.clips.empty()) throw std::invalid_argument("Missing imported audio item");
        for (const auto& clip : imported.clips) song->duration = std::max(song->duration, clip.startTime + clip.duration);
        auto destination = std::find_if(song->tracks.begin(), song->tracks.end(), [&](const auto& track) { return track.id == imported.id; });
        if (destination == song->tracks.end()) song->tracks.push_back(std::move(imported));
        else {
            if (!projectionMedia && (fixedTrackName(destination->role) != fixedTrackName(imported.role) || destination->role.id == "timecode" || destination->role.id == "chords")) throw std::invalid_argument("Incompatible track type");
            for (auto& clip : imported.clips) destination->clips.push_back(std::move(clip));
        }
    }
    orderSpecialTracks(next); synchronizeTimecode(next); synchronizeRegionOwnership(next, &project_); validate(next);
    project_ = std::move(next);
}
void Engine::addRecordedClip(const ID& id, AudioClip clip, bool replacing) {
    projectSync::requireWritable();
    Project next = project_;
    for(auto& song : next.songs) for(auto& track : song.tracks) if(track.id == id) {
        const auto recordedID = clip.id;
        const auto recordedOwner = clip.regionOwnerID;
        const bool preserveRecordedOwner = !replacing && clip.midi.has_value();
        song.duration = std::max(song.duration, clip.startTime + clip.duration);
        if (replacing) {
            auto existing = std::find_if(track.clips.begin(), track.clips.end(), [&](const auto& item) { return item.id == clip.id; });
            if (existing == track.clips.end()) throw std::invalid_argument("Unknown audio item");
            *existing = std::move(clip);
        } else track.clips.push_back(std::move(clip));
        orderSpecialTracks(next); synchronizeTimecode(next); synchronizeRegionOwnership(next, &project_);
        // The MIDI capture map was fixed at note input time. Moving a region
        // during the take must not attach a previously loose performance.
        if (preserveRecordedOwner) for (auto& destination : song.tracks) for (auto& recorded : destination.clips) if (recorded.id == recordedID) {
            recorded.regionOwnerID = recordedOwner && std::none_of(song.parts.begin(), song.parts.end(), [&](const auto& part) { return part.id == *recordedOwner; }) ? std::nullopt : recordedOwner;
        }
        validate(next); project_ = std::move(next); return;
    }
    throw std::invalid_argument("Unknown recording track");
}
void Engine::editMasterColor(unsigned color) {
    projectSync::requireWritable();
    if (color > 0xffffff) throw std::invalid_argument("Invalid master color");
    project_.masterColor = color;
}
void Engine::editTrack(const ID& id, std::string name, unsigned color) {
    projectSync::requireWritable();
    if (name.empty() || color > 0xffffff) throw std::invalid_argument("Invalid track name or color");
    for (auto& song : project_.songs) for (auto& track : song.tracks) if (track.id == id) {
        track.name = fixedTrackName(track.role).empty() ? std::move(name) : fixedTrackName(track.role); track.color = color; return;
    }
    throw std::invalid_argument("Unknown track");
}
void Engine::setOutputPatches(const ID& id, const std::vector<OutputPatch>& patches) {
    projectSync::requireWritable();
    for (const auto& patch : patches)
        if (patch.firstChannel < -2 || patch.firstChannel > 1024 || patch.channelCount < 1 || patch.channelCount > 2 || (patch.firstChannel <= 0 && patch.channelCount != 2)) throw std::invalid_argument("Invalid output patch");
    if (id.empty()) {
        for (const auto& patch : patches) if (patch.firstChannel == 0 || patch.firstChannel == -2) throw std::invalid_argument("Master cannot route back into itself");
        project_.masterOutputs = patches; project_.masterPatch.reset(); project_.masterSecondaryPatch.reset(); return;
    }
    for (auto& song : project_.songs) if (song.id == transport_.songId)
        for (auto& track : song.tracks) if (track.id == id) {
            for (const auto& patch : patches) if (patch.firstChannel == -2 && !track.parentTrackID) throw std::invalid_argument("Track has no group");
            auto previous = track.outputs; track.outputs = patches;
            try { validateRouting(song); } catch (...) { track.outputs = previous; throw; }
            track.patch.reset(); track.secondaryPatch.reset(); return;
        }
    throw std::invalid_argument("Unknown track");
}
void Engine::setOutputPatch(const ID& id, int first, int count, int slot) {
    projectSync::requireWritable();
    if (slot < 0 || slot > 1 || first < -2 || first > 1024 || count < 1 || count > 2 || (first <= 0 && count != 2)) throw std::invalid_argument("Invalid output patch");
    if (id.empty()) {
        if (first == 0 || first == -2) throw std::invalid_argument("Master cannot route back into itself");
        if (project_.masterOutputs) {
            auto patches = *project_.masterOutputs; while(patches.size()<=size_t(slot)) patches.push_back(OutputPatch{-1,2}); patches[slot]={first,count}; setOutputPatches(id,patches);
        } else (slot == 0 ? project_.masterPatch : project_.masterSecondaryPatch) = OutputPatch{first, count};
        return;
    }
    for (auto& song : project_.songs) if (song.id == transport_.songId)
        for (auto& track : song.tracks) if (track.id == id) {
            if (first == -2 && !track.parentTrackID) throw std::invalid_argument("Track has no group");
            if (track.outputs) {
                auto patches = *track.outputs; while(patches.size()<=size_t(slot)) patches.push_back(OutputPatch{-1,2}); patches[slot]={first,count}; setOutputPatches(id,patches);
            } else {
                auto& destination = slot == 0 ? track.patch : track.secondaryPatch;
                auto previous = destination; destination = OutputPatch{first,count};
                try { validateRouting(song); } catch (...) {destination=previous;throw;}
            }
            return;
        }
    throw std::invalid_argument("Unknown track");
}

namespace {
std::set<ID> trackSubtree(const std::vector<Track>& tracks, const ID& root) {
    std::set<ID> members{root};
    // Valid projects are in depth-first order, with every parent preceding its children.
    for (const auto& track : tracks)
        if (track.parentTrackID && members.count(*track.parentTrackID)) members.insert(track.id);
    return members;
}
void sendToParent(Track& track) {
    auto patches = track.outputPatches();
    if (patches.empty()) patches.push_back(OutputPatch{-2,2});
    patches.front() = OutputPatch{-2,2};
    // Keep auxiliary hardware sends, but do not leave a second direct Master path.
    patches.erase(std::remove_if(patches.begin() + 1, patches.end(), [](const auto& patch) {
        return patch.firstChannel == 0 || patch.firstChannel == -2;
    }), patches.end());
    track.patch = patches.front();
    track.secondaryPatch = patches.size() > 1 ? std::optional<OutputPatch>{patches[1]} : std::nullopt;
    if (track.outputs) track.outputs = patches;
}
std::vector<Track> orderTrackForest(const std::vector<Track>& tracks) {
    std::map<ID, std::vector<size_t>> children;
    std::vector<size_t> pending;
    for (size_t i = 0; i < tracks.size(); ++i) {
        if (tracks[i].parentTrackID) children[*tracks[i].parentTrackID].push_back(i);
        else pending.push_back(i);
    }
    std::reverse(pending.begin(), pending.end());
    std::vector<Track> result;
    std::set<ID> visited;
    while (!pending.empty()) {
        const auto index = pending.back(); pending.pop_back();
        const auto& track = tracks[index];
        if (!visited.insert(track.id).second) throw std::invalid_argument("Invalid track group");
        result.push_back(track);
        const auto& nested = children[track.id];
        pending.insert(pending.end(), nested.rbegin(), nested.rend());
    }
    if (result.size() != tracks.size()) throw std::invalid_argument("Invalid track group");
    return result;
}
}
void Engine::groupTracks(const std::vector<ID>& ids) {
    projectSync::requireWritable();
    if (ids.size() < 2) throw std::invalid_argument("Select at least two tracks");
    auto song = std::find_if(project_.songs.begin(), project_.songs.end(), [&](const auto& s) { return s.id == transport_.songId; });
    if (song == project_.songs.end()) throw std::invalid_argument("No current arrangement");
    auto tracks = song->tracks;
    std::set<ID> selected(ids.begin(), ids.end());
    for (const auto& id : selected) {
        const auto track = std::find_if(tracks.begin(), tracks.end(), [&](const auto& t) { return t.id == id; });
        if (track == tracks.end()) throw std::invalid_argument("Unknown track");
        if (!fixedTrackName(track->role).empty()) throw std::invalid_argument("Special tracks cannot be grouped");
        if (track->stereoLinkPartner) throw std::invalid_argument("Linked tracks cannot be grouped");
    }
    if (selected.size() < 2) throw std::invalid_argument("Select at least two tracks");
    for (const auto& t : tracks) if (t.parentTrackID && selected.count(*t.parentTrackID)) selected.insert(t.id);
    auto first = std::find_if(tracks.begin(), tracks.end(), [&](const auto& t) { return selected.count(t.id); });
    const ID parent = first->id;
    first->patch = OutputPatch{first->parentTrackID ? -2 : 0,2}; first->secondaryPatch.reset(); first->outputs.reset();
    // Move only the selected subtree roots; their own folders/children keep every internal route.
    for (auto& t : tracks) if (t.id != parent && selected.count(t.id) &&
        (!t.parentTrackID || !selected.count(*t.parentTrackID))) {
        t.parentTrackID = parent; sendToParent(t);
    }
    auto replacement = project_;
    replacement.songs[static_cast<size_t>(song - project_.songs.begin())].tracks = orderTrackForest(tracks);
    orderSpecialTracks(replacement); validate(replacement);
    project_ = std::move(replacement);
}
void Engine::reorderTrack(const ID& id, const ID& before) {
    projectSync::requireWritable();
    for (size_t songIndex = 0; songIndex < project_.songs.size(); ++songIndex) {
        const auto& song = project_.songs[songIndex];
        if (song.id != transport_.songId) continue;
        const auto source = std::find_if(song.tracks.begin(), song.tracks.end(), [&](const auto& t) { return t.id == id; });
        const auto target = before.empty() ? song.tracks.end() : std::find_if(song.tracks.begin(), song.tracks.end(), [&](const auto& t) { return t.id == before; });
        if (source == song.tracks.end() || (!before.empty() && target == song.tracks.end())) throw std::invalid_argument("Unknown track");
        const auto members = trackSubtree(song.tracks, id);
        const bool folder = members.size() > 1;
        if (members.count(before)) return; // Never put a folder inside itself or a descendant.
        std::optional<ID> parent = target == song.tracks.end() ? std::nullopt : target->parentTrackID;
        if (!fixedTrackName(source->role).empty()) parent.reset();
        std::vector<Track> moving, remaining;
        for (auto track : song.tracks) {
            if (members.count(track.id)) {
                if (track.id == id) {
                    track.parentTrackID = parent;
                    if (folder && parent) sendToParent(track);
                    if (!parent) {
                        if (track.outputs) for (auto& patch : *track.outputs) if (patch.firstChannel == -2) patch = OutputPatch{0,2};
                        if (track.patch && track.patch->firstChannel == -2) track.patch = OutputPatch{0,2};
                        if (track.secondaryPatch && track.secondaryPatch->firstChannel == -2) track.secondaryPatch.reset();
                    }
                }
                moving.push_back(std::move(track));
            } else remaining.push_back(std::move(track));
        }
        auto insert = std::find_if(remaining.begin(), remaining.end(), [&](const auto& t) { return t.id == before; });
        const bool targetIsAncestor = target != song.tracks.end() && trackSubtree(song.tracks, target->id).count(id);
        if (folder && parent && !targetIsAncestor) {
            // Dropping on any member appends the entire incoming tree to that member's folder.
            const auto destinationMembers = trackSubtree(remaining, *parent);
            insert = remaining.end();
            for (auto it = remaining.begin(); it != remaining.end(); ++it)
                if (destinationMembers.count(it->id)) insert = it + 1;
        }
        remaining.insert(insert, moving.begin(), moving.end());
        auto replacement = project_;
        replacement.songs[songIndex].tracks = std::move(remaining);
        orderSpecialTracks(replacement); validate(replacement);
        project_ = std::move(replacement);
        return;
    }
    throw std::invalid_argument("No current arrangement");
}
void Engine::execute(const Command& c) {
    projectSync::requireWritable();
    if (c.kind == CommandKind::selectRegion) {
        const auto* list = selectedRegionPlaylist();
        if (list && list->containsEntry(c.target) && list->isDuplicate(c.target)) {
            execute({CommandKind::queueRegion, c.target, c.value}); return;
        }
    }
    const bool mixerControl = c.kind==CommandKind::volume || c.kind==CommandKind::pan ||
        c.kind==CommandKind::mute || c.kind==CommandKind::solo || c.kind==CommandKind::phase || c.kind==CommandKind::masterMono;
    if (projectSync::internalDepth == 0 && !mixerControl) ++syncRevision_;
    if (!std::isfinite(c.value)) throw std::invalid_argument("Non-finite control value");
    if (c.kind == CommandKind::stop || c.kind == CommandKind::stopAll || c.kind == CommandKind::seek || c.kind == CommandKind::select || c.kind == CommandKind::selectRegion || c.kind == CommandKind::next || c.kind == CommandKind::previous) resetMultiLoop();
    if (c.kind == CommandKind::stop || c.kind == CommandKind::stopAll || c.kind == CommandKind::seek || c.kind == CommandKind::select || c.kind == CommandKind::selectRegion || c.kind == CommandKind::next || c.kind == CommandKind::previous) transport_.queuedSectionMarkerId.reset();
    const auto cancelQueuedSection = [&] {
        if (!transport_.queuedSectionMarkerId) return;
        transport_.queuedSectionMarkerId.reset();
        transport_.sectionQueueStartedAt = 0;
        const auto* song = currentSong();
        const auto* part = sectionPlaybackRegion();
        if (!song || !part) return;
        std::optional<double> next;
        if (song->markers) for (const auto& marker : *song->markers) {
            if (!marker.section.value_or(false) || marker.tempoBPM) continue;
            if (transport_.ignoreNextAfter && marker.position >= *transport_.ignoreNextAfter && marker.regionOwnerID != part->id) continue;
            if (marker.position > transport_.position + 1e-9 && marker.position <= part->endTime && (!next || marker.position < *next)) next = marker.position;
        }
        // Cancel previews the next section or the current song's end,
        // without seeking audio or restarting paused playback.
        transport_.editPosition = next.value_or(part->endTime);
    };
    switch (c.kind) {
    case CommandKind::toggleMultiLoopBypass:
        transport_.multiLoopsBypassed = !transport_.multiLoopsBypassed;
        refreshMultiLoop();
        break;
    case CommandKind::cancelSection:
        cancelQueuedSection();
        break;
    case CommandKind::queueSection: {
        const auto target = sectionDestination(c.target);
        if (!target) throw std::invalid_argument("Unknown section marker");
        if (transport_.queuedSectionMarkerId == target->id) { cancelQueuedSection(); break; }
        if (!transport_.playing) { transport_.queuedSectionMarkerId.reset(); execute({CommandKind::editSeek, {}, target->position}); break; }
        const auto* part = sectionPlaybackRegion();
        if (!part) throw std::invalid_argument("Choose a section while a song is playing.");
        transport_.queuedSectionMarkerId = target->id;
        transport_.sectionQueueStartedAt = transport_.position;
        // Preview the destination immediately; playback still jumps at its section boundary.
        execute({CommandKind::editSeek, {}, target->position});
        break;
    }
    case CommandKind::tempo:
    case CommandKind::beatsPerBar:
    case CommandKind::beatUnit: {
        if (!std::isfinite(c.value)) throw std::invalid_argument("Invalid tempo");
        auto* song = const_cast<Song*>(currentSong());
        if (!song) throw std::invalid_argument("No current song");
        if (c.kind == CommandKind::tempo) {
            setProjectTiming(c.value, song->beatsPerBar, song->beatUnit, song->timeSettings);
        } else {
            if (c.value < 1 || c.value > 64) throw std::invalid_argument("Invalid time signature");
            const int value = static_cast<int>(c.value);
            if (value != c.value || value < 1 || value > 64) throw std::invalid_argument("Invalid time signature");
            if (c.kind == CommandKind::beatsPerBar) {
                if (value > 32) throw std::invalid_argument("Invalid beats per bar");
                song->beatsPerBar = value;
            } else {
                if ((value & (value - 1)) != 0) throw std::invalid_argument("Invalid beat unit");
                song->beatUnit = value;
            }
        }
        break;
    }
    case CommandKind::selectRegion:
    case CommandKind::queueRegion: {
        const auto* list = selectedRegionPlaylist();
        const bool duplicate = list && list->containsEntry(c.target) && list->isDuplicate(c.target);
        const auto source = list && list->containsEntry(c.target) ? list->resolvedRegionId(c.target) : c.target;
        const auto* part = region(source);
        if (!part) throw std::invalid_argument("Unknown region");
        if (duplicate) {
            const auto* targetBounds = playbackBounds(part);
            const auto* activeBounds = transport_.playing ? playbackBounds(region(transport_.regionId)) : nullptr;
            const auto* secondaryBounds = transport_.subPlay.playing ? playbackBounds(region(transport_.queuedRegionId)) : nullptr;
            if (targetBounds && ((activeBounds && targetBounds->id == activeBounds->id) ||
                                 (secondaryBounds && targetBounds->id == secondaryBounds->id)))
                throw std::invalid_argument("Cannot queue a duplicate of the song that is playing.");
        }
        const auto entry = entryForRegion(part->id, list && list->containsEntry(c.target) ? std::optional<ID>(c.target) : std::nullopt);
        if (c.kind == CommandKind::queueRegion && transport_.playing) {
            const auto* active = region(transport_.regionId);
            const auto* bounds = playbackBounds(active);
            if (bounds && playbackBounds(part) && playbackBounds(part)->id == bounds->id && duplicate)
                throw std::invalid_argument("Cannot queue a duplicate of the song that is playing.");
            if (bounds && part->id == bounds->id) break;
            const Part* displayed = region(transport_.ignoreNextRegionId);
            if (!displayed && bounds) for (const auto& child : currentSong()->parts) {
                if (child.parentRegionID == bounds->id && transport_.position >= child.startTime && transport_.position < child.endTime &&
                    (!displayed || child.startTime > displayed->startTime ||
                     (child.startTime == displayed->startTime && child.endTime > displayed->endTime))) displayed = &child;
            }
            if (displayed && part->id == displayed->id) break;
            const auto* queued = region(transport_.queuedRegionId);
            if (queued && (part->id == queued->id || queued->parentRegionID == part->id) &&
                (transport_.queuedPlaylistEntryId == entry || (!entry && !transport_.queuedPlaylistEntryId))) {
                transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); transport_.queueStartedAt = 0;
                autoRegionQueue_ = false; automaticSubplayQueue_.reset();
                if (project_.regionSetlist) project_.regionSetlist->autoAdvance = false;
                break;
            }
            if (part->parentRegionID && active && (active->id == *part->parentRegionID || active->parentRegionID == part->parentRegionID))
                throw std::invalid_argument("Cannot queue a song from the active unified region");
            transport_.queuedRegionId = part->id; transport_.queuedPlaylistEntryId = entry; transport_.queueStartedAt = transport_.position;
            transport_.subPlay.position = part->startTime; manualSubCursor_ = false; autoRegionQueue_ = false;
        } else {
            clearIgnoreNext();
            transport_.paused = false; resumeSub_ = false;
            transport_.position = part->startTime; transport_.editPosition = part->startTime; transport_.regionId = part->id; transport_.playlistEntryId = entry;
            transport_.playbackStartRegionId = playbackEntryRegion(*currentSong(), part->startTime);
            transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); autoRegionQueue_ = false; syncRegion();
        }
        break;
    }
    case CommandKind::clipMute:
        for (auto& song : project_.songs) for (auto& track : song.tracks) for (auto& clip : track.clips)
            if (clip.id == c.target) { if (!fixedTrackName(track.role).empty() && !(clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0)) throw std::invalid_argument("Special items cannot be muted"); clip.muted = !clip.muted; return; }
        throw std::invalid_argument("Unknown clip");
    case CommandKind::clipPhase:
    case CommandKind::clipPan:
        if (!std::isfinite(c.value) || (c.kind == CommandKind::clipPan && (c.value < -1 || c.value > 1)) ||
            (c.kind == CommandKind::clipPhase && c.value != 0 && c.value != 1)) throw std::invalid_argument("Invalid item pan or polarity");
        for (auto& song : project_.songs) for (auto& track : song.tracks) for (auto& clip : track.clips)
            if (clip.id == c.target) {
                if (c.kind == CommandKind::clipPhase) clip.phaseInverted = c.value != 0;
                else clip.pan = c.value == 0 ? std::nullopt : std::optional<double>(c.value);
                return;
            }
        throw std::invalid_argument("Unknown clip");
    case CommandKind::clipPitch:
        if (!std::isfinite(c.value) || c.value < -12 || c.value > 12) throw std::invalid_argument("Invalid item pitch");
        for (auto& song : project_.songs) for (auto& track : song.tracks) for (auto& clip : track.clips)
            if (clip.id == c.target) {
                if ((!fixedTrackName(track.role).empty() && !(clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0)) || clip.midi) throw std::invalid_argument("Select audio items to tune");
                clip.pitchSemitones = c.value == 0 ? std::nullopt : std::optional<double>(c.value); return;
            }
        throw std::invalid_argument("Unknown clip");
    case CommandKind::clipChannelMode:
        if (!std::isfinite(c.value) || c.value < 0 || c.value > 4 || c.value != std::floor(c.value)) throw std::invalid_argument("Invalid item channel mode");
        for (auto& song : project_.songs) for (auto& track : song.tracks) for (auto& clip : track.clips)
            if (clip.id == c.target) {
                if (!fixedTrackName(track.role).empty() && !(clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0)) throw std::invalid_argument("Special item channels cannot be changed");
                clip.channelMode = c.value == 0 ? std::nullopt : std::optional<int>(int(c.value)); return;
            }
        throw std::invalid_argument("Unknown clip");
    case CommandKind::clipFadeInCurve:
    case CommandKind::clipFadeInSCurve:
    case CommandKind::clipFadeOutCurve:
    case CommandKind::clipFadeOutSCurve:
        if (!std::isfinite(c.value) || c.value < -1 || c.value > 1) throw std::invalid_argument("Invalid fade curve");
        for (auto& song : project_.songs) for (auto& track : song.tracks) for (auto& clip : track.clips)
            if (clip.id == c.target) {
                if (!fixedTrackName(track.role).empty() && !(clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0)) throw std::invalid_argument("Special items cannot have fades");
                if (c.kind == CommandKind::clipFadeInCurve) clip.fadeInCurve = c.value;
                if (c.kind == CommandKind::clipFadeInSCurve) clip.fadeInSCurve = c.value;
                if (c.kind == CommandKind::clipFadeOutCurve) clip.fadeOutCurve = c.value;
                if (c.kind == CommandKind::clipFadeOutSCurve) clip.fadeOutSCurve = c.value;
                return;
            }
        throw std::invalid_argument("Unknown clip");
    case CommandKind::clipFadeIn:
    case CommandKind::clipFadeOut:
        if (!std::isfinite(c.value) || c.value < 0) throw std::invalid_argument("Invalid item fade");
        for (auto& song : project_.songs) for (auto& track : song.tracks) for (auto& clip : track.clips)
            if (clip.id == c.target) {
                if (!fixedTrackName(track.role).empty() && !(clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0)) throw std::invalid_argument("Special items cannot have fades");
                auto& fade = c.kind == CommandKind::clipFadeIn ? clip.fadeIn : clip.fadeOut;
                fade = c.value == 0 ? std::nullopt : std::optional<double>(std::min(clip.duration,c.value));
                return;
            }
        throw std::invalid_argument("Unknown clip");
    case CommandKind::clipNormalization:
    case CommandKind::clipGain:
        if (c.value < 0 || c.value > std::pow(10.0, 24.0 / 20.0)) throw std::invalid_argument("Item gain must be between silence and +24 dB");
        for (auto& song : project_.songs) for (auto& track : song.tracks) for (auto& clip : track.clips)
            if (clip.id == c.target) {
                if (!fixedTrackName(track.role).empty() && !(clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0)) throw std::invalid_argument("Special item gain cannot be changed");
                if (c.kind == CommandKind::clipNormalization) { if (c.value == 1) clip.normalizationGain.reset(); else clip.normalizationGain = c.value; }
                else clip.gain = c.value;
                return;
            }
        throw std::invalid_argument("Unknown clip");
    case CommandKind::ignoreNext: toggleIgnoreNext(); break;
    case CommandKind::pause:
        if (transport_.playing) {
            resumeSub_ = transport_.subPlay.playing;
            transport_.subPlay.playing = false;
            transport_.playing = false;
            transport_.paused = true;
        }
        break;
    case CommandKind::play:
        if (currentSong()) {
            if (!transport_.playing && !transport_.paused) {
                transport_.position = transport_.editPosition;
                if (transport_.position >= currentSong()->duration) transport_.position = 0;
                playStart_ = transport_.position;
                transport_.playbackStartRegionId = playbackEntryRegion(*currentSong(), transport_.position);
            }
            if (transport_.paused && resumeSub_) transport_.subPlay.playing = true;
            transport_.paused = false; resumeSub_ = false;
            transport_.playing = true; syncRegion(); refreshMultiLoop();
        }
        break;
    case CommandKind::subPlay:
        if (transport_.playing && currentSong() && !transport_.subPlay.playing) {
            automaticSubplayActive_ = false;
            // Auto/prepare follows the queue until the user explicitly places
            // the secondary cursor. Manual placement is free across the timeline.
            if (!manualSubCursor_) if (const auto* queued = region(transport_.queuedRegionId))
                transport_.subPlay.position = queued->startTime;
            subPlayStart_ = transport_.subPlay.position;
            transport_.subPlaybackStartRegionId = playbackEntryRegion(*currentSong(), transport_.subPlay.position);
            transport_.subPlay.playing = true;
        }
        break;
    case CommandKind::subStop: automaticSubplayActive_ = false; transport_.subPlay.playing = false; if (subPlayStart_) transport_.subPlay.position = *subPlayStart_; subPlayStart_.reset(); break;
    case CommandKind::subSeek: manualSubCursor_ = true; automaticSubplayActive_ = false; if (currentSong()) { transport_.subPlay.position = std::max(0.0, c.value); transport_.subPlaybackStartRegionId = playbackEntryRegion(*currentSong(), transport_.subPlay.position); } break;
    case CommandKind::stopAll: execute({CommandKind::subStop}); execute({CommandKind::stop}); break;
    case CommandKind::stop:
        automaticSubplayQueue_.reset();
        clearIgnoreNext();
        if (transport_.subPlay.playing) { promoteSubPlay(); break; }
        {
            const auto* queued = region(transport_.queuedRegionId);
            transport_.paused = false; resumeSub_ = false; execute({CommandKind::subStop}); transport_.playing = false;
            if (queued) {
                transport_.position = queued->startTime; transport_.editPosition = queued->startTime; transport_.regionId = queued->id;
                transport_.playlistEntryId = transport_.queuedPlaylistEntryId;
            } else if (playStart_) transport_.position = *playStart_;
            playStart_.reset(); transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); autoRegionQueue_ = false; syncRegion(); break;
        }
    case CommandKind::next: move(1); break;
    case CommandKind::previous: move(-1); break;
    case CommandKind::select: select(c.target); break;
    case CommandKind::queue:
        if (std::none_of(project_.songs.begin(), project_.songs.end(), [&](const auto& s) { return s.id == c.target; })) throw std::invalid_argument("Unknown queued song");
        transport_.queue.songId = c.target; break;
    case CommandKind::editSeek:
        if (currentSong()) {
            transport_.editPosition = std::clamp(c.value, 0.0, currentSong()->duration);
            if (!transport_.playing) {
                clearIgnoreNext();
                transport_.paused = false; resumeSub_ = false;
                transport_.position = transport_.editPosition;
                transport_.playbackStartRegionId = playbackEntryRegion(*currentSong(), transport_.position);
                transport_.regionId.reset(); transport_.playlistEntryId.reset(); transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); autoRegionQueue_ = false; syncRegion();
            }
        }
        break;
    case CommandKind::seek: clearIgnoreNext(); if (currentSong()) { transport_.position = std::clamp(c.value, 0.0, currentSong()->duration); transport_.editPosition = transport_.position; transport_.playbackStartRegionId = playbackEntryRegion(*currentSong(), transport_.position); transport_.regionId.reset(); transport_.playlistEntryId.reset(); transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); autoRegionQueue_ = false; syncRegion(); refreshMultiLoop(); } break;
    case CommandKind::loopStart:
        if (!std::isfinite(c.value) || c.value < 0) throw std::invalid_argument("Invalid loop start");
        transport_.loop.start = c.value; break;
    case CommandKind::loopEnd:
        if (!std::isfinite(c.value) || c.value < 0) throw std::invalid_argument("Invalid loop end");
        transport_.loop.end = c.value; break;
    case CommandKind::escape: {
        // One cancellation per key press: section jump, loop, then song queue
        // together with Auto. Lower-priority actions stay armed until their turn.
        if (transport_.queuedSectionMarkerId) {
            cancelQueuedSection();
            break;
        }
        if (transport_.loop.enabled) {
            transport_.loop.enabled = false;
            if (transport_.multiLoop && transport_.multiLoop->gates) {
                auto& loop = *transport_.multiLoop;
                loop.released = true;
                loop.releasePosition = transport_.position;
                loop.amount = 1;
            }
            transport_.loop.start.reset(); transport_.loop.end.reset();
            break;
        }
        transport_.loop.start.reset(); transport_.loop.end.reset();
        if (project_.regionSetlist) project_.regionSetlist->autoAdvance = false;
        autoRegionQueue_ = false;
        transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset();
        transport_.queue.songId.reset();
        automaticSubplayQueue_.reset();
        break;
    }
    case CommandKind::toggleLoop:
        if (!transport_.loop.enabled) {
            if (transport_.multiLoop && transport_.multiLoop->gates) {
                transport_.loop.start = transport_.multiLoop->start;
                transport_.loop.end = transport_.multiLoop->end;
            }
            if (!transport_.loop.start || !transport_.loop.end || *transport_.loop.end <= *transport_.loop.start) {
                transport_.loop.start.reset(); transport_.loop.end.reset();
                if (const auto* song = currentSong()) {
                    const double cursor = transport_.playing ? transport_.position : transport_.editPosition;
                    for (const auto& part : song->parts) if (part.startTime <= cursor && cursor < part.endTime) {
                        if (!transport_.loop.start || part.startTime > *transport_.loop.start) transport_.loop.start = part.startTime;
                        if (!transport_.loop.end || part.endTime < *transport_.loop.end) transport_.loop.end = part.endTime;
                    }
                    if (transport_.loop.start && song->markers) for (const auto& marker : *song->markers)
                        if (marker.section.value_or(false) && !marker.tempoBPM && marker.position > cursor && marker.position < *transport_.loop.end) transport_.loop.end = marker.position;
                }
            }
            if (!transport_.loop.start || !transport_.loop.end || *transport_.loop.end <= *transport_.loop.start) break;
        }
        transport_.loop.enabled = !transport_.loop.enabled;
        if (!transport_.loop.enabled) { transport_.loop.start.reset(); transport_.loop.end.reset(); }
        if (transport_.multiLoop && transport_.multiLoop->gates) {
            auto& loop = *transport_.multiLoop;
            loop.released = !transport_.loop.enabled;
            loop.releasePosition = transport_.position;
            loop.amount = 1;
        }
        break;
    default:
        if (c.target.empty() && c.kind == CommandKind::pan) { project_.masterPan = std::clamp(c.value, -1.0, 1.0); return; }
        if (c.target.empty() && c.kind == CommandKind::volume) { project_.masterVolume = std::clamp(c.value, 0.0, std::pow(10.0, 12.0 / 20.0)); return; }
        if (c.target.empty() && c.kind == CommandKind::mute) { project_.masterMute = !project_.masterMute; return; }
        if (c.target.empty() && c.kind == CommandKind::phase) { return; }
        if (c.target.empty() && c.kind == CommandKind::masterMono) { project_.masterMono = !project_.masterMono; return; }
        if (c.target.empty() && c.kind == CommandKind::solo) { project_.masterSolo = !project_.masterSolo; return; }
        for (auto& song : project_.songs) for (auto& track : song.tracks) if (track.id == c.target) {
            if (!fixedTrackName(track.role).empty() && track.role.id != "video" && track.role.id != "generatedClick" && !(track.role.id == "timecode" && (c.kind == CommandKind::mute || c.kind == CommandKind::volume || c.kind == CommandKind::phase))) throw std::invalid_argument("This control is unavailable on a special track");
            if (c.kind == CommandKind::volume) track.volume = std::clamp(c.value, 0.0, std::pow(10.0, 12.0 / 20.0));
            if (c.kind == CommandKind::pan) track.pan = std::clamp(c.value, -1.0, 1.0);
            if (c.kind == CommandKind::phase) track.phaseInverted = !track.phaseInverted.value_or(false);
            if (c.kind == CommandKind::mute) track.mute = !track.mute;
            if (c.kind == CommandKind::solo) track.solo = !track.solo;
            if (track.stereoLinkPartner && (c.kind == CommandKind::volume || c.kind == CommandKind::pan)) {
                for (auto& linked : song.tracks) if (linked.id == *track.stereoLinkPartner && linked.stereoLinkPartner == track.id) {
                    if (c.kind == CommandKind::volume) linked.volume = track.volume;
                    else linked.pan = -track.pan;
                }
            }
            return;
        }
        throw std::invalid_argument("Unknown track");
    }
}
// Region IDs are stable virtual INICIO targets; no timeline marker is added.
std::optional<TimelineMarker> Engine::sectionDestination(const ID& id) const {
    const auto* song = currentSong(); if (!song) return std::nullopt;
    for (const auto& part : song->parts) if (part.id == id) {
        TimelineMarker start{part.id, "INÍCIO", part.startTime, 0x409cff};
        start.section = true;
        return start;
    }
    if (song->markers) for (const auto& marker : *song->markers)
        if (marker.id == id && marker.section.value_or(false) && !marker.tempoBPM) return marker;
    return std::nullopt;
}
const Part* Engine::sectionRegion(double position) const {
    const auto* song = currentSong(); if (!song) return nullptr;
    const Part* result = nullptr;
    for (const auto& part : song->parts) if (position >= part.startTime && position < part.endTime) {
        if (!result || (part.parentRegionID && !result->parentRegionID) ||
            (part.parentRegionID.has_value() == result->parentRegionID.has_value() && part.endTime-part.startTime < result->endTime-result->startTime)) result = &part;
    }
    return result;
}
const Part* Engine::sectionPlaybackRegion() const {
    if (transport_.ignoreNextEnd) if (const auto* owner = region(transport_.ignoreNextRegionId)) return owner;
    return sectionRegion(transport_.position);
}
std::optional<double> Engine::nextSectionTrigger() const {
    const auto* song = currentSong(); const auto* part = sectionPlaybackRegion();
    if (!transport_.playing || !song || !part) return {};
    double trigger = transport_.ignoreNextEnd.value_or(part->endTime);
    if (trigger <= transport_.position + 1e-9) return {};
    if (song->markers) for (const auto& marker : *song->markers) {
        if (!marker.section.value_or(false) || marker.tempoBPM) continue;
        if (transport_.ignoreNextAfter && marker.position >= *transport_.ignoreNextAfter && marker.regionOwnerID != part->id) continue;
        if (marker.position > transport_.position + 1e-9 && marker.position <= part->endTime && marker.position < trigger) trigger = marker.position;
    }
    return trigger;
}
void Engine::normalizeLiveMarks() {
    if (!project_.regionSetlist) { liveElapsedByRegion_.clear(); return; }
    auto& state = *project_.regionSetlist;
    if (!state.liveEnabled.value_or(false)) {
        // Saved history is portable independently of the Live switch. UI reset
        // actions explicitly pass an empty history; stopping collection only
        // discards runtime partial counters.
        liveElapsedByRegion_.clear(); return;
    }
    std::set<ID> valid, marked;
    std::map<ID, std::vector<ID>> children;
    for (const auto& song : project_.songs) for (const auto& part : song.parts) {
        valid.insert(part.id);
        if (part.parentRegionID) children[*part.parentRegionID].push_back(part.id);
    }
    if (state.playedLiveRegionIDs) for (const auto& id : *state.playedLiveRegionIDs)
        if (valid.count(id) && !children.count(id)) marked.insert(id);
    for (const auto& group : children)
        if (std::all_of(group.second.begin(), group.second.end(), [&](const auto& id) { return marked.count(id); })) marked.insert(group.first);
    for (auto it = liveElapsedByRegion_.begin(); it != liveElapsedByRegion_.end(); )
        if (!valid.count(it->first) || children.count(it->first) || marked.count(it->first)) it = liveElapsedByRegion_.erase(it); else ++it;
    state.playedLiveRegionIDs = std::vector<ID>(marked.begin(), marked.end());
}
void Engine::recordLivePlayback(const TransportState& before, double elapsed) {
    if (!project_.regionSetlist || !project_.regionSetlist->liveEnabled.value_or(false) ||
        !std::isfinite(elapsed) || elapsed <= 0 || (!before.playing && !before.subPlay.playing)) return;
    auto& state = *project_.regionSetlist;
    std::set<ID> marked;
    if (state.playedLiveRegionIDs) marked.insert(state.playedLiveRegionIDs->begin(),state.playedLiveRegionIDs->end());
    std::map<ID,std::vector<ID>> children;
    for (const auto& song : project_.songs) for (const auto& part : song.parts)
        if (part.parentRegionID) children[*part.parentRegionID].push_back(part.id);
    const auto songFor = [&](const std::optional<ID>& id) -> const Song* {
        for (const auto& song : project_.songs) if (id == song.id) return &song;
        return nullptr;
    };
    const auto* previousSong = songFor(before.songId);
    const auto* nextSong = songFor(transport_.songId);
    std::map<ID,double> contributions;
    const auto contribute = [&](const ID& id, double duration) {
        if (!marked.count(id) && duration > 0) contributions[id] = std::max(contributions[id],std::min(duration,elapsed));
    };
    const auto containing = [&](const Song* song, double at) {
        std::vector<const Part*> result;
        if (song) for (const auto& part : song->parts)
            if (!children.count(part.id) && part.startTime <= at && at < part.endTime) result.push_back(&part);
        return result;
    };
    const auto stream = [&](bool wasPlaying, bool playing, double start, double end, bool promoted) {
        if (!wasPlaying || !previousSong || !std::isfinite(start) || !std::isfinite(end)) return;
        if (before.songId == transport_.songId && std::abs(end-start-elapsed) < 1e-6) {
            for (const auto& part : previousSong->parts) if (!children.count(part.id))
                contribute(part.id,std::min(end,part.endTime)-std::max(start,part.startTime));
            return;
        }
        const auto prior = containing(previousSong,start), next = containing(nextSong,end);
        double oldTail = elapsed;
        for (const auto* part : prior) {
            const bool continues = (playing || promoted) && std::any_of(next.begin(),next.end(),[&](const auto* p) { return p->id == part->id; });
            contribute(part->id,continues ? elapsed : std::min(elapsed,std::max(0.0,part->endTime-start)));
            oldTail = std::min(oldTail,std::max(0.0,part->endTime-start));
        }
        if (prior.empty()) oldTail = 0;
        if (playing) for (const auto* part : next)
            if (std::none_of(prior.begin(),prior.end(),[&](const auto* p) { return p->id == part->id; }))
                contribute(part->id,std::min(elapsed-oldTail,std::max(0.0,end-part->startTime)));
    };
    stream(before.playing,transport_.playing,before.position,transport_.position,false);
    const bool promoted = before.subPlay.playing && !transport_.subPlay.playing && transport_.playing && before.subPlayPromotion != transport_.subPlayPromotion;
    stream(before.subPlay.playing,transport_.subPlay.playing,before.subPlay.position,
        promoted ? transport_.position : transport_.subPlay.position,promoted);
    bool changed = false;
    for (const auto& item : contributions) {
        auto counter = std::find_if(liveElapsedByRegion_.begin(),liveElapsedByRegion_.end(),[&](const auto& value) { return value.first == item.first; });
        if (counter == liveElapsedByRegion_.end()) {
            liveElapsedByRegion_.emplace_back(item.first,item.second); counter = liveElapsedByRegion_.end()-1;
        } else counter->second += item.second;
        if (counter->second + 1e-9 >= 10) { marked.insert(item.first); liveElapsedByRegion_.erase(counter); changed = true; }
    }
    if (!changed) return;
    for (const auto& group : children)
        if (std::all_of(group.second.begin(),group.second.end(),[&](const auto& id) { return marked.count(id); })) marked.insert(group.first);
    state.playedLiveRegionIDs = std::vector<ID>(marked.begin(),marked.end());
}
void Engine::advance(double elapsed) {
    if (!std::isfinite(elapsed) || elapsed <= 0) return;
    if (!project_.regionSetlist || !project_.regionSetlist->liveEnabled.value_or(false)) { advanceWithoutLiveTracking(elapsed); return; }
    const auto before = transport_;
    advanceWithoutLiveTracking(elapsed);
    recordLivePlayback(before,elapsed);
}
void Engine::advanceWithoutLiveTracking(double elapsed) {
    projectSync::Internal syncTick;
    if (!std::isfinite(elapsed) || elapsed <= 0) return;
    // Consume a queued jump at its musical boundary, including the remainder of
    // a long tick. Sub Play advances once for each consumed interval, independently.
    for (int pass = 0; pass < 3 && transport_.playing && transport_.queuedSectionMarkerId; ++pass) {
        refreshMultiLoop();
        const auto target = sectionDestination(*transport_.queuedSectionMarkerId);
        const auto trigger = nextSectionTrigger();
        if (!target) { transport_.queuedSectionMarkerId.reset(); break; }
        const auto end = transport_.loop.enabled ? transport_.loop.end : std::nullopt;
        if (end && *end > transport_.position && (!trigger || *end < *trigger)) {
            const double untilWrap = *end - transport_.position;
            if (elapsed < untilWrap) break;
            advanceContinuous(untilWrap); elapsed -= untilWrap;
            if (elapsed <= 0) return;
            continue;
        }
        if (!trigger) break;
        const double untilTrigger = *trigger - transport_.position;
        if (elapsed < untilTrigger) break;
        // Copy before advancing: an automatic region transition must not leave
        // a pointer into a replaced arrangement.
        const auto destination = *target;
        advanceContinuous(untilTrigger, &destination);
        elapsed -= untilTrigger;
        if (elapsed <= 0) return;
        break;
    }
    const auto* previous = sectionPlaybackRegion();
    const auto previousID = previous ? std::optional<ID>(previous->id) : std::nullopt;
    advanceContinuous(elapsed);
    const auto* next = sectionPlaybackRegion();
    if (!transport_.playing || !next || next->id != previousID) transport_.queuedSectionMarkerId.reset();
}
// Next measures its lead from the queued song's onset, not from the outgoing
// song's tempo. Integrate tempo/meter changes inside that initial passage.
static double automaticSubplayInitDuration(const Song& song, const Part& queued, std::optional<int> barsOverride = std::nullopt) {
    const auto bars=barsOverride ? barsOverride : queued.subplayInitBars;
    if(!bars) return std::clamp(queued.subplayInitSeconds.value_or(1),1.0,5.0);
    double cursor=queued.startTime, remaining=std::clamp(*bars,1,5);
    while(remaining>0) {
        const TimelineMarker* active=nullptr;
        double next=std::numeric_limits<double>::infinity();
        if(song.markers) for(const auto& marker:*song.markers) if(marker.tempoBPM) {
            if(marker.position>cursor) next=std::min(next,marker.position);
            else if(!active || marker.position>active->position ||
                    (marker.position==active->position && marker.id>active->id)) active=&marker;
        }
        const double bpm=active?*active->tempoBPM:song.bpm;
        const int beats=active?active->tempoBeats.value_or(4):song.beatsPerBar;
        const int unit=active?active->tempoUnit.value_or(4):song.beatUnit;
        const double seconds=60.0/bpm*beats*4.0/unit;
        const double available=(next-cursor)/seconds;
        if(remaining<=available) return cursor-queued.startTime+remaining*seconds;
        remaining-=available;cursor=next;
    }
    return cursor-queued.startTime;
}
void Engine::advanceContinuous(double elapsed, const TimelineMarker* sectionDestination) {
    if (!std::isfinite(elapsed) || elapsed <= 0) return;
    refreshMultiLoop();
    double subElapsed = elapsed;
    if (automaticSubplayQueue_ != transport_.queuedRegionId) automaticSubplayQueue_.reset();
    if (!sectionDestination && transport_.playing && !transport_.loop.enabled && !(transport_.multiLoop && !transport_.multiLoop->released) && !transport_.subPlay.playing && project_.regionSetlist &&
        project_.regionSetlist->automaticSubplay.value_or(false) && !project_.regionSetlist->prepareWithoutPlayback.value_or(false)) {
        const auto* active = playbackBounds(region(transport_.regionId));
        const auto* queued = region(transport_.queuedRegionId);
        if (active && queued && automaticSubplayQueue_ != transport_.queuedRegionId) {
            const double end = transport_.ignoreNextEnd.value_or(active->endTime);
            const double lead = std::clamp(project_.regionSetlist->automaticSubplaySeconds.value_or(1), 1.0, 5.0);
            const double trigger = project_.regionSetlist->automaticSubplayNext.value_or(false) && currentSong()
                ? end - automaticSubplayInitDuration(*currentSong(), *queued)
                : project_.regionSetlist->automaticSubplayBars && currentSong()
                    ? end - automaticSubplayInitDuration(*currentSong(), *queued, project_.regionSetlist->automaticSubplayBars)
                    : end - lead;
            if (transport_.position < end && transport_.position + elapsed >= trigger) {
                transport_.subPlay.position = queued->startTime; manualSubCursor_ = false;
                execute({CommandKind::subPlay});
                automaticSubplayQueue_ = queued->id;
                automaticSubplayActive_ = true;
                subElapsed = std::max(0.0, elapsed - std::max(0.0, trigger - transport_.position));
            }
        }
    }
    if (transport_.subPlay.playing && currentSong()) {
        transport_.subPlay.position += subElapsed;
    }
    if (!transport_.playing) return;
    if (sectionDestination) {
        const double destination = sectionDestination->position;
        transport_.queuedSectionMarkerId.reset();
        resetMultiLoop(); clearIgnoreNext();
        if (const auto* queued = region(transport_.queuedRegionId); queued && destination >= queued->startTime && destination < queued->endTime) {
            transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); autoRegionQueue_ = false;
            execute({CommandKind::subStop});
        }
        transport_.position = destination; transport_.editPosition = destination;
        transport_.playbackStartRegionId = playbackEntryRegion(*currentSong(), destination);
        transport_.regionId.reset(); ++transport_.sectionJumpSerial;
        syncRegion(); return;
    }
    const auto* song = currentSong(); if (!song) return;
    syncRegion();
    if (!finishCurrent_ && transport_.loop.enabled && transport_.loop.start && transport_.loop.end &&
        *transport_.loop.end > *transport_.loop.start && !(transport_.multiLoop && !transport_.multiLoop->released)) {
        transport_.position += elapsed;
        if (transport_.position >= *transport_.loop.end) {
            ++transport_.sectionJumpSerial;
            transport_.position = *transport_.loop.start + std::fmod(transport_.position - *transport_.loop.start, *transport_.loop.end - *transport_.loop.start);
        }
        syncRegion(); return;
    }
    if (!finishCurrent_ && advanceMultiLoop(elapsed)) return;
    // Consume region boundaries in the engine, independent of UI refresh rate.
    while (transport_.playing) {
        const auto* active = playbackBounds(region(transport_.regionId));
        const bool ignoring = transport_.ignoreNextEnd.has_value();
        const double end = ignoring ? *transport_.ignoreNextEnd : active ? active->endTime : song->duration;
        if ((!active && !ignoring) || transport_.position + elapsed < end) break;
        const auto* queued = region(transport_.queuedRegionId);
        if (transport_.subPlay.playing) {
            // A boundary stops the outgoing head, never a song already started
            // by the user (or automatic pre-roll). Promote before STOP/queue
            // policy, even without a queue or after a manual secondary seek.
            // The secondary head already consumed this tick above.
            const auto* bounds = playbackBounds(queued);
            const bool inQueued = queued && bounds && transport_.subPlay.position >= queued->startTime &&
                transport_.subPlay.position < bounds->endTime;
            // A large advance can cross the entire automatically pre-rolled
            // region. Let the normal boundary loop consume that case, so block
            // end/STOP policies still apply to the incoming song's own end.
            if (!automaticSubplayActive_ || inQueued) {
                promoteSubPlay(inQueued ? std::optional<ID>(queued->id) : std::nullopt);
                return;
            }
        }
        // STOP applies only without a valid incoming queue. Both manual and
        // automatic queues own the transition; prepare-only is handled below.
        if (!ignoring && !queued && project_.regionSetlist && project_.regionSetlist->stopAtRegionEnd.value_or(false)) {
            transport_.position = active->endTime; transport_.playing = false; transport_.paused = false;
            execute({CommandKind::subStop}); return;
        }
        if (finishCurrent_) { transport_.position = active->endTime; transport_.playing = false; transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); execute({CommandKind::subStop}); return; }
        if (queued) {
            elapsed -= std::max(0.0, end - transport_.position);
            clearIgnoreNext();
            const auto id = queued->id; const double start = queued->startTime;
            transport_.position = start; transport_.editPosition = start; transport_.regionId = id;
            transport_.playlistEntryId = transport_.queuedPlaylistEntryId;
            playStart_ = start;
            transport_.playbackStartRegionId = playbackEntryRegion(*song, start);
            transport_.queuedRegionId.reset(); transport_.queuedPlaylistEntryId.reset(); autoRegionQueue_ = false;
            if (project_.regionSetlist && project_.regionSetlist->prepareWithoutPlayback.value_or(false)) {
                transport_.playing = false; transport_.paused = false; playStart_.reset();
                execute({CommandKind::subStop}); return;
            }
            // Promote the pre-scheduled audio destination exactly as a section
            // seek or loop wrap does; the transport never enters a stopped state.
            ++transport_.sectionJumpSerial;
            autoQueueRegion();
            continue;
        }
        if (ignoring) {
            transport_.position = end; transport_.playing = false; transport_.paused = false;
            transport_.regionId = transport_.ignoreNextRegionId;
            clearIgnoreNext(); execute({CommandKind::subStop}); return;
        }
        if (project_.regionSetlist && project_.regionSetlist->autoAdvance) {
            transport_.position = active->endTime; transport_.playing = false; execute({CommandKind::subStop}); return;
        }
        break;
    }
    transport_.position += elapsed;
    refreshMultiLoop();
    syncRegion();
    if (transport_.position < song->duration) return;
    if (transport_.subPlay.playing) { promoteSubPlay(); return; }
    if (finishCurrent_) { transport_.position = song->duration; transport_.playing = false; execute({CommandKind::subStop}); return; }
    // Consume elapsed time across queued songs, without a UI-frame dependency.
    double remainder = transport_.position - song->duration;
    auto next = nextSongId();
    if (!next) { transport_.position = song->duration; transport_.playing = false; execute({CommandKind::subStop}); return; }
    select(*next);
    advanceWithoutLiveTracking(remainder);
}
}

namespace jaras {
void Engine::setTrackRouting(const std::vector<std::pair<ID,TrackRouting>>& routes) {
    projectSync::requireWritable();
    std::vector<std::pair<Track*, std::optional<TrackRouting>>> previous;
    try {
        for (const auto& value : routes) {
            Track* found = nullptr;
            for (auto& song : project_.songs) for (auto& track : song.tracks) if (track.id == value.first) found = &track;
            if (!found) throw std::invalid_argument("Unknown track");
            previous.push_back({found,found->routing});found->routing=value.second;
        }
        for (const auto& song : project_.songs) validateRouting(song);
    } catch (...) {for (auto it=previous.rbegin();it!=previous.rend();++it)it->first->routing=it->second;throw;}
}
}

namespace jaras {
static bool multiLoopsBypassed(const Song& song,const Part& part) {
    if(part.totalLoop.value_or(false)) return true;
    if(part.parentRegionID) for(const auto& parent:song.parts) if(parent.id==*part.parentRegionID && parent.totalLoop.value_or(false)) return true;
    return false;
}
void Engine::resetMultiLoop() {
    if (transport_.multiLoop && transport_.multiLoop->gates) transport_.loop = {};
    transport_.multiLoop.reset();
}
void Engine::refreshMultiLoop() {
    if (transport_.multiLoopsBypassed) { resetMultiLoop(); return; }
    const auto* song = currentSong();
    if(transport_.loop.enabled && !transport_.multiLoop) {
        const bool total=song && (transport_.playing || transport_.paused) && std::any_of(song->parts.begin(),song->parts.end(),[&](const auto& part){
            return part.totalLoop.value_or(false) && transport_.position>=part.startTime && transport_.position<part.endTime;
        });
        if(!total) return;
    }
    if (!song || (!transport_.playing && !transport_.paused)) { resetMultiLoop(); return; }
    const double position = transport_.position;
    const MultiLoop* candidate = nullptr;
    double begin = 0, end = 0;
    MultiLoop total;
    const Part* whole=nullptr;
    for(const auto& part:song->parts) if(part.totalLoop.value_or(false) && position>=part.startTime && position<part.endTime) {
        if(!whole || (whole->parentRegionID && !part.parentRegionID) || (whole->parentRegionID==part.parentRegionID && part.startTime<whole->startTime)) whole=&part;
    }
    if(whole) {
        total.id=whole->id;total.name="Total Loop";total.fadeSeconds=1;
        candidate=&total;begin=whole->startTime;end=whole->endTime;
    }
    if (!candidate && transport_.loop.enabled && !transport_.multiLoop) return;
    if (!whole && song->markers) for (const auto& part : song->parts) for (const auto& loop : part.multiLoops) {
        if(!loop.enabled.value_or(true) || multiLoopsBypassed(*song,part)) continue;
        const TimelineMarker *first = nullptr, *last = nullptr;
        for (const auto& marker : *song->markers) {
            if (marker.tempoBPM || !marker.section.value_or(false)) continue;
            if (marker.id == loop.marker1) first = &marker;
            if (marker.id == loop.marker2) last = &marker;
        }
        if (transport_.ignoreNextEnd && first && first->position >= *transport_.ignoreNextEnd) continue;
        if (!first || !last || first->position < part.startTime || last->position > part.endTime || first->position >= last->position) continue;
        if (position < std::max(0.0, first->position - loop.fadeSeconds) || position >= last->position) continue;
        // Retain the current loop when intervals overlap, otherwise first in time.
        if (!candidate || (transport_.multiLoop && transport_.multiLoop->id == loop.id) || (!(transport_.multiLoop && candidate->id == transport_.multiLoop->id) && first->position < begin)) {
            candidate = &loop; begin = first->position; end = last->position;
        }
        if (transport_.multiLoop && candidate->id == transport_.multiLoop->id) break;
    }
    if (!candidate) { resetMultiLoop(); return; }
    if (!transport_.multiLoop || transport_.multiLoop->id != candidate->id) {
        resetMultiLoop(); MultiLoopPlayback state; state.id = candidate->id; state.start = begin; state.end = end; state.config = *candidate;
        transport_.multiLoop = std::move(state);
    }
    auto& state = *transport_.multiLoop;
    state.start = begin; state.end = end; state.config = *candidate;
    // The saved presets remain editable while M/S is bypassed. Auto Fader is
    // independent of the M/S switch, matching VS Hook's four loop slots.
    if (!state.config.mixerEnabled.value_or(true)) {
        for (auto& track : state.config.tracks) { track.mute = false; track.solo = false; }
    }
    if (state.released) state.amount = std::clamp((end - position) / std::max(0.000001, end - state.releasePosition), 0.0, 1.0);
    else {
        state.amount = std::clamp((position - begin + candidate->fadeSeconds) / candidate->fadeSeconds, 0.0, 1.0);
        if (position >= begin) { state.gates = true; transport_.loop.enabled = true; transport_.loop.start = begin; transport_.loop.end = end; }
    }
}
bool Engine::advanceMultiLoop(double elapsed) {
    if (transport_.multiLoopsBypassed) return false;
    refreshMultiLoop();
    const auto* song = currentSong();
    if (!song || !transport_.playing) return false;
    // Detect crossing a start even if a busy UI delivered a long tick.
    if (!transport_.multiLoop) {
        double boundary = std::numeric_limits<double>::infinity();
        for(const auto& part:song->parts) if(part.totalLoop.value_or(false) && part.startTime>=transport_.position && part.startTime<=transport_.position+elapsed) {
            if(!transport_.ignoreNextEnd || part.startTime<*transport_.ignoreNextEnd) boundary=std::min(boundary,part.startTime);
        }
        if(song->markers) for (const auto& part : song->parts) for (const auto& loop : part.multiLoops) {
            if(!loop.enabled.value_or(true) || multiLoopsBypassed(*song,part)) continue;
            const TimelineMarker *a = nullptr, *b = nullptr;
            for (const auto& marker : *song->markers) if (!marker.tempoBPM && marker.section.value_or(false)) {
                if (marker.id == loop.marker1) a = &marker;
                if (marker.id == loop.marker2) b = &marker;
            }
            if (transport_.ignoreNextEnd && a && a->position >= *transport_.ignoreNextEnd) continue;
            if (a && b && a->position >= part.startTime && b->position <= part.endTime && a->position < b->position &&
                a->position >= transport_.position && a->position <= transport_.position + elapsed) boundary = std::min(boundary, a->position);
        }
        if (boundary <= transport_.position + elapsed) {
            elapsed -= boundary - transport_.position; transport_.position = boundary; refreshMultiLoop();
        }
    }
    if (!transport_.multiLoop || transport_.multiLoop->released) return false;
    auto& state = *transport_.multiLoop;
    const double next = transport_.position + elapsed;
    if (next < state.start) return false;
    state.gates = true; state.amount = 1; transport_.loop.enabled = true;
    transport_.loop.start = state.start; transport_.loop.end = state.end;
    if (next >= state.end) ++transport_.sectionJumpSerial;
    transport_.position = next >= state.end ? state.start + std::fmod(next - state.start, state.end - state.start) : next;
    syncRegion();
    return true;
}
}
namespace jaras {
bool Engine::applyProjectSync(projectSync::Frame frame, double elapsed, bool first, bool *mixerChanged) {
    if (!project_.projectSyncID || !projectSync::sameID(*project_.projectSyncID, frame.project))
        throw std::invalid_argument("Project Sync: open the matching saved project on PC B.");
    if (!std::isfinite(elapsed) || elapsed < 0 || elapsed > 1) throw std::invalid_argument("Stale Project Sync frame");
    const auto &t = frame.transport;
    auto validTime=[](double value) { return std::isfinite(value) && value >= 0 && value <= 60480000; };
    if (!validTime(t.position) || !validTime(t.subPlay.position) || !validTime(t.editPosition) ||
        (t.loop.start && !validTime(*t.loop.start)) || (t.loop.end && !validTime(*t.loop.end)) ||
        (t.loop.start && t.loop.end && *t.loop.end <= *t.loop.start)) throw std::invalid_argument("Invalid Project Sync position");
    const Song *song=nullptr;
    for(const auto &s:project_.songs) if(t.songId==s.id) song=&s;
    if(t.songId && !song) throw std::invalid_argument("Project Sync: project contents do not match.");
    const auto regionExists=[&](const std::optional<ID> &id) {
        return !id || (song && std::any_of(song->parts.begin(),song->parts.end(),[&](const auto &p){ return p.id==*id; }));
    };
    if(!regionExists(t.regionId) || !regionExists(t.queuedRegionId) || !regionExists(t.playbackStartRegionId) ||
       !regionExists(t.subPlaybackStartRegionId) || !regionExists(t.ignoreNextRegionId))
        throw std::invalid_argument("Project Sync: project regions do not match.");
    if(t.queuedSectionMarkerId && (!song || !song->markers || !std::any_of(song->markers->begin(),song->markers->end(),[&](const auto &m){return m.id==*t.queuedSectionMarkerId;})))
        throw std::invalid_argument("Project Sync: project markers do not match.");
    if(frame.setlist && frame.setlist->selectedId && (!project_.regionSetlist || !std::any_of(project_.regionSetlist->playlists.begin(),project_.regionSetlist->playlists.end(),[&](const auto &p){return p.id==*frame.setlist->selectedId;})))
        throw std::invalid_argument("Project Sync: project playlists do not match.");
    const RegionPlaylist* syncedPlaylist = nullptr;
    if (frame.setlist && project_.regionSetlist && song)
        for (const auto& list : project_.regionSetlist->playlists)
            if (list.id == frame.setlist->selectedId && list.songId == song->id) syncedPlaylist = &list;
    const auto entryExists = [&](const std::optional<ID>& entry, const std::optional<ID>& physical) {
        if (!entry) return true;
        if (!syncedPlaylist || !physical || !syncedPlaylist->containsEntry(*entry)) return false;
        const auto source = syncedPlaylist->resolvedRegionId(*entry);
        return source == *physical || (song && std::any_of(song->parts.begin(),song->parts.end(),[&](const auto& part) {
            return part.id == *physical && part.parentRegionID == source;
        }));
    };
    if (!entryExists(t.playlistEntryId,t.regionId) || !entryExists(t.queuedPlaylistEntryId,t.queuedRegionId))
        throw std::invalid_argument("Project Sync: playlist occurrences do not match.");
    for(const auto &time:{frame.playStart,frame.subPlayStart,t.ignoreNextAfter,t.ignoreNextEnd})
        if(time && !validTime(*time))throw std::invalid_argument("Invalid Project Sync position");
    if(!regionExists(frame.automaticSubplayQueue) || (t.queue.songId && !std::any_of(project_.songs.begin(),project_.songs.end(),[&](const auto &s){return s.id==*t.queue.songId;})))
        throw std::invalid_argument("Project Sync: project queue does not match.");
    if(t.multiLoop) {
        const auto &m=*t.multiLoop;
        if(!song || !validTime(m.start) || !validTime(m.end) || m.end<=m.start || m.amount<0 || m.amount>1 || !validTime(m.releasePosition) ||
           !std::isfinite(m.config.fadeSeconds) || m.config.fadeSeconds<0 || m.config.fadeSeconds>60)
            throw std::invalid_argument("Invalid Project Sync loop");
        for(const auto &track:m.config.tracks) if(!std::isfinite(track.gain) || track.gain<0 || track.gain>64 ||
            (track.id!="master" && track.id!="00000000-0000-0000-0000-000000000000" && !std::any_of(song->tracks.begin(),song->tracks.end(),[&](const auto &t){return t.id==track.id;})))
            throw std::invalid_argument("Invalid Project Sync loop track");
    }
    if(frame.setlist) {
        const auto &s=*frame.setlist;
        if((s.automaticSubplaySeconds && (!std::isfinite(*s.automaticSubplaySeconds) || *s.automaticSubplaySeconds<1 || *s.automaticSubplaySeconds>5)) ||
           (s.automaticSubplayBars && (*s.automaticSubplayBars<1 || *s.automaticSubplayBars>5))) throw std::invalid_argument("Invalid Project Sync timing");
    }
    // Validate all mixer targets before changing any project or transport state.
    const auto validMixer=[](double volume,double pan) {
        return std::isfinite(volume) && volume>=0 && volume<=64 && std::isfinite(pan) && pan>=-1 && pan<=1;
    };
    if(!validMixer(frame.mixer.masterVolume,frame.mixer.masterPan) || frame.mixer.tracks.size()>2048)
        throw std::invalid_argument("Invalid Project Sync mixer");
    std::map<ID,Track*> tracks;
    for(auto &s:project_.songs) for(auto &track:s.tracks) tracks.emplace(track.id,&track);
    std::set<ID> seen;
    for(const auto &track:frame.mixer.tracks)
        if(!validMixer(track.volume,track.pan) || !tracks.count(track.id) || !seen.insert(track.id).second)
            throw std::invalid_argument("Project Sync: project tracks do not match.");
    bool mixerEdited=false;
    const auto assign=[&](auto &destination,const auto &value) {if(destination!=value){destination=value;mixerEdited=true;}};
    assign(project_.masterVolume,frame.mixer.masterVolume);assign(project_.masterPan,frame.mixer.masterPan);
    assign(project_.masterMute,frame.mixer.masterMute);assign(project_.masterSolo,frame.mixer.masterSolo);
    for(const auto &track:frame.mixer.tracks) {
        auto &target=*tracks.at(track.id);
        assign(target.volume,track.volume);assign(target.pan,track.pan);assign(target.mute,track.mute);assign(target.solo,track.solo);
    }
    if(mixerChanged) *mixerChanged=mixerEdited;
    const auto previous=transport_;
    const bool command=first || receivedSyncRevision_!=frame.revision || previous.songId!=t.songId ||
        previous.playing!=t.playing || previous.subPlay.playing!=t.subPlay.playing || previous.regionId!=t.regionId;
    if(frame.setlist) {
        auto next=*frame.setlist;
        if(project_.regionSetlist) { next.playlists=project_.regionSetlist->playlists; next.blocks=project_.regionSetlist->blocks; }
        project_.regionSetlist=std::move(next);
    }
    transport_=t; receivedSyncRevision_=frame.revision;
    resumeSub_=frame.resumeSub;manualSubCursor_=frame.manualSubCursor;
    autoRegionQueue_=frame.autoRegionQueue;automaticSubplayActive_=frame.automaticSubplayActive;
    playStart_=frame.playStart;subPlayStart_=frame.subPlayStart;automaticSubplayQueue_=frame.automaticSubplayQueue;
    // Compensate measured LAN transit time through the normal loop/queue rules.
    if(elapsed>0) advanceWithoutLiveTracking(elapsed);
    const bool discontinuity=command || std::abs(transport_.position-previous.position)>.04 ||
        (transport_.subPlay.playing && std::abs(transport_.subPlay.position-previous.subPlay.position)>.04);
    if(!discontinuity) {
        if(transport_.playing) transport_.position=previous.position;
        if(transport_.subPlay.playing) transport_.subPlay.position=previous.subPlay.position;
    }
    return discontinuity;
}
}
