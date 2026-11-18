#pragma once
#include "ProjectCodec.h"
#include "RegionPitch.h"
#include "../../Core/Songs/TempoPlaybackRate.hpp"
#include "../../Core/Tracks/AutomationTiming.hpp"
#include "../../Core/Transport/PlaybackScope.hpp"

namespace catlive::multitrackData {
inline const String prefix = ".jldata-";
inline bool isManifest(const File &file) { return file.getFileName().startsWithIgnoreCase(prefix); }
inline bool isFilename(const String &name) {
    return name.isNotEmpty() && name != "." && name != ".." && !name.containsAnyOf("/\\:");
}
inline bool isMedia(const jaras::AudioClip &clip) {
    return clip.audioFile && text(clip.audioFile->path).startsWith("Videos/") &&
        isFilename(text(clip.audioFile->path).substring(7));
}
struct RenderedStem {
    struct Item { double offset, duration, rate; std::optional<double> pitchSemitones; };
    String file;
    ID track;
    std::vector<Item> items;
};
struct Document {
    jaras::Project project;
    std::vector<RenderedStem> stems;
    StringArray lyricsFiles;
    bool tunerUnbaked = false;
    const jaras::Song& arrangement() const { return project.songs.front(); }
    const jaras::Part& region() const { return arrangement().parts.front(); }
};
inline var manifestJSON(const File &file) {
    if (file.isSymbolicLink() || file.getSize() <= 0 || file.getSize() > 32 * 1024 * 1024)
        throw std::runtime_error("Invalid Multitrack region data.");
    return JSON::parse(file);
}
inline Document decode(const var &raw) {
    if (num(raw, "version") != 1 || !get(raw, "renderedStems").isArray() || !get(raw, "lyricsFiles").isArray())
        throw std::runtime_error("Invalid Multitrack region data.");
    Document result;
    result.tunerUnbaked = (bool)get(raw, "tunerUnbaked");
    result.project = ProjectCodec::decode(get(raw, "project"));
    if (result.project.songs.size() != 1 || result.arrangement().parts.size() != 1)
        throw std::runtime_error("Invalid Multitrack arrangement.");
    for (const auto &track : result.arrangement().tracks) for (const auto &clip : track.clips)
        if (clip.audioFile ? !isMedia(clip) : !clip.text) throw std::runtime_error("Invalid Multitrack media path.");
    for (const auto &value : list(get(raw, "renderedStems"))) {
        RenderedStem stem{str(value, "file"), utf8(Uuid(str(value, "track")).toDashedString().toUpperCase()), {}};
        if (!isFilename(stem.file) ||
            std::none_of(result.arrangement().tracks.begin(), result.arrangement().tracks.end(),
                [&](const auto &track) { return track.id == stem.track; }))
            throw std::runtime_error("Invalid Multitrack stem.");
        for (const auto &item : list(get(value, "items"))) {
            RenderedStem::Item converted{num(item, "offset"), num(item, "duration"), num(item, "rate"), {}};
            if (!get(item, "pitchSemitones").isVoid()) converted.pitchSemitones = num(item, "pitchSemitones");
            if (!std::isfinite(converted.offset) || !std::isfinite(converted.duration) || converted.duration <= 0 ||
                !std::isfinite(converted.rate) || converted.rate <= 0 ||
                (converted.pitchSemitones && (!std::isfinite(*converted.pitchSemitones) || std::abs(*converted.pitchSemitones) > 12)))
                throw std::runtime_error("Invalid Multitrack item.");
            stem.items.push_back(converted);
        }
        result.stems.push_back(std::move(stem));
    }
    for (const auto &value : list(get(raw, "lyricsFiles"))) {
        if (!value.isString() || !isFilename(value.toString())) throw std::runtime_error("Invalid Multitrack lyrics file.");
        result.lyricsFiles.add(value.toString());
    }
    return result;
}
struct Drawer {
    struct Entry {
        String folder; double offset, cue; Document data;
        std::optional<ID> cueID;
        std::optional<std::string> cueName;
        std::optional<unsigned> cueColor;
    };
    String name;
    double duration;
    std::optional<unsigned> color;
    std::optional<bool> uppercaseName;
    std::optional<int> pitchSemitones;
    std::vector<Entry> entries;
    double leadingOffset() const {
        double first = 0;
        for (const auto &entry : entries) first = std::min(first, entry.offset - entry.data.region().startTime);
        return first;
    }
    double occupiedEnd() const {
        double end = duration;
        for (const auto &entry : entries)
            end = std::max(end, entry.offset - entry.data.region().startTime + entry.data.arrangement().duration);
        return end;
    }
};
inline Drawer decodeDrawer(const var &raw) {
    Drawer drawer{str(raw, "name"), num(raw, "duration"), {}, {}, {}, {}};
    if (!get(raw, "color").isVoid()) drawer.color = (unsigned)num(raw, "color");
    if (!get(raw, "uppercaseName").isVoid()) drawer.uppercaseName = (bool)get(raw, "uppercaseName");
    if (!get(raw, "pitchSemitones").isVoid()) drawer.pitchSemitones = (int)num(raw, "pitchSemitones");
    if (num(raw, "version") != 2 || !std::isfinite(drawer.duration) || drawer.duration <= 0 ||
        (drawer.pitchSemitones && std::abs(*drawer.pitchSemitones) > 12))
        throw std::runtime_error("Invalid Multitrack drawer data.");
    StringArray folders;
    for (const auto &value : list(get(raw, "entries"))) {
        Drawer::Entry entry{str(value, "folder"), num(value, "offset"), num(value, "cue"), decode(get(value, "data"))};
        if (const auto id = str(value, "cueID"); id.isNotEmpty()) entry.cueID = utf8(Uuid(id).toDashedString().toUpperCase());
        if (!get(value, "cueName").isVoid()) entry.cueName = utf8(str(value, "cueName"));
        if (!get(value, "cueColor").isVoid()) entry.cueColor = (unsigned)num(value, "cueColor");
        if (!isFilename(entry.folder) || folders.contains(entry.folder, true) || !std::isfinite(entry.offset) ||
            entry.offset < 0 || !std::isfinite(entry.cue) || entry.cue < 0 || entry.cue >= drawer.duration ||
            entry.offset + entry.data.region().endTime - entry.data.region().startTime > drawer.duration + 1e-6)
            throw std::runtime_error("Invalid song in Multitrack drawer.");
        folders.add(entry.folder);
        drawer.entries.push_back(std::move(entry));
    }
    if (drawer.entries.empty()) throw std::runtime_error("Empty Multitrack drawer.");
    return drawer;
}
inline var encode(const jaras::Song &source, const jaras::Part &region, std::vector<jaras::Track> tracks,
                  const std::vector<RenderedStem> &stems, const StringArray &lyricsFiles, bool fullItems) {
    const double origin = region.startTime;
    double first = origin;
    std::set<ID> trackIDs;
    for (const auto &track : tracks) {
        trackIDs.insert(track.id);
        for (const auto &clip : track.clips) first = std::min(first, clip.startTime);
    }
    double last = region.endTime;
    if (fullItems) for (const auto &stem : stems) for (const auto &item : stem.items) {
        first = std::min(first, origin + item.offset);
        last = std::max(last, origin + item.offset + item.duration);
    }
    const jaras::Part *drawer = nullptr;
    if (fullItems)
        for (const auto &part : source.parts) if (part.id == region.parentRegionID) { drawer = &part; break; }
    const jaras::Part *firstChild = nullptr;
    std::set<ID> siblingIDs;
    if (drawer) for (const auto &part : source.parts) if (part.parentRegionID == drawer->id) {
        siblingIDs.insert(part.id);
        if (!firstChild || jaras::playbackRegionStart(source, part) < jaras::playbackRegionStart(source, *firstChild))
            firstChild = &part;
    }
    std::vector<jaras::TimelineMarker> regionMarkers;
    if (source.markers) for (const auto &marker : *source.markers) {
        if (marker.sourceRegionID) continue;
        if (drawer) {
            if (marker.position < drawer->startTime || marker.position >= drawer->endTime) continue;
            if (marker.regionOwnerID && siblingIDs.count(*marker.regionOwnerID)) {
                if (marker.regionOwnerID != region.id) continue;
            } else {
                if (marker.regionOwnerID && marker.regionOwnerID != drawer->id) continue;
                const auto owner = jaras::dominantUnifiedOwner(source, *drawer, marker.position, marker.position + 1e-6, {});
                if (owner ? owner != region.id : !firstChild || firstChild->id != region.id) continue;
            }
        } else if (marker.position < origin || marker.position >= region.endTime ||
            (marker.regionOwnerID && marker.regionOwnerID != region.id && marker.regionOwnerID != region.parentRegionID)) continue;
        regionMarkers.push_back(marker);
        first = std::min(first, marker.position); last = std::max(last, marker.position);
    }
    auto part = region;
    part.startTime -= first; part.endTime -= first;
    part.parentRegionID.reset();
    part.multiLoops.clear();
    part.pitchTrackIDs.reset(); part.pitchGroupIDs.reset();
    jaras::Song song;
    song.id = uuid(); song.name = region.name; song.duration = std::max(.01, last - first);
    song.bpm = source.bpm; song.beatsPerBar = source.beatsPerBar; song.beatUnit = source.beatUnit;
    song.timeSettings = source.timeSettings; song.parts.push_back(part);
    song.markers = std::move(regionMarkers);
    if (std::none_of(song.markers->begin(), song.markers->end(),
        [&](const auto &marker) { return marker.tempoBPM && std::abs(marker.position - origin) < 1e-7; })) {
        jaras::TimelineMarker marker;
        marker.id = uuid(); marker.name = "TEMPO"; marker.position = origin; marker.color = 0x999999;
        const auto *active = jaras::tempoPlayback::active(source, origin);
        marker.tempoBPM = active ? *active->tempoBPM : source.bpm;
        marker.tempoBeats = active && active->tempoBeats ? *active->tempoBeats : source.beatsPerBar;
        marker.tempoUnit = active && active->tempoUnit ? *active->tempoUnit : source.beatUnit;
        marker.tempoTimebase = "global";
        marker.tempoPlaybackRate = active ? jaras::tempoPlayback::rate(source, *active) : 1.;
        song.markers->push_back(marker);
    }
    std::set<ID> markerIDs;
    for (const auto &marker : *song.markers) markerIDs.insert(marker.id);
    for (auto &marker : *song.markers) {
        if (marker.tempoBPM) marker.tempoPlaybackRate = jaras::tempoPlayback::rate(source, marker);
        marker.position -= first;
        marker.regionOwnerID = part.id;
        marker.unifiedRegionID.reset();
        if (!fullItems && marker.automaticSectionTargetID && !markerIDs.count(*marker.automaticSectionTargetID)) {
            marker.automaticSectionTargetID.reset(); marker.automaticSectionRepeatCount.reset();
        }
    }
    for (auto &track : tracks) {
        track.audioFile.reset(); track.clickSound.reset();
        track.programChanges.erase(std::remove_if(track.programChanges.begin(), track.programChanges.end(), [&](const auto &marker) {
            return marker.position < origin || marker.position >= region.endTime;
        }), track.programChanges.end());
        for (auto &marker : track.programChanges) marker.position -= first;
        if (track.parentTrackID && !trackIDs.count(*track.parentTrackID)) {
            auto outputs = track.outputPatches();
            outputs.erase(std::remove_if(outputs.begin(), outputs.end(), [](const auto &patch) { return patch.firstChannel == -2; }), outputs.end());
            track.parentTrackID.reset();
            if (outputs.empty()) outputs.push_back({0, 2});
            track.outputs = std::move(outputs); track.patch.reset(); track.secondaryPatch.reset();
        }
        if (track.stereoLinkPartner && !trackIDs.count(*track.stereoLinkPartner)) {
            track.stereoLinkPartner.reset(); track.stereoLinkLeft = false; track.stereoLinkJSON.reset();
        }
        if (track.routing) for (auto *routes : {&track.routing->receives, &track.routing->transmitters})
            for (auto &route : *routes) if (route && !trackIDs.count(*route)) route.reset();
        jaras::automationTiming::map(track.automationJSON, [&](double time) { return std::max(0., time - first); });
        for (auto &clip : track.clips) {
            clip.startTime -= first;
            clip.regionOwnerID = part.id;
            clip.tempoRateReferences.erase(std::remove_if(clip.tempoRateReferences.begin(), clip.tempoRateReferences.end(),
                [&](const auto &reference) { return !markerIDs.count(reference.markerID); }), clip.tempoRateReferences.end());
            clip.separatedStemTracks.clear();
            song.duration = std::max(song.duration, clip.startTime + clip.duration);
        }
    }
    song.tracks = std::move(tracks);
    jaras::Project project;
    project.id = uuid(); project.name = region.name;
    project.createdAt = project.updatedAt = utf8(Time::getCurrentTime().toISO8601(true));
    project.songs.push_back(std::move(song));
    auto value = object();
    put(value, "version", 1);
    put(value, "tunerUnbaked", true);
    put(value, "project", ProjectCodec::encode(project));
    Array<var> savedStems, savedLyrics;
    for (const auto &stem : stems) {
        auto row = object();
        put(row, "file", stem.file); put(row, "track", text(stem.track));
        Array<var> items;
        for (const auto &item : stem.items) {
            auto entry = object();
            put(entry, "offset", item.offset); put(entry, "duration", item.duration); put(entry, "rate", item.rate);
            if (item.pitchSemitones) put(entry, "pitchSemitones", *item.pitchSemitones);
            items.add(entry);
        }
        put(row, "items", items); savedStems.add(row);
    }
    for (const auto &name : lyricsFiles) savedLyrics.add(name);
    put(value, "renderedStems", savedStems); put(value, "lyricsFiles", savedLyrics);
    return value;
}
inline void write(const File &file, const var &value) {
    if (!file.replaceWithText(JSON::toString(value, true)))
        throw std::runtime_error("Could not write Multitrack region data.");
}
} // namespace catlive::multitrackData
