#include "ProjectCodec.h"
#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstring>
#include <fstream>
#include <functional>
#include <limits>
#include <map>
#include <stdexcept>
#include <system_error>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <bcrypt.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

namespace catlive::native {
namespace {
using jaras::ID;
void require(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}
json object() { return json::object(); }
const json &get(const json &value, const char *key) {
    static const json absent;
    if (!value.is_object()) return absent;
    const auto found = value.find(key);
    return found == value.end() ? absent : *found;
}
void put(json &value, const char *key, json data) { value[key] = std::move(data); }
std::string jsonString(const json &value) {
    if (value.is_string()) return value.get<std::string>();
    if (value.is_null()) return {};
    if (value.is_boolean()) return value.get<bool>() ? "1" : "0";
    return value.dump();
}
std::string str(const json &value, const char *key, std::string fallback = {}) {
    const auto &entry = get(value, key);
    return entry.is_null() ? fallback : jsonString(entry);
}
double num(const json &value, const char *key, double fallback = 0) {
    const auto &entry = get(value, key);
    if (entry.is_number()) return entry.get<double>();
    if (entry.is_boolean()) return entry.get<bool>() ? 1.0 : 0.0;
    if (entry.is_string()) {
        try { return std::stod(entry.get<std::string>()); } catch (...) { return 0; }
    }
    return entry.is_null() ? fallback : 0;
}
bool flag(const json &value, const char *key, bool fallback = false) {
    return num(value, key, fallback ? 1 : 0) != 0;
}
const json &list(const json &value) {
    static const json empty = json::array();
    return value.is_array() ? value : empty;
}
template <typename T> void putDefault(json &owner, const char *key, T value, T fallback) {
    if (value != fallback || !get(owner, key).is_null()) put(owner, key, value);
}
std::string s(const json &v, const char *k) { return str(v, k); }
json merged(const json &original) { return original.is_object() ? original : object(); }
json byId(const json &array, const ID &id) {
    if (array.is_array())
        for (const auto &value : array)
            if (s(value, "id") == id)
                return value;
    return {};
}
jaras::OutputPatch patch(const json &v) {
    return {(int)num(v, "firstChannel"), (int)num(v, "channelCount", 2)};
}
json patchJSON(const jaras::OutputPatch &p) {
    auto v = object();
    put(v, "firstChannel", p.firstChannel);
    put(v, "channelCount", p.channelCount);
    return v;
}
jaras::AudioFile audioFile(const json &v) {
    jaras::AudioFile f;
    f.path = s(v, "path");
    if (get(v, "sha256").is_string())
        f.sha256 = s(v, "sha256");
    return f;
}
json audioJSON(const jaras::AudioFile &f) {
    auto v = object();
    put(v, "path", f.path);
    if (f.sha256)
        put(v, "sha256", *f.sha256);
    return v;
}
template <class T> void optionalNum(const json &v, const char *key, std::optional<T> &out) {
    if (!get(v, key).is_null())
        out = (T)num(v, key);
}
template <class T> void optionalText(const json &v, const char *key, std::optional<T> &out) {
    if (get(v, key).is_string())
        out = s(v, key);
}
void optionalJSON(const json &value, const char *key, std::optional<std::string> &out) {
    if (get(value, key).is_object())
        out = get(value, key).dump();
}
void remove(json &value, const char *key) { value.erase(key); }
template <class T> void emit(json &value, const char *key, const std::optional<T> &data) {
    if (data)
        put(value, key, *data);
    else
        remove(value, key);
}
[[maybe_unused]] void emit(json &value, const char *key, const std::optional<unsigned> &data) {
    if (data)
        put(value, key, (std::int64_t)*data);
    else
        remove(value, key);
}
void emit(json &value, const char *key, const std::optional<std::string> &data) {
    if (data)
        put(value, key, *data);
    else
        remove(value, key);
}
void emitJSON(json &value, const char *key, const std::optional<std::string> &data) {
    if (data)
        put(value, key, json::parse(*data));
    else
        remove(value, key);
}
void emit(json &value, const char *key, const std::optional<jaras::OutputPatch> &data) {
    if (data)
        put(value, key, patchJSON(*data));
    else
        remove(value, key);
}
void emit(json &value, const char *key, const std::optional<jaras::AudioFile> &data) {
    if (data)
        put(value, key, audioJSON(*data));
    else
        remove(value, key);
}
json idsJSON(const std::vector<ID> &ids) {
    json result = json::array();
    for (const auto &id : ids)
        result.push_back(id);
    return result;
}
void optionalIDs(const json &value, const char *key, std::optional<std::vector<ID>> &out) {
    if (get(value, key).is_array()) {
        out.emplace();
        for (auto id : list(get(value, key)))
            out->push_back(jsonString(id));
    }
}
jaras::TimecodeSettings timecode(const json &value) {
    jaras::TimecodeSettings t;
    t.mode = s(value, "mode");
    t.frameRate = num(value, "frameRate", 30);
    t.offset = num(value, "offset");
    t.regionRelative = flag(value, "regionRelative", true);
    t.midiDestination = (int)num(value, "midiDestination");
    return t;
}
json timecodeJSON(const jaras::TimecodeSettings &t) {
    auto value = object();
    put(value, "mode", t.mode);
    put(value, "frameRate", t.frameRate);
    put(value, "offset", t.offset);
    put(value, "regionRelative", t.regionRelative);
    put(value, "midiDestination", t.midiDestination);
    return value;
}
jaras::MIDIItem midi(const json &value) {
    jaras::MIDIItem item;
    item.sourceBPM = num(value, "sourceBPM", 120);
    auto grid = get(value, "grid");
    item.division = (int)num(grid, "division", 16);
    item.mode = str(grid, "mode", "straight");
    item.swing = num(grid, "swing", .5);
    for (auto raw : list(get(value, "notes"))) {
        jaras::MIDINote note;
        note.id = s(raw, "id");
        note.start = num(raw, "start");
        note.length = num(raw, "length", 1);
        note.pitch = (int)num(raw, "pitch", 60);
        note.velocity = (int)num(raw, "velocity", 100);
        note.channel = (int)num(raw, "channel", 1);
        item.notes.push_back(note);
    }
    return item;
}
json midiJSON(const jaras::MIDIItem &item, const json &original) {
    auto result = merged(original);
    put(result, "sourceBPM", item.sourceBPM);
    auto grid = merged(get(original, "grid"));
    put(grid, "division", item.division);
    put(grid, "mode", item.mode);
    put(grid, "swing", item.swing);
    put(result, "grid", grid);
    json notes = json::array();
    for (const auto &note : item.notes) {
        auto raw = merged(byId(get(original, "notes"), note.id));
        put(raw, "id", note.id);
        put(raw, "start", note.start);
        put(raw, "length", note.length);
        put(raw, "pitch", note.pitch);
        put(raw, "velocity", note.velocity);
        put(raw, "channel", note.channel);
        notes.push_back(raw);
    }
    put(result, "notes", notes);
    return result;
}
jaras::MultiLoop multiLoop(const json &raw) {
    jaras::MultiLoop loop;
    loop.id = s(raw, "id");
    loop.name = s(raw, "name");
    loop.marker1 = s(raw, "marker1");
    loop.marker2 = s(raw, "marker2");
    loop.fadeSeconds = num(raw, "fadeSeconds", 3);
    optionalNum(raw, "enabled", loop.enabled);
    optionalNum(raw, "mixerEnabled", loop.mixerEnabled);
    for (auto t : list(get(raw, "tracks"))) {
        jaras::MultiLoopTrack track;
        track.id = s(t, "id");
        track.gain = num(t, "gain", 1);
        track.autoFader = flag(t, "autoFader");
        track.mute = flag(t, "mute");
        track.solo = flag(t, "solo");
        loop.tracks.push_back(track);
    }
    return loop;
}
json multiLoopJSON(const jaras::MultiLoop &loop, const json &original) {
    auto raw = merged(original);
    put(raw, "id", loop.id);
    put(raw, "name", loop.name);
    put(raw, "marker1", loop.marker1);
    put(raw, "marker2", loop.marker2);
    put(raw, "fadeSeconds", loop.fadeSeconds);
    emit(raw, "enabled", loop.enabled);
    emit(raw, "mixerEnabled", loop.mixerEnabled);
    json tracks = json::array();
    for (const auto &t : loop.tracks) {
        auto value = merged(byId(get(original, "tracks"), t.id));
        put(value, "id", t.id);
        put(value, "gain", t.gain);
        put(value, "autoFader", t.autoFader);
        put(value, "mute", t.mute);
        put(value, "solo", t.solo);
        tracks.push_back(value);
    }
    put(raw, "tracks", tracks);
    return raw;
}
} // namespace

jaras::Project ProjectCodec::decode(const json &input) {
    const auto root = canonicalIDs(input);
    require(root.is_object(), "Expected project object.");
    jaras::Project p;
    p.id = s(root, "id");
    p.name = s(root, "name");
    p.projectFormatVersion = (int)num(root, "projectFormatVersion", 1);
    require(p.projectFormatVersion == 1, "This project version requires a newer CatLive.");
    p.minimumJarasVersion = s(root, "minimumJarasVersion");
    p.createdAt = s(root, "createdAt");
    p.updatedAt = s(root, "updatedAt");
    p.masterVolume = num(root, "masterVolume", 1);
    p.masterPan = num(root, "masterPan");
    p.masterMute = flag(root, "masterMute");
    p.masterSolo = flag(root, "masterSolo");
    optionalJSON(root, "masterAutomation", p.masterAutomationJSON);
    if (get(root, "masterFX").is_object())
        p.masterFXJSON = get(root, "masterFX").dump();
    p.masterMono = flag(root, "masterMono");
    optionalNum(root, "timelineMovementLocked", p.timelineMovementLocked);
    optionalNum(root, "masterColor", p.masterColor);
    optionalNum(root, "masterPhaseInverted", p.masterPhaseInverted);
    if (get(root, "masterPatch").is_object())
        p.masterPatch = patch(get(root, "masterPatch"));
    if (get(root, "masterSecondaryPatch").is_object())
        p.masterSecondaryPatch = patch(get(root, "masterSecondaryPatch"));
    if (get(root, "masterOutputs").is_array()) {
        p.masterOutputs.emplace();
        for (auto value : list(get(root, "masterOutputs")))
            p.masterOutputs->push_back(patch(value));
    }
    if (get(root, "savedCursor").is_object()) {
        auto cursor = get(root, "savedCursor");
        p.savedCursor = jaras::SavedProjectCursor{s(cursor, "songID"), num(cursor, "position")};
    }
    require(list(get(root, "songs")).size() <= 2048, "Too many songs.");
    size_t clipCount = 0;
    for (const auto &raw : list(get(root, "songs"))) {
        jaras::Song song;
        song.id = s(raw, "id");
        song.name = s(raw, "name");
        song.duration = num(raw, "duration");
        song.bpm = num(raw, "bpm", 120);
        song.beatsPerBar = (int)num(raw, "beatsPerBar", 4);
        song.beatUnit = (int)num(raw, "beatUnit", 4);
        song.regionOwnershipInitialized = flag(raw, "regionOwnershipInitialized");
        song.regionOwnershipVersion = (int)num(raw, "regionOwnershipVersion");
        if (get(raw, "timeSettings").is_object()) {
            auto value = get(raw, "timeSettings");
            jaras::ProjectTimeSettings time;
            time.divisions = (int)num(value, "divisions", 4);
            time.timebase = str(value, "timebase", "free") == "relative"
                                ? jaras::ProjectTimebase::relative
                                : jaras::ProjectTimebase::free;
            time.affectsMIDIItems = flag(value, "affectsMIDIItems");
            time.affectsAutomationLength = flag(value, "affectsAutomationLength", true);
            song.timeSettings = time;
        }
        for (const auto &rt : list(get(raw, "tracks"))) {
            jaras::Track t;
            t.id = s(rt, "id");
            t.name = s(rt, "name");
            t.role.id = s(rt, "role");
            t.volume = num(rt, "volume", 1);
            t.pan = num(rt, "pan");
            t.mute = flag(rt, "mute");
            t.solo = flag(rt, "solo");
            t.output = (int)num(rt, "output", 1);
            optionalNum(rt, "color", t.color);
            optionalNum(rt, "phaseInverted", t.phaseInverted);
            optionalNum(rt, "heightScale", t.heightScale);
            optionalText(rt, "instrumentIcon", t.instrumentIcon);
            optionalText(rt, "parentTrackID", t.parentTrackID);
            optionalJSON(rt, "automation", t.automationJSON);
            optionalNum(rt, "midiInput", t.midiInput);
            optionalNum(rt, "midiChannel", t.midiChannel);
            optionalNum(rt, "inputMonitoring", t.inputMonitoring);
            optionalNum(rt, "recordingChannels", t.recordingChannels);
            optionalText(rt, "recordingFormat", t.recordingFormat);
            t.importedTimecodeItems = flag(rt, "importedTimecodeItems");
            if (get(rt, "inputPatch").is_object())
                t.inputPatch = patch(get(rt, "inputPatch"));
            if (get(rt, "timecode").is_object())
                t.timecode = timecode(get(rt, "timecode"));
            if (get(rt, "stereoLink").is_object()) {
                auto link = get(rt, "stereoLink");
                t.stereoLinkJSON = link.dump();
                t.stereoLinkPartner = s(link, "partner");
                t.stereoLinkLeft = flag(link, "left");
            }
            if (get(rt, "routing").is_object()) {
                jaras::TrackRouting routing;
                routing.receives.clear();
                routing.transmitters.clear();
                auto rawRouting = get(rt, "routing");
                for (auto id : list(get(rawRouting, "receives")))
                    routing.receives.push_back(
                        id.is_string() ? std::optional<ID>(jsonString(id)) : std::nullopt);
                for (auto id : list(get(rawRouting, "transmitters")))
                    routing.transmitters.push_back(
                        id.is_string() ? std::optional<ID>(jsonString(id)) : std::nullopt);
                t.routing = routing;
            }
            if (get(rt, "patch").is_object())
                t.patch = patch(get(rt, "patch"));
            if (get(rt, "secondaryPatch").is_object())
                t.secondaryPatch = patch(get(rt, "secondaryPatch"));
            if (get(rt, "outputs").is_array()) {
                t.outputs.emplace();
                for (auto v : list(get(rt, "outputs")))
                    t.outputs->push_back(patch(v));
            }
            if (get(rt, "audioFile").is_object())
                t.audioFile = audioFile(get(rt, "audioFile"));
            if (get(rt, "clickSound").is_object())
                t.clickSound = audioFile(get(rt, "clickSound"));
            for (const auto &rc : list(get(rt, "clips"))) {
                require(++clipCount <= 200000, "Too many clips.");
                jaras::AudioClip c;
                c.id = s(rc, "id");
                c.name = s(rc, "name");
                c.startTime = num(rc, "startTime");
                c.duration = num(rc, "duration");
                c.sourceOffset = num(rc, "sourceOffset");
                c.playbackRate = num(rc, "playbackRate", 1);
                c.muted = flag(rc, "muted");
                optionalNum(rc, "gain", c.gain);
                optionalNum(rc, "pan", c.pan);
                optionalNum(rc, "phaseInverted", c.phaseInverted);
                optionalNum(rc, "normalizationGain", c.normalizationGain);
                optionalNum(rc, "fadeIn", c.fadeIn);
                optionalNum(rc, "fadeOut", c.fadeOut);
                optionalNum(rc, "fadeOutSCurve", c.fadeOutSCurve);
                optionalNum(rc, "fadeOutCurve", c.fadeOutCurve);
                optionalNum(rc, "fadeInSCurve", c.fadeInSCurve);
                optionalNum(rc, "fadeInCurve", c.fadeInCurve);
                optionalNum(rc, "channelMode", c.channelMode);
                optionalNum(rc, "loopStart", c.loopStart);
                optionalNum(rc, "loopLength", c.loopLength);
                optionalNum(rc, "recordingLane", c.recordingLane);
                optionalNum(rc, "timecodeStartOffset", c.timecodeStartOffset);
                optionalNum(rc, "timecodeEndOffset", c.timecodeEndOffset);
                optionalNum(rc, "fxBypassed", c.fxBypassed);
                optionalNum(rc, "frozenMIDI", c.frozenMIDI);
                optionalNum(rc, "renderedTiming", c.renderedTiming);
                optionalNum(rc, "pitchSemitones", c.pitchSemitones);
                optionalNum(rc, "tempoBasePlaybackRate", c.tempoBasePlaybackRate);
                optionalNum(rc, "renderedTempo", c.renderedTempo);
                optionalJSON(rc, "automation", c.automationJSON);
                if (get(rc, "timecode").is_object())
                    c.timecode = timecode(get(rc, "timecode"));
                if (get(rc, "midi").is_object())
                    c.midi = midi(get(rc, "midi"));
                for (auto id : list(get(rc, "separatedStemTracks")))
                    c.separatedStemTracks.push_back(jsonString(id));
                for (auto channel : list(get(rc, "waveformChannels"))) {
                    std::vector<double> values;
                    for (auto sample : list(channel))
                        values.push_back((double)sample);
                    c.waveformChannels.push_back(values);
                }
                optionalText(rc, "regionOwnerID", c.regionOwnerID);
                optionalText(rc, "text", c.text);
                if (get(rc, "audioFile").is_object())
                    c.audioFile = audioFile(get(rc, "audioFile"));
                for (auto sample : list(get(rc, "waveform")))
                    c.waveform.push_back((double)sample);
                if (get(rc, "fx").is_object())
                    c.fxJSON = get(rc, "fx").dump();
                t.clips.push_back(std::move(c));
            }
            if (get(rt, "fx").is_object())
                t.fxJSON = get(rt, "fx").dump();
            song.tracks.push_back(std::move(t));
        }
        for (const auto &rp : list(get(raw, "parts"))) {
            jaras::Part part;
            part.id = s(rp, "id");
            part.name = s(rp, "name");
            part.startTime = num(rp, "startTime");
            part.endTime = num(rp, "endTime");
            optionalNum(rp, "color", part.color);
            optionalText(rp, "parentRegionID", part.parentRegionID);
            optionalNum(rp, "uppercaseName", part.uppercaseName);
            optionalNum(rp, "pitchSemitones", part.pitchSemitones);
            optionalNum(rp, "totalLoop", part.totalLoop);
            optionalIDs(rp, "pitchTrackIDs", part.pitchTrackIDs);
            optionalIDs(rp, "pitchGroupIDs", part.pitchGroupIDs);
            for (auto loop : list(get(rp, "multiLoops")))
                part.multiLoops.push_back(multiLoop(loop));
            song.parts.push_back(std::move(part));
        }
        if (get(raw, "markers").is_array()) {
            song.markers.emplace();
            for (const auto &rm : list(get(raw, "markers"))) {
                jaras::TimelineMarker m;
                m.id = s(rm, "id");
                m.name = s(rm, "name");
                m.position = num(rm, "position");
                m.color = (unsigned)num(rm, "color");
                optionalNum(rm, "tempoBPM", m.tempoBPM);
                optionalNum(rm, "tempoBeats", m.tempoBeats);
                optionalNum(rm, "tempoUnit", m.tempoUnit);
                optionalNum(rm, "tempoReferenceBPM", m.tempoReferenceBPM);
                optionalText(rm, "tempoTimebase", m.tempoTimebase);
                optionalNum(rm, "section", m.section);
                optionalNum(rm, "loopSection", m.loopSection);
                optionalText(rm, "automaticSectionTargetID", m.automaticSectionTargetID);
                optionalText(rm, "unifiedRegionID", m.unifiedRegionID);
                optionalText(rm, "sourceRegionID", m.sourceRegionID);
                optionalText(rm, "regionOwnerID", m.regionOwnerID);
                song.markers->push_back(std::move(m));
            }
        }
        p.songs.push_back(std::move(song));
    }
    for (auto raw : list(get(root, "setlists"))) {
        jaras::Setlist sl;
        sl.id = s(raw, "id");
        sl.name = s(raw, "name");
        for (auto v : list(get(raw, "songIds")))
            sl.songIds.push_back(jsonString(v));
        p.setlists.push_back(std::move(sl));
    }
    const auto rs = get(root, "regionSetlist");
    if (rs.is_object()) {
        jaras::RegionSetlist state;
        state.autoAdvance = flag(rs, "autoAdvance");
        state.autoUntilBlockEnd = flag(rs, "autoUntilBlockEnd");
        optionalText(rs, "selectedId", state.selectedId);
        optionalNum(rs, "stopAtRegionEnd", state.stopAtRegionEnd);
        optionalNum(rs, "automaticSubplay", state.automaticSubplay);
        optionalNum(rs, "automaticSubplaySeconds", state.automaticSubplaySeconds);
        optionalNum(rs, "prepareWithoutPlayback", state.prepareWithoutPlayback);
        optionalNum(rs, "liveEnabled", state.liveEnabled);
        optionalIDs(rs, "playedLiveRegionIDs", state.playedLiveRegionIDs);
        for (auto raw : list(get(rs, "playlists"))) {
            jaras::RegionPlaylist pl;
            pl.id = s(raw, "id");
            pl.name = s(raw, "name");
            pl.songId = s(raw, "songId");
            for (auto v : list(get(raw, "regionIds")))
                pl.regionIds.push_back(jsonString(v));
            if (get(raw, "duplicates").is_array()) {
                pl.duplicates.emplace();
                for (auto duplicate : list(get(raw, "duplicates")))
                    pl.duplicates->push_back({s(duplicate, "id"), s(duplicate, "regionId")});
            }
            state.playlists.push_back(std::move(pl));
        }
        if (get(rs, "blocks").is_array()) {
            state.blocks.emplace();
            for (auto rb : list(get(rs, "blocks"))) {
                jaras::SetlistBlock b;
                b.id = s(rb, "id");
                b.songId = s(rb, "songId");
                b.name = s(rb, "name");
                b.color = (unsigned)num(rb, "color");
                optionalText(rb, "playlistId", b.playlistId);
                optionalText(rb, "beforeRegionId", b.beforeRegionId);
                optionalNum(rb, "symbol", b.symbol);
                state.blocks->push_back(b);
            }
        }
        p.regionSetlist = state;
    }
    jaras::validate(p);
    return p;
}
json ProjectCodec::encode(const jaras::Project &p, json input) {
    const auto original = canonicalIDs(input);
    jaras::validate(p);
    auto root = merged(original);
    put(root, "id", p.id);
    put(root, "name", p.name);
    put(root, "projectFormatVersion", p.projectFormatVersion);
    put(root, "minimumJarasVersion", "1.0.0");
    put(root, "createdAt", p.createdAt);
    put(root, "updatedAt", p.updatedAt);
    putDefault(root, "masterVolume", p.masterVolume, 1.0);
    putDefault(root, "masterPan", p.masterPan, 0.0);
    putDefault(root, "masterMute", p.masterMute, false);
    putDefault(root, "masterSolo", p.masterSolo, false);
    putDefault(root, "masterMono", p.masterMono, false);
    if (p.timelineMovementLocked) put(root, "timelineMovementLocked", *p.timelineMovementLocked);
    else root.erase("timelineMovementLocked");
    emitJSON(root, "masterAutomation", p.masterAutomationJSON);
    emit(root, "masterPatch", p.masterPatch);
    emit(root, "masterSecondaryPatch", p.masterSecondaryPatch);
    emit(root, "masterPhaseInverted", p.masterPhaseInverted);
    emit(root, "masterColor", p.masterColor);
    if (p.masterOutputs) {
        json patches = json::array();
        for (const auto &value : *p.masterOutputs)
            patches.push_back(patchJSON(value));
        put(root, "masterOutputs", patches);
    } else remove(root, "masterOutputs");
    if (p.savedCursor) {
        auto cursor = merged(get(root, "savedCursor"));
        put(cursor, "songID", p.savedCursor->songID);
        put(cursor, "position", p.savedCursor->position);
        put(root, "savedCursor", cursor);
    } else remove(root, "savedCursor");
    if (p.masterFXJSON)
        put(root, "masterFX", json::parse(*p.masterFXJSON));
    else remove(root, "masterFX");
    json songs = json::array();
    for (const auto &song : p.songs) {
        auto raw = merged(byId(get(original, "songs"), song.id));
        put(raw, "id", song.id);
        put(raw, "name", song.name);
        put(raw, "duration", song.duration);
        put(raw, "bpm", song.bpm);
        putDefault(raw, "beatsPerBar", song.beatsPerBar, 4);
        putDefault(raw, "beatUnit", song.beatUnit, 4);
        if (song.timeSettings) {
            auto value = merged(get(raw, "timeSettings"));
            put(value, "divisions", song.timeSettings->divisions);
            put(value, "timebase",
                song.timeSettings->timebase == jaras::ProjectTimebase::relative ? "relative"
                                                                                : "free");
            put(value, "affectsMIDIItems", song.timeSettings->affectsMIDIItems);
            put(value, "affectsAutomationLength", song.timeSettings->affectsAutomationLength);
            put(raw, "timeSettings", value);
        } else remove(raw, "timeSettings");
        if (song.regionOwnershipInitialized || !get(raw, "regionOwnershipInitialized").is_null())
            put(raw, "regionOwnershipInitialized", song.regionOwnershipInitialized);
        if (song.regionOwnershipVersion || !get(raw, "regionOwnershipVersion").is_null())
            put(raw, "regionOwnershipVersion", song.regionOwnershipVersion);
        json tracks = json::array();
        for (const auto &t : song.tracks) {
            auto rt = merged(byId(get(raw, "tracks"), t.id));
            put(rt, "id", t.id);
            put(rt, "name", t.name);
            put(rt, "role", t.role.id);
            put(rt, "volume", t.volume);
            put(rt, "pan", t.pan);
            put(rt, "mute", t.mute);
            put(rt, "solo", t.solo);
            put(rt, "output", t.output);
            emitJSON(rt, "automation", t.automationJSON);
            emitJSON(rt, "stereoLink", t.stereoLinkJSON);
            emit(rt, "midiInput", t.midiInput);
            emit(rt, "midiChannel", t.midiChannel);
            emit(rt, "inputMonitoring", t.inputMonitoring);
            emit(rt, "recordingChannels", t.recordingChannels);
            emit(rt, "recordingFormat", t.recordingFormat);
            emit(rt, "inputPatch", t.inputPatch);
            emit(rt, "patch", t.patch);
            emit(rt, "secondaryPatch", t.secondaryPatch);
            emit(rt, "parentTrackID", t.parentTrackID);
            emit(rt, "audioFile", t.audioFile);
            emit(rt, "clickSound", t.clickSound);
            if (!t.outputs)
                remove(rt, "outputs");
            if (t.timecode)
                put(rt, "timecode", timecodeJSON(*t.timecode));
            else
                remove(rt, "timecode");
            if (t.importedTimecodeItems || !get(rt, "importedTimecodeItems").is_null())
                put(rt, "importedTimecodeItems", t.importedTimecodeItems);
            if (t.routing) {
                auto value = merged(get(rt, "routing"));
                json receives = json::array(), transmitters = json::array();
                for (const auto &id : t.routing->receives)
                    receives.push_back(id ? json(*id) : json());
                for (const auto &id : t.routing->transmitters)
                    transmitters.push_back(id ? json(*id) : json());
                put(value, "receives", receives);
                put(value, "transmitters", transmitters);
                put(rt, "routing", value);
            } else
                remove(rt, "routing");
            if (t.fxJSON)
                put(rt, "fx", json::parse(*t.fxJSON));
            else remove(rt, "fx");
            emit(rt, "color", t.color);
            if (t.patch)
                put(rt, "patch", patchJSON(*t.patch));
            if (t.secondaryPatch)
                put(rt, "secondaryPatch", patchJSON(*t.secondaryPatch));
            if (t.outputs) {
                json patches = json::array();
                for (const auto &value : *t.outputs)
                    patches.push_back(patchJSON(value));
                put(rt, "outputs", patches);
            }
            if (t.parentTrackID)
                put(rt, "parentTrackID", *t.parentTrackID);
            emit(rt, "heightScale", t.heightScale);
            emit(rt, "instrumentIcon", t.instrumentIcon);
            emit(rt, "phaseInverted", t.phaseInverted);
            if (t.audioFile)
                put(rt, "audioFile", audioJSON(*t.audioFile));
            if (t.clickSound)
                put(rt, "clickSound", audioJSON(*t.clickSound));
            json clips = json::array();
            for (const auto &c : t.clips) {
                auto rc = merged(byId(get(rt, "clips"), c.id));
                put(rc, "id", c.id);
                put(rc, "name", c.name);
                put(rc, "startTime", c.startTime);
                put(rc, "duration", c.duration);
                put(rc, "sourceOffset", c.sourceOffset);
                putDefault(rc, "playbackRate", c.playbackRate, 1.0);
                putDefault(rc, "muted", c.muted, false);
                emitJSON(rc, "automation", c.automationJSON);
                emit(rc, "audioFile", c.audioFile);
                emit(rc, "normalizationGain", c.normalizationGain);
                emit(rc, "recordingLane", c.recordingLane);
                emit(rc, "channelMode", c.channelMode);
                emit(rc, "loopStart", c.loopStart);
                emit(rc, "loopLength", c.loopLength);
                emit(rc, "timecodeStartOffset", c.timecodeStartOffset);
                emit(rc, "timecodeEndOffset", c.timecodeEndOffset);
                emit(rc, "fxBypassed", c.fxBypassed);
                emit(rc, "frozenMIDI", c.frozenMIDI);
                emit(rc, "renderedTiming", c.renderedTiming);
                emit(rc, "pitchSemitones", c.pitchSemitones);
                emit(rc, "tempoBasePlaybackRate", c.tempoBasePlaybackRate);
                emit(rc, "renderedTempo", c.renderedTempo);
                if (c.midi)
                    put(rc, "midi", midiJSON(*c.midi, get(rc, "midi")));
                else
                    remove(rc, "midi");
                if (c.timecode)
                    put(rc, "timecode", timecodeJSON(*c.timecode));
                else
                    remove(rc, "timecode");
                if (!c.separatedStemTracks.empty() || get(rc, "separatedStemTracks").is_array())
                    put(rc, "separatedStemTracks", idsJSON(c.separatedStemTracks));
                if (!c.waveformChannels.empty() || get(rc, "waveformChannels").is_array()) {
                    json channels = json::array();
                    for (const auto &samples : c.waveformChannels) {
                        json channel = json::array();
                        for (auto sample : samples)
                            channel.push_back(sample);
                        channels.push_back(channel);
                    }
                    put(rc, "waveformChannels", channels);
                }
                if (c.fxJSON)
                    put(rc, "fx", json::parse(*c.fxJSON));
                else remove(rc, "fx");
                if (c.audioFile)
                    put(rc, "audioFile", audioJSON(*c.audioFile));
                emit(rc, "gain", c.gain);
                emit(rc, "pan", c.pan);
                emit(rc, "phaseInverted", c.phaseInverted);
                emit(rc, "fadeIn", c.fadeIn);
                emit(rc, "fadeOut", c.fadeOut);
                if (c.fadeOutSCurve) put(rc, "fadeOutSCurve", *c.fadeOutSCurve); else rc.erase("fadeOutSCurve");
                if (c.fadeOutCurve) put(rc, "fadeOutCurve", *c.fadeOutCurve); else rc.erase("fadeOutCurve");
                if (c.fadeInSCurve) put(rc, "fadeInSCurve", *c.fadeInSCurve); else rc.erase("fadeInSCurve");
                if (c.fadeInCurve) put(rc, "fadeInCurve", *c.fadeInCurve); else rc.erase("fadeInCurve");
                emit(rc, "regionOwnerID", c.regionOwnerID);
                emit(rc, "text", c.text);
                json peaks = json::array();
                for (auto sample : c.waveform)
                    peaks.push_back(sample);
                put(rc, "waveform", peaks);
                clips.push_back(rc);
            }
            put(rt, "clips", clips);
            tracks.push_back(rt);
        }
        put(raw, "tracks", tracks);
        json parts = json::array();
        for (const auto &part : song.parts) {
            auto rp = merged(byId(get(raw, "parts"), part.id));
            put(rp, "id", part.id);
            put(rp, "name", part.name);
            put(rp, "startTime", part.startTime);
            put(rp, "endTime", part.endTime);
            emit(rp, "color", part.color);
            emit(rp, "parentRegionID", part.parentRegionID);
            emit(rp, "uppercaseName", part.uppercaseName);
            emit(rp, "pitchSemitones", part.pitchSemitones);
            emit(rp, "totalLoop", part.totalLoop);
            if (part.pitchTrackIDs)
                put(rp, "pitchTrackIDs", idsJSON(*part.pitchTrackIDs));
            else
                remove(rp, "pitchTrackIDs");
            if (part.pitchGroupIDs)
                put(rp, "pitchGroupIDs", idsJSON(*part.pitchGroupIDs));
            else
                remove(rp, "pitchGroupIDs");
            if (!part.multiLoops.empty() || get(rp, "multiLoops").is_array()) {
                json loops = json::array();
                for (const auto &loop : part.multiLoops)
                    loops.push_back(multiLoopJSON(loop, byId(get(rp, "multiLoops"), loop.id)));
                put(rp, "multiLoops", loops);
            }
            parts.push_back(rp);
        }
        put(raw, "parts", parts);
        if (song.markers) {
            json markers = json::array();
            for (const auto &m : *song.markers) {
                auto rm = merged(byId(get(raw, "markers"), m.id));
                put(rm, "id", m.id);
                put(rm, "name", m.name);
                put(rm, "position", m.position);
                put(rm, "color", (std::int64_t)m.color);
                emit(rm, "tempoBeats", m.tempoBeats);
                emit(rm, "tempoUnit", m.tempoUnit);
                emit(rm, "tempoReferenceBPM", m.tempoReferenceBPM);
                emit(rm, "tempoTimebase", m.tempoTimebase);
                emit(rm, "unifiedRegionID", m.unifiedRegionID);
                emit(rm, "sourceRegionID", m.sourceRegionID);
                emit(rm, "regionOwnerID", m.regionOwnerID);
                emit(rm, "tempoBPM", m.tempoBPM);
                emit(rm, "section", m.section);
                emit(rm, "loopSection", m.loopSection);
                emit(rm, "automaticSectionTargetID", m.automaticSectionTargetID);
                markers.push_back(rm);
            }
            put(raw, "markers", markers);
        } else remove(raw, "markers");
        songs.push_back(raw);
    }
    put(root, "songs", songs);
    json setlists = json::array();
    for (const auto &sl : p.setlists) {
        auto raw = merged(byId(get(original, "setlists"), sl.id));
        put(raw, "id", sl.id);
        put(raw, "name", sl.name);
        json ids = json::array();
        for (auto &id : sl.songIds)
            ids.push_back(id);
        put(raw, "songIds", ids);
        setlists.push_back(raw);
    }
    put(root, "setlists", setlists);
    if (p.regionSetlist) {
        const auto &state = *p.regionSetlist;
        auto rs = merged(get(original, "regionSetlist"));
        put(rs, "autoAdvance", state.autoAdvance);
        putDefault(rs, "autoUntilBlockEnd", state.autoUntilBlockEnd, false);
        emit(rs, "selectedId", state.selectedId);
        emit(rs, "stopAtRegionEnd", state.stopAtRegionEnd);
        emit(rs, "prepareWithoutPlayback", state.prepareWithoutPlayback);
        emit(rs, "automaticSubplay", state.automaticSubplay);
        emit(rs, "automaticSubplaySeconds", state.automaticSubplaySeconds);
        emit(rs, "liveEnabled", state.liveEnabled);
        if (state.playedLiveRegionIDs)
            put(rs, "playedLiveRegionIDs", idsJSON(*state.playedLiveRegionIDs));
        else
            remove(rs, "playedLiveRegionIDs");
        json playlists = json::array();
        for (const auto &playlist : state.playlists) {
            auto value = merged(byId(get(rs, "playlists"), playlist.id));
            put(value, "id", playlist.id);
            put(value, "name", playlist.name);
            put(value, "songId", playlist.songId);
            put(value, "regionIds", idsJSON(playlist.regionIds));
            if (playlist.duplicates) {
                json duplicates = json::array();
                for (const auto &entry : *playlist.duplicates) {
                    auto duplicate = json::object();
                    put(duplicate, "id", entry.id);
                    put(duplicate, "regionId", entry.regionId);
                    duplicates.push_back(duplicate);
                }
                put(value, "duplicates", duplicates);
            } else value.erase("duplicates");
            playlists.push_back(value);
        }
        put(rs, "playlists", playlists);
        if (state.blocks) {
            json blocks = json::array();
            for (const auto &block : *state.blocks) {
                auto value = merged(byId(get(rs, "blocks"), block.id));
                put(value, "id", block.id);
                put(value, "songId", block.songId);
                put(value, "name", block.name);
                put(value, "color", (std::int64_t)block.color);
                emit(value, "playlistId", block.playlistId);
                emit(value, "beforeRegionId", block.beforeRegionId);
                emit(value, "symbol", block.symbol);
                blocks.push_back(value);
            }
            put(rs, "blocks", blocks);
        } else
            remove(rs, "blocks");
        put(root, "regionSetlist", rs);
    } else
        remove(root, "regionSetlist");
    return canonicalIDs(root);
}


namespace {
std::string lowerASCII(std::string value) {
    for (auto &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return value;
}
bool compactUUID(const std::string &value) {
    return value.size() == 32 && std::all_of(value.begin(), value.end(), [](unsigned char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    });
}
std::string dashedUUID(std::string value) {
    for (auto &c : value) if (c >= 'a' && c <= 'f') c -= 'a' - 'A';
    for (const auto at : {20, 16, 12, 8}) value.insert((size_t)at, 1, '-');
    return value;
}
constexpr unsigned char documentHeader[]{0x4a, 0x41, 0x52, 0x41, 0x53, 0x4a, 0x4c, 0x00, 0x01};
constexpr std::size_t maximumDocumentBytes = 128 * 1024 * 1024;
#ifdef _WIN32
// Same application document key and authenticated header as ProjectDocumentCodec.swift.
constexpr unsigned char documentKey[]{0xce, 0x9a, 0x3a, 0xb3, 0xab, 0x54, 0x63, 0x22, 0x5a, 0x93, 0xd8,
    0x65, 0xdd, 0xe0, 0x49, 0xce, 0x38, 0x56, 0xde, 0x29, 0x9a, 0x12,
    0x29, 0x44, 0x07, 0x41, 0xf7, 0x37, 0x0f, 0x49, 0x69, 0xfd};
void cryptoCheck(NTSTATUS status) {
    require(status >= 0, "Project authentication/encryption failed.");
}
struct AES {
    BCRYPT_ALG_HANDLE algorithm{};
    BCRYPT_KEY_HANDLE key{};
    AES() {
        cryptoCheck(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_AES_ALGORITHM, nullptr, 0));
        try {
            cryptoCheck(BCryptSetProperty(algorithm, BCRYPT_CHAINING_MODE,
                reinterpret_cast<PUCHAR>(const_cast<wchar_t *>(BCRYPT_CHAIN_MODE_GCM)),
                sizeof(BCRYPT_CHAIN_MODE_GCM), 0));
            cryptoCheck(BCryptGenerateSymmetricKey(algorithm, &key, nullptr, 0,
                const_cast<PUCHAR>(documentKey), sizeof(documentKey), 0));
        } catch (...) {
            BCryptCloseAlgorithmProvider(algorithm, 0);
            throw;
        }
    }
    ~AES() {
        if (key) BCryptDestroyKey(key);
        if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    }
    AES(const AES &) = delete;
    AES &operator=(const AES &) = delete;
};
std::vector<unsigned char> encryptDocument(const std::string &plaintext) {
    require(plaintext.size() <= maximumDocumentBytes - sizeof(documentHeader) - 28,
            "Document exceeds 128 MB.");
    AES aes;
    const auto bytes = static_cast<ULONG>(plaintext.size());
    std::vector<unsigned char> result(sizeof(documentHeader) + 12 + bytes + 16);
    std::copy(std::begin(documentHeader), std::end(documentHeader), result.begin());
    auto *nonce = result.data() + sizeof(documentHeader);
    cryptoCheck(BCryptGenRandom(nullptr, nonce, 12, BCRYPT_USE_SYSTEM_PREFERRED_RNG));
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = nonce;
    info.cbNonce = 12;
    info.pbAuthData = const_cast<PUCHAR>(documentHeader);
    info.cbAuthData = sizeof(documentHeader);
    info.pbTag = nonce + 12 + bytes;
    info.cbTag = 16;
    ULONG written = 0;
    cryptoCheck(BCryptEncrypt(aes.key,
        reinterpret_cast<PUCHAR>(const_cast<char *>(plaintext.data())), bytes, &info,
        nullptr, 0, nonce + 12, bytes, &written, 0));
    require(written == bytes, "Invalid encrypted document size.");
    return result;
}
std::string decrypt(const std::vector<unsigned char> &bytes) {
    require(bytes.size() >= sizeof(documentHeader) + 28, "Truncated CatLive document.");
    AES aes;
    const auto size = static_cast<ULONG>(bytes.size() - sizeof(documentHeader) - 28);
    std::string result(size, '\0');
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = const_cast<PUCHAR>(bytes.data() + sizeof(documentHeader));
    info.cbNonce = 12;
    info.pbAuthData = const_cast<PUCHAR>(documentHeader);
    info.cbAuthData = sizeof(documentHeader);
    info.pbTag = const_cast<PUCHAR>(bytes.data() + bytes.size() - 16);
    info.cbTag = 16;
    ULONG written = 0;
    cryptoCheck(BCryptDecrypt(aes.key, const_cast<PUCHAR>(bytes.data() + sizeof(documentHeader) + 12),
        size, &info, nullptr, 0, reinterpret_cast<PUCHAR>(result.data()), size, &written, 0));
    require(written == size, "Invalid decrypted document size.");
    return result;
}
struct TemporaryOutput {
    std::filesystem::path path;
    HANDLE handle = INVALID_HANDLE_VALUE;
    bool ownsFile = false;
    ~TemporaryOutput() {
        if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
        if (ownsFile && !path.empty()) DeleteFileW(path.c_str());
    }
};
void atomicWrite(const std::filesystem::path &destination, const std::vector<unsigned char> &bytes) {
    TemporaryOutput output;
    for (int attempt = 0; attempt < 16 && output.handle == INVALID_HANDLE_VALUE; ++attempt) {
        std::array<unsigned char, 16> random{};
        cryptoCheck(BCryptGenRandom(nullptr, random.data(), (ULONG)random.size(), BCRYPT_USE_SYSTEM_PREFERRED_RNG));
        std::wstring name = L".catlive-save-";
        for (const auto byte : random) { name += L"0123456789abcdef"[byte >> 4]; name += L"0123456789abcdef"[byte & 15]; }
        output.path = destination.parent_path() / (name + L".tmp");
        output.handle = CreateFileW(output.path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                                   FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
        if (output.handle == INVALID_HANDLE_VALUE && GetLastError() != ERROR_FILE_EXISTS)
            throw std::runtime_error("Could not create temporary project; previous file was preserved.");
    }
    require(output.handle != INVALID_HANDLE_VALUE, "Could not allocate temporary project.");
    output.ownsFile = true;
    std::size_t offset = 0;
    while (offset < bytes.size()) {
        const auto count = static_cast<DWORD>(std::min<std::size_t>(bytes.size() - offset, 1024 * 1024));
        DWORD written = 0;
        require(WriteFile(output.handle, bytes.data() + offset, count, &written, nullptr) && written > 0,
                "Could not write project; previous file was preserved.");
        offset += written;
    }
    require(FlushFileBuffers(output.handle), "Could not flush project; previous file was preserved.");
    const auto handle = output.handle;
    output.handle = INVALID_HANDLE_VALUE;
    require(CloseHandle(handle), "Could not close project; previous file was preserved.");
    require(MoveFileExW(output.path.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH),
            "Could not replace project; previous file was preserved.");
    output.path.clear();
}
#endif
} // namespace

namespace {
// UUID migration is schema-aware. Vendor state and future fields may contain
// identical-looking strings/keys, but their identity belongs to the producer.
std::string canonicalID(const std::string &value) {
    if (compactUUID(value)) return dashedUUID(value);
    if (value.size() == 41 && value.substr(32) == "-timecode" && compactUUID(value.substr(0, 32))) {
        auto result = dashedUUID(value.substr(0, 32));
        const auto first = std::string("0123456789ABCDEF").find(result[0]) ^ 8;
        result[0] = "0123456789ABCDEF"[first];
        return result;
    }
    return value;
}
void canonicalIDValue(json &value) {
    if (value.is_string()) value = canonicalID(value.get<std::string>());
}
template <typename F> void field(json &owner, const char *key, F &&work) {
    if (!owner.is_object()) return;
    const auto found = owner.find(key);
    if (found != owner.end()) work(*found);
}
template <typename F> void elements(json &owner, const char *key, F &&work) {
    field(owner, key, [&](json &values) {
        if (values.is_array()) for (auto &value : values) work(value);
    });
}
void canonicalIDFields(json &owner, std::initializer_list<const char *> keys) {
    for (const auto *key : keys) field(owner, key, canonicalIDValue);
}
void canonicalIDArray(json &owner, const char *key) {
    elements(owner, key, canonicalIDValue);
}
void canonicalNativeKey(json &value) {
    if (!value.is_string()) return;
    const auto text = value.get<std::string>();
    if (text.compare(0, 7, "Native:") == 0) value = "Native:" + canonicalID(text.substr(7));
}
void canonicalFX(json &fx) {
    elements(fx, "bands", [](json &band) { canonicalIDFields(band, {"id"}); });
    elements(fx, "instances", [](json &instance) {
        canonicalIDFields(instance, {"id"});
        field(instance, "settings", canonicalFX);
    });
    elements(fx, "inserted", canonicalNativeKey);
    // External instance IDs, class IDs, component/controller states and all
    // other external plugin content are opaque strings, not Swift UUID fields.
}
void canonicalAutomation(json &automation) {
    elements(automation, "envelopes", [](json &envelope) {
        canonicalIDFields(envelope, {"id"});
        elements(envelope, "points", [](json &point) { canonicalIDFields(point, {"id"}); });
        field(envelope, "target", [](json &target) {
            field(target, "native", [](json &native) {
                canonicalIDFields(native, {"band"});
                field(native, "effect", canonicalNativeKey);
            });
        });
    });
}
void canonicalRouting(json &routing) {
    canonicalIDArray(routing, "receives");
    canonicalIDArray(routing, "transmitters");
}
void canonicalMapKeys(json &map, bool prefixed) {
    if (!map.is_object()) return;
    json result = object();
    for (auto &entry : map.items()) {
        auto key = entry.key();
        if (!prefixed) key = canonicalID(key);
        else if (key.compare(0, 7, "region:") == 0 || key.compare(0, 7, "marker:") == 0)
            key = key.substr(0, 7) + canonicalID(key.substr(7));
        require(!result.contains(key), "Conflicting legacy IDs in integration map.");
        result[key] = std::move(entry.value());
    }
    map = std::move(result);
}
} // namespace

json ProjectCodec::canonicalIDs(const json &input) {
    auto root = input;
    canonicalIDFields(root, {"id"});
    field(root, "savedCursor", [](json &cursor) { canonicalIDFields(cursor, {"songID"}); });
    field(root, "masterFX", canonicalFX);
    field(root, "masterAutomation", canonicalAutomation);
    elements(root, "setlists", [](json &setlist) {
        canonicalIDFields(setlist, {"id"}); canonicalIDArray(setlist, "songIds");
    });
    field(root, "regionSetlist", [](json &setlist) {
        canonicalIDFields(setlist, {"selectedId"});
        canonicalIDArray(setlist, "playedLiveRegionIDs");
        elements(setlist, "playlists", [](json &playlist) {
            canonicalIDFields(playlist, {"id", "songId"}); canonicalIDArray(playlist, "regionIds");
            elements(playlist, "duplicates", [](json &entry) { canonicalIDFields(entry, {"id", "regionId"}); });
        });
        elements(setlist, "blocks", [](json &block) {
            canonicalIDFields(block, {"id", "songId", "playlistId", "beforeRegionId"});
        });
    });
    elements(root, "songs", [](json &song) {
        canonicalIDFields(song, {"id"});
        elements(song, "tracks", [](json &track) {
            canonicalIDFields(track, {"id", "parentTrackID"});
            field(track, "routing", canonicalRouting);
            field(track, "stereoLink", [](json &link) {
                canonicalIDFields(link, {"partner"});
                field(link, "original", [](json &original) { field(original, "routing", canonicalRouting); });
            });
            field(track, "fx", canonicalFX); field(track, "automation", canonicalAutomation);
            elements(track, "clips", [](json &clip) {
                canonicalIDFields(clip, {"id", "regionOwnerID"});
                canonicalIDArray(clip, "separatedStemTracks");
                field(clip, "fx", canonicalFX); field(clip, "automation", canonicalAutomation);
                field(clip, "midi", [](json &midi) {
                    elements(midi, "notes", [](json &note) { canonicalIDFields(note, {"id"}); });
                });
            });
        });
        elements(song, "parts", [](json &part) {
            canonicalIDFields(part, {"id", "parentRegionID"});
            canonicalIDArray(part, "pitchTrackIDs"); canonicalIDArray(part, "pitchGroupIDs");
            elements(part, "multiLoops", [](json &loop) {
                canonicalIDFields(loop, {"id", "marker1", "marker2"});
                elements(loop, "tracks", [](json &track) { canonicalIDFields(track, {"id"}); });
            });
        });
        elements(song, "markers", [](json &marker) {
            canonicalIDFields(marker, {"id", "unifiedRegionID", "sourceRegionID", "regionOwnerID"});
        });
    });
    field(root, "resolume", [](json &resolume) {
        for (const auto *key : {"withMarkers", "regionsOnly"})
            field(resolume, key, [](json &map) { canonicalMapKeys(map, true); });
    });
    field(root, "windowsLighting", [](json &lighting) {
        field(lighting, "assignments", [](json &map) { canonicalMapKeys(map, true); });
        field(lighting, "starts", [](json &map) { canonicalMapKeys(map, false); });
    });
    return root;
}

std::vector<std::uint8_t> ProjectCodec::seal(const std::string &plaintext) {
#ifdef _WIN32
    return encryptDocument(plaintext);
#else
    (void)plaintext;
    throw std::runtime_error("Encrypted Windows .jl I/O requires the Windows CNG backend.");
#endif
}
std::string ProjectCodec::unseal(const std::vector<std::uint8_t> &bytes) {
    require(!bytes.empty() && bytes.size() <= maximumDocumentBytes, "Invalid project or document exceeds 128 MB.");
    if (bytes.size() >= sizeof(documentHeader) &&
        std::equal(std::begin(documentHeader), std::end(documentHeader), bytes.begin())) {
#ifdef _WIN32
        return decrypt(bytes);
#else
        throw std::runtime_error("Encrypted Windows .jl I/O requires the Windows CNG backend.");
#endif
    }
    std::string plaintext(bytes.begin(), bytes.end());
    const auto first = plaintext.find_first_not_of(" \t\r\n");
    require(first != std::string::npos && plaintext[first] == '{', "Invalid or unsupported .jl project.");
    return plaintext;
}
namespace {
#ifdef _WIN32
std::wstring normalizedMediaName(const std::wstring &value) {
    const int count = NormalizeString(NormalizationC, value.c_str(), -1, nullptr, 0);
    if (count <= 0) return value;
    std::wstring result((size_t)count, L'\0');
    const int written = NormalizeString(NormalizationC, value.c_str(), -1, result.data(), count);
    if (written <= 0) return value;
    result.resize(static_cast<size_t>(written));
    if (!result.empty() && result.back() == L'\0') result.pop_back();
    return result;
}
#endif
std::filesystem::path existingMediaPath(const std::filesystem::path &requested, int depth = 0) {
    if (std::filesystem::exists(requested) || depth >= 64) return requested;
    const auto parent = requested.parent_path();
    if (parent == requested || parent.empty()) return requested;
    const auto folder = existingMediaPath(parent, depth + 1);
    if (!std::filesystem::is_directory(folder)) return requested;
    const auto exact = folder / requested.filename();
    if (std::filesystem::exists(exact)) return exact;
    std::filesystem::path match;
#ifdef _WIN32
    const auto wanted = normalizedMediaName(requested.filename().native());
#else
    const auto wanted = lowerASCII(requested.filename().u8string());
#endif
    for (const auto &entry : std::filesystem::directory_iterator(folder)) {
#ifdef _WIN32
        const auto candidate = normalizedMediaName(entry.path().filename().native());
        const bool equal = CompareStringOrdinal(candidate.c_str(), -1, wanted.c_str(), -1, TRUE) == CSTR_EQUAL;
#else
        // Native APFS handles canonical equivalents on exact existence checks.
        const bool equal = lowerASCII(entry.path().filename().u8string()) == wanted;
#endif
        if (!equal) continue;
        if (!match.empty()) return requested;
        match = entry.path();
    }
    return match.empty() ? requested : match;
}
} // namespace
std::filesystem::path ProjectCodec::resolveMedia(const std::filesystem::path &directory,
                                               const std::string &relative, bool resolveExisting) {
    auto value = relative;
    std::replace(value.begin(), value.end(), '\\', '/');
    require(!value.empty() && value.front() != '/' && value.find(':') == std::string::npos &&
            value.find('\0') == std::string::npos, "Audio paths must be relative to the project.");
    const auto path = std::filesystem::u8path(value);
    require(!path.is_absolute() && !path.has_root_path(), "Audio paths must be relative to the project.");
    for (const auto &part : path) require(part != ".." && part != ".", "Unsafe media path.");
    const auto root = std::filesystem::absolute(directory).lexically_normal();
    const auto file = (root / path).lexically_normal();
    auto base = root.begin(), child = file.begin();
    for (; base != root.end() && child != file.end(); ++base, ++child)
        require(*base == *child, "Audio path escapes project folder.");
    require(base == root.end() && child != file.end(), "Audio path escapes project folder.");
    return resolveExisting ? existingMediaPath(file) : file;
}

json ProjectCodec::read(const std::filesystem::path &file) {
    const auto size = std::filesystem::file_size(file);
    require(size > 0 && size <= maximumDocumentBytes, "Invalid project or document exceeds 128 MB.");
    std::ifstream stream(file, std::ios::binary);
    require(stream.is_open(), "Could not read project.");
    std::vector<unsigned char> bytes(static_cast<std::size_t>(size));
    stream.read(reinterpret_cast<char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    require(static_cast<std::size_t>(stream.gcount()) == bytes.size(), "Could not read complete project.");
    const auto plaintext = unseal(bytes);
    auto result = canonicalIDs(json::parse(plaintext));
    decode(result);
    return result;
}

void ProjectCodec::write(const std::filesystem::path &file, const json &input) {
    const auto value = canonicalIDs(input);
    decode(value);
#ifdef _WIN32
    const auto destination = std::filesystem::absolute(file).lexically_normal();
    const auto folder = destination.parent_path();
    std::filesystem::create_directories(folder);
    for (const auto &entry : std::filesystem::directory_iterator(folder)) {
        if (!entry.is_regular_file() || lowerASCII(entry.path().extension().u8string()) != ".jl") continue;
        const auto other = entry.path().lexically_normal();
        const bool same = CompareStringOrdinal(other.c_str(), -1, destination.c_str(), -1, TRUE) == CSTR_EQUAL;
        require(same, "Choose a separate folder for each CatLive project.");
    }
    atomicWrite(destination, seal(value.dump()));
#else
    (void)file;
    throw std::runtime_error("Encrypted Windows .jl I/O requires the Windows CNG backend.");
#endif
}

} // namespace catlive::native
