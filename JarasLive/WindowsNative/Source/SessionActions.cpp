#include "SessionActions.h"
#include "Identifier.h"
#include "TrackDuplication.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <stdexcept>
#include <string_view>

namespace catlive::native {
namespace {
using json = nlohmann::json;
using namespace jaras;
[[noreturn]] void invalid(const std::string& message) { throw std::invalid_argument(message); }
void require(bool condition, const std::string& message) { if (!condition) invalid(message); }

void object(const json& value, std::initializer_list<std::string_view> keys) {
    require(value.is_object(), "Expected an argument object");
    for (auto it = value.begin(); it != value.end(); ++it)
        require(std::find(keys.begin(), keys.end(), it.key()) != keys.end(), "Unknown argument: " + it.key());
}
const json& field(const json& value, const char* key) {
    const auto found = value.find(key);
    if (found == value.end()) invalid(std::string("Missing argument: ") + key);
    return *found;
}
std::string text(const json& value) {
    require(value.is_string(), "Expected a string");
    const auto result = value.get<std::string>();
    jaras::validateClipText(result);
    return result;
}
std::string identifier(const json& value) {
    auto result = text(value);
    require(!result.empty() && result.size() <= 1024 && result.find('\0') == std::string::npos,
            "Expected a nonempty identifier");
    return result;
}
double number(const json& value) {
    require(value.is_number(), "Expected a number");
    const auto result = value.get<double>();
    require(std::isfinite(result), "Non-finite number");
    return result;
}
int integer(const json& value) {
    const auto result = number(value);
    require(result == std::floor(result) && result >= std::numeric_limits<int>::min()
            && result <= std::numeric_limits<int>::max(), "Expected an integer");
    return static_cast<int>(result);
}
bool boolean(const json& value) {
    require(value.is_boolean(), "Expected a boolean");
    return value.get<bool>();
}
unsigned color(const json& value) {
    const auto result = integer(value);
    require(result >= 0 && result <= 0xffffff, "Expected a 24-bit RGB color");
    return static_cast<unsigned>(result);
}
const json& array(const json& value, std::size_t limit = 200000) {
    require(value.is_array() && value.size() <= limit, "Invalid array or array too large");
    return value;
}
template<class T, class Decode>
void optional(const json& value, const char* key, std::optional<T>& target, Decode decode) {
    if (!value.contains(key)) return;
    const auto& raw = value.at(key);
    target = raw.is_null() ? std::optional<T>{} : std::optional<T>{decode(raw)};
}
template<class T, class Decode>
void setting(const json& value, const char* key, T& target, Decode decode) {
    if (value.contains(key)) target = decode(value.at(key));
}
void finiteJSON(const json& value, unsigned depth = 0) {
    require(depth <= 64, "Arguments are nested too deeply");
    if (value.is_number()) (void)number(value);
    else if (value.is_structured()) for (const auto& child : value) finiteJSON(child, depth + 1);
    else require(!value.is_binary() && !value.is_discarded(), "Unsupported JSON value");
}
std::vector<ID> identifiers(const json& value) {
    std::vector<ID> result;
    std::set<ID> seen;
    for (const auto& raw : array(value)) {
        auto id = identifier(raw);
        require(seen.insert(id).second, "Duplicate identifier");
        result.push_back(std::move(id));
    }
    return result;
}
const Song& song(const NativeSession& session, const ID& id) {
    for (const auto& value : session.project().songs) if (value.id == id) return value;
    invalid("Unknown song");
}
const Song& currentSong(const NativeSession& session) {
    require(session.transport().songId.has_value(), "No current arrangement");
    return song(session, *session.transport().songId);
}
const Track& track(const NativeSession& session, const ID& id, bool current = false) {
    for (const auto& s : session.project().songs) {
        if (current && s.id != session.transport().songId) continue;
        for (const auto& value : s.tracks) if (value.id == id) return value;
    }
    invalid("Unknown track");
}
const AudioClip& clip(const NativeSession& session, const ID& id, bool current = false) {
    for (const auto& s : session.project().songs) {
        if (current && s.id != session.transport().songId) continue;
        for (const auto& t : s.tracks) for (const auto& value : t.clips) if (value.id == id) return value;
    }
    invalid("Unknown item");
}
const Part& region(const NativeSession& session, const ID& id) {
    for (const auto& value : currentSong(session).parts) if (value.id == id) return value;
    invalid("Unknown region");
}
const TimelineMarker* findMarker(const NativeSession& session, const ID& id) {
    const auto& s = currentSong(session);
    if (s.markers) for (const auto& value : *s.markers) if (value.id == id) return &value;
    return nullptr;
}
void requireGridMovement(const NativeSession& session) {
    require(!session.project().timelineMovementLocked.value_or(false), "O movimento no grid está bloqueado pelo cadeado.");
}
void requireMarkerPosition(const NativeSession& session, const TimelineMarker& value) {
    if (const auto* previous = findMarker(session, value.id))
        if (previous->position != value.position) requireGridMovement(session);
}
ID mixerID(const NativeSession& session, const json& value, bool current = false) {
    const auto id = identifier(value);
    if (id == "master") return {};
    (void)track(session, id, current);
    return id;
}
OutputPatch patch(const json& value) {
    object(value, {"firstChannel", "channelCount"});
    return {integer(field(value, "firstChannel")), integer(field(value, "channelCount"))};
}
std::vector<OutputPatch> patches(const json& value) {
    std::vector<OutputPatch> result;
    for (const auto& raw : array(value, 1024)) result.push_back(patch(raw));
    return result;
}
TrackRouting routing(const json& value) {
    object(value, {"receives", "transmitters"});
    TrackRouting result;
    auto decode = [](const json& raw) {
        std::vector<std::optional<ID>> values;
        for (const auto& id : array(raw, 1024)) values.push_back(id.is_null() ? std::nullopt : std::optional<ID>{identifier(id)});
        return values;
    };
    result.receives = decode(field(value, "receives"));
    result.transmitters = decode(field(value, "transmitters"));
    return result;
}
TimecodeSettings timecode(const json& value) {
    object(value, {"mode", "frameRate", "offset", "regionRelative", "midiDestination"});
    TimecodeSettings result;
    result.mode = text(field(value, "mode"));
    result.frameRate = number(field(value, "frameRate"));
    result.offset = number(field(value, "offset"));
    result.regionRelative = boolean(field(value, "regionRelative"));
    result.midiDestination = integer(field(value, "midiDestination"));
    require(result.midiDestination >= 0 && result.midiDestination <= 32, "Invalid MIDI destination");
    return result;
}
ProjectTimeSettings timeSettings(const json& value) {
    object(value, {"divisions", "timebase", "affectsMIDIItems", "affectsAutomationLength"});
    ProjectTimeSettings result;
    result.divisions = integer(field(value, "divisions"));
    const auto mode = text(field(value, "timebase"));
    require(mode == "free" || mode == "relative", "Unknown project timebase");
    result.timebase = mode == "free" ? ProjectTimebase::free : ProjectTimebase::relative;
    result.affectsMIDIItems = boolean(field(value, "affectsMIDIItems"));
    result.affectsAutomationLength = boolean(field(value, "affectsAutomationLength"));
    return result;
}
std::string opaqueObject(const json& value) {
    require(value.is_object(), "Expected an FX/automation state object");
    const auto serialized = value.dump();
    require(serialized.size() <= 32 * 1024 * 1024, "FX/automation state is too large");
    return serialized; // Never reconstruct or strip plugin state, presets or unknown fields.
}
AudioFile audioFile(const json& value) {
    object(value, {"path", "sha256"});
    AudioFile result{text(field(value, "path"))};
    optional(value, "sha256", result.sha256, text);
    return result;
}
MIDIItem midiItem(const json& value) {
    object(value, {"notes", "sourceBPM", "grid"});
    MIDIItem result;
    setting(value, "sourceBPM", result.sourceBPM, number);
    if (value.contains("grid")) {
        const auto& grid = value.at("grid");
        object(grid, {"division", "mode", "swing"});
        setting(grid, "division", result.division, integer);
        setting(grid, "mode", result.mode, text);
        setting(grid, "swing", result.swing, number);
    }
    for (const auto& raw : array(field(value, "notes"))) {
        object(raw, {"id", "start", "length", "pitch", "velocity", "channel"});
        result.notes.push_back({identifier(field(raw, "id")), number(field(raw, "start")),
            number(field(raw, "length")), integer(field(raw, "pitch")), integer(field(raw, "velocity")), integer(field(raw, "channel"))});
    }
    return result;
}
std::vector<double> waveform(const json& value) {
    std::vector<double> result;
    for (const auto& sample : array(value, 2000000)) result.push_back(number(sample));
    return result;
}
AudioClip item(const json& value) {
    object(value, {"id", "name", "startTime", "duration", "sourceOffset", "playbackRate", "muted", "audioFile",
        "gain", "pan", "normalizationGain", "phaseInverted", "fadeIn", "fadeOut", "fadeInCurve", "fadeInSCurve",
        "fadeOutCurve", "fadeOutSCurve", "channelMode", "loopStart", "loopLength", "recordingLane", "timecodeStartOffset",
        "timecodeEndOffset", "fx", "fxBypassed", "text", "midi", "frozenMIDI", "renderedTiming", "pitchSemitones",
        "timecode", "regionOwnerID", "automation", "tempoBasePlaybackRate", "renderedTempo", "separatedStemTracks",
        "waveform", "waveformChannels"});
    AudioClip result;
    result.id = identifier(field(value, "id")); result.name = text(field(value, "name"));
    result.startTime = number(field(value, "startTime")); result.duration = number(field(value, "duration"));
    setting(value, "sourceOffset", result.sourceOffset, number);
    setting(value, "playbackRate", result.playbackRate, number);
    setting(value, "muted", result.muted, boolean);
#define ITEM_OPTIONAL(key, member, decode) optional(value, key, result.member, decode)
    ITEM_OPTIONAL("audioFile", audioFile, audioFile);
    ITEM_OPTIONAL("gain", gain, number); ITEM_OPTIONAL("pan", pan, number);
    ITEM_OPTIONAL("normalizationGain", normalizationGain, number); ITEM_OPTIONAL("phaseInverted", phaseInverted, boolean);
    ITEM_OPTIONAL("fadeIn", fadeIn, number); ITEM_OPTIONAL("fadeOut", fadeOut, number);
    ITEM_OPTIONAL("fadeInCurve", fadeInCurve, number); ITEM_OPTIONAL("fadeInSCurve", fadeInSCurve, number);
    ITEM_OPTIONAL("fadeOutCurve", fadeOutCurve, number); ITEM_OPTIONAL("fadeOutSCurve", fadeOutSCurve, number);
    ITEM_OPTIONAL("channelMode", channelMode, integer); ITEM_OPTIONAL("loopStart", loopStart, number);
    ITEM_OPTIONAL("loopLength", loopLength, number); ITEM_OPTIONAL("recordingLane", recordingLane, integer);
    ITEM_OPTIONAL("timecodeStartOffset", timecodeStartOffset, number); ITEM_OPTIONAL("timecodeEndOffset", timecodeEndOffset, number);
    ITEM_OPTIONAL("fx", fxJSON, opaqueObject); ITEM_OPTIONAL("fxBypassed", fxBypassed, boolean);
    ITEM_OPTIONAL("text", text, text); ITEM_OPTIONAL("midi", midi, midiItem);
    ITEM_OPTIONAL("frozenMIDI", frozenMIDI, boolean); ITEM_OPTIONAL("renderedTiming", renderedTiming, boolean);
    ITEM_OPTIONAL("pitchSemitones", pitchSemitones, number); ITEM_OPTIONAL("timecode", timecode, timecode);
    ITEM_OPTIONAL("regionOwnerID", regionOwnerID, identifier); ITEM_OPTIONAL("automation", automationJSON, opaqueObject);
    ITEM_OPTIONAL("tempoBasePlaybackRate", tempoBasePlaybackRate, number); ITEM_OPTIONAL("renderedTempo", renderedTempo, boolean);
#undef ITEM_OPTIONAL
    if (value.contains("separatedStemTracks")) result.separatedStemTracks = identifiers(value.at("separatedStemTracks"));
    if (value.contains("waveform")) result.waveform = waveform(value.at("waveform"));
    if (value.contains("waveformChannels")) for (const auto& channel : array(value.at("waveformChannels"), 32))
        result.waveformChannels.push_back(waveform(channel));
    return result;
}
Track importedTrack(const json& value) {
    object(value, {"id", "name", "role", "volume", "pan", "mute", "solo", "output", "audioFile", "clips", "patch",
        "color", "inputPatch", "inputMonitoring", "recordingChannels", "recordingFormat", "fx", "automation",
        "midiInput", "midiChannel", "parentTrackID", "secondaryPatch", "outputs", "timecode", "importedTimecodeItems",
        "routing", "stereoLink", "phaseInverted", "heightScale", "clickSound"});
    Track result;
    result.id = identifier(field(value, "id")); result.name = text(field(value, "name"));
    setting(value, "role", result.role.id, identifier);
    setting(value, "volume", result.volume, number); setting(value, "pan", result.pan, number);
    setting(value, "mute", result.mute, boolean); setting(value, "solo", result.solo, boolean);
    setting(value, "output", result.output, integer);
    setting(value, "importedTimecodeItems", result.importedTimecodeItems, boolean);
#define TRACK_OPTIONAL(key, member, decode) optional(value, key, result.member, decode)
    TRACK_OPTIONAL("audioFile", audioFile, audioFile); TRACK_OPTIONAL("patch", patch, patch);
    TRACK_OPTIONAL("color", color, color); TRACK_OPTIONAL("inputPatch", inputPatch, patch);
    TRACK_OPTIONAL("inputMonitoring", inputMonitoring, boolean); TRACK_OPTIONAL("recordingChannels", recordingChannels, integer);
    TRACK_OPTIONAL("recordingFormat", recordingFormat, text); TRACK_OPTIONAL("fx", fxJSON, opaqueObject);
    TRACK_OPTIONAL("automation", automationJSON, opaqueObject); TRACK_OPTIONAL("midiInput", midiInput, integer);
    TRACK_OPTIONAL("midiChannel", midiChannel, integer); TRACK_OPTIONAL("parentTrackID", parentTrackID, identifier);
    TRACK_OPTIONAL("secondaryPatch", secondaryPatch, patch); TRACK_OPTIONAL("outputs", outputs, patches);
    TRACK_OPTIONAL("timecode", timecode, timecode); TRACK_OPTIONAL("routing", routing, routing);
    TRACK_OPTIONAL("phaseInverted", phaseInverted, boolean); TRACK_OPTIONAL("heightScale", heightScale, number);
    TRACK_OPTIONAL("clickSound", clickSound, audioFile);
#undef TRACK_OPTIONAL
    for (const auto& raw : array(field(value, "clips"))) result.clips.push_back(item(raw));
    if (value.contains("stereoLink") && !value.at("stereoLink").is_null()) {
        const auto& link = value.at("stereoLink");
        require(link.is_object(), "Invalid stereo link");
        result.stereoLinkJSON = link.dump();
        result.stereoLinkPartner = identifier(field(link, "partner"));
        result.stereoLinkLeft = boolean(field(link, "left"));
    }
    return result;
}
void itemReferences(const AudioClip& value, const Song& song, const std::set<ID>& availableTracks) {
    if (value.regionOwnerID)
        require(std::any_of(song.parts.begin(), song.parts.end(), [&](const auto& part) { return part.id == *value.regionOwnerID; }),
                "Unknown item owner region");
    for (const auto& id : value.separatedStemTracks) require(availableTracks.count(id), "Unknown separated-stem track");
}
void importedReferences(const std::vector<Track>& tracks, const Song& song) {
    std::set<ID> availableTracks;
    for (const auto& track : song.tracks) availableTracks.insert(track.id);
    for (const auto& track : tracks) availableTracks.insert(track.id);
    for (const auto& track : tracks) {
        if (track.parentTrackID) require(availableTracks.count(*track.parentTrackID), "Unknown parent track");
        if (track.stereoLinkPartner) require(availableTracks.count(*track.stereoLinkPartner), "Unknown stereo-link track");
        if (track.routing) for (const auto& links : {track.routing->receives, track.routing->transmitters})
            for (const auto& id : links) if (id) require(availableTracks.count(*id), "Unknown routing track");
        for (const auto& clip : track.clips) itemReferences(clip, song, availableTracks);
    }
}
TimelineMarker marker(const json& value, const NativeSession& session) {
    object(value, {"id", "name", "position", "color", "tempoBPM", "tempoBeats", "tempoUnit", "tempoTimebase",
        "tempoReferenceBPM", "section", "loopSection", "unifiedRegionID", "sourceRegionID", "regionOwnerID"});
    const auto id = identifier(field(value, "id"));
    auto result = findMarker(session, id) ? *findMarker(session, id) : TimelineMarker{};
    result.id = id; result.name = text(field(value, "name"));
    result.position = number(field(value, "position")); result.color = color(field(value, "color"));
    optional(value, "tempoBPM", result.tempoBPM, number); optional(value, "tempoBeats", result.tempoBeats, integer);
    optional(value, "tempoUnit", result.tempoUnit, integer); optional(value, "tempoTimebase", result.tempoTimebase, text);
    optional(value, "tempoReferenceBPM", result.tempoReferenceBPM, number);
    optional(value, "section", result.section, boolean); optional(value, "loopSection", result.loopSection, boolean);
    optional(value, "unifiedRegionID", result.unifiedRegionID, identifier);
    optional(value, "sourceRegionID", result.sourceRegionID, identifier);
    optional(value, "regionOwnerID", result.regionOwnerID, identifier);
    for (const auto& reference : {result.unifiedRegionID, result.sourceRegionID, result.regionOwnerID})
        if (reference) (void)region(session, *reference);
    const auto* previous = findMarker(session, id);
    require(result.unifiedRegionID == (previous ? previous->unifiedRegionID : std::nullopt)
            && result.sourceRegionID == (previous ? previous->sourceRegionID : std::nullopt),
            "Unified marker links are maintained by region operations");
    return result;
}
RegionSetlist regionSetlist(const json& value) {
    object(value, {"playlists", "selectedId", "autoAdvance", "blocks", "stopAtRegionEnd", "prepareWithoutPlayback",
        "automaticSubplay", "automaticSubplaySeconds", "liveEnabled", "playedLiveRegionIDs", "autoUntilBlockEnd"});
    RegionSetlist result;
    for (const auto& raw : array(field(value, "playlists"), 2048)) {
        object(raw, {"id", "name", "songId", "regionIds"});
        result.playlists.push_back({identifier(field(raw, "id")), text(field(raw, "name")),
            identifier(field(raw, "songId")), identifiers(field(raw, "regionIds"))});
    }
    optional(value, "selectedId", result.selectedId, identifier);
    setting(value, "autoAdvance", result.autoAdvance, boolean);
    setting(value, "autoUntilBlockEnd", result.autoUntilBlockEnd, boolean);
    optional(value, "stopAtRegionEnd", result.stopAtRegionEnd, boolean);
    optional(value, "prepareWithoutPlayback", result.prepareWithoutPlayback, boolean);
    optional(value, "automaticSubplay", result.automaticSubplay, boolean);
    optional(value, "automaticSubplaySeconds", result.automaticSubplaySeconds, number);
    optional(value, "liveEnabled", result.liveEnabled, boolean);
    optional(value, "playedLiveRegionIDs", result.playedLiveRegionIDs, identifiers);
    if (value.contains("blocks") && !value.at("blocks").is_null()) {
        result.blocks.emplace();
        for (const auto& raw : array(value.at("blocks"), 4096)) {
            object(raw, {"id", "songId", "playlistId", "name", "color", "beforeRegionId", "symbol"});
            SetlistBlock block;
            block.id = identifier(field(raw, "id")); block.songId = identifier(field(raw, "songId"));
            block.name = text(field(raw, "name")); block.color = color(field(raw, "color"));
            optional(raw, "playlistId", block.playlistId, identifier);
            optional(raw, "beforeRegionId", block.beforeRegionId, identifier);
            optional(raw, "symbol", block.symbol, boolean);
            result.blocks->push_back(std::move(block));
        }
    }
    return result;
}

enum class Target { none, song, region, section, track, mixer, clip };
enum class Value { none, number, integer, boolean };
struct CommandSpec { const char* name; CommandKind kind; Target target; Value value; };
// Explicit names and argument types. No caller-supplied numeric CommandKind.
const CommandSpec commands[] = {
    {"toggleMultiLoopBypass", CommandKind::toggleMultiLoopBypass, Target::none, Value::none},
    {"queueSection", CommandKind::queueSection, Target::section, Value::none},
    {"cancelSection", CommandKind::cancelSection, Target::none, Value::none},
    {"clipFadeIn", CommandKind::clipFadeIn, Target::clip, Value::number},
    {"clipFadeOut", CommandKind::clipFadeOut, Target::clip, Value::number},
    {"loopStart", CommandKind::loopStart, Target::none, Value::number},
    {"loopEnd", CommandKind::loopEnd, Target::none, Value::number},
    {"escape", CommandKind::escape, Target::none, Value::none},
    {"phase", CommandKind::phase, Target::track, Value::none},
    {"masterMono", CommandKind::masterMono, Target::none, Value::none},
    {"ignoreNext", CommandKind::ignoreNext, Target::none, Value::none},
    {"tempo", CommandKind::tempo, Target::none, Value::number},
    {"beatsPerBar", CommandKind::beatsPerBar, Target::none, Value::integer},
    {"beatUnit", CommandKind::beatUnit, Target::none, Value::integer},
    {"play", CommandKind::play, Target::none, Value::none},
    {"stop", CommandKind::stop, Target::none, Value::none},
    {"next", CommandKind::next, Target::none, Value::none},
    {"previous", CommandKind::previous, Target::none, Value::none},
    {"queue", CommandKind::queue, Target::song, Value::none},
    {"select", CommandKind::select, Target::song, Value::none},
    {"toggleLoop", CommandKind::toggleLoop, Target::none, Value::none},
    {"seek", CommandKind::seek, Target::none, Value::number},
    {"editSeek", CommandKind::editSeek, Target::none, Value::number},
    {"subPlay", CommandKind::subPlay, Target::none, Value::none},
    {"subStop", CommandKind::subStop, Target::none, Value::none},
    {"subSeek", CommandKind::subSeek, Target::none, Value::number},
    {"stopAll", CommandKind::stopAll, Target::none, Value::none},
    {"volume", CommandKind::volume, Target::mixer, Value::number},
    {"pan", CommandKind::pan, Target::mixer, Value::number},
    {"mute", CommandKind::mute, Target::mixer, Value::none},
    {"solo", CommandKind::solo, Target::mixer, Value::none},
    {"selectRegion", CommandKind::selectRegion, Target::region, Value::none},
    {"queueRegion", CommandKind::queueRegion, Target::region, Value::none},
    {"pause", CommandKind::pause, Target::none, Value::none},
    {"clipMute", CommandKind::clipMute, Target::clip, Value::none},
    {"clipGain", CommandKind::clipGain, Target::clip, Value::number},
    {"clipPhase", CommandKind::clipPhase, Target::clip, Value::boolean},
    {"clipPan", CommandKind::clipPan, Target::clip, Value::number},
    {"clipChannelMode", CommandKind::clipChannelMode, Target::clip, Value::integer},
    {"clipNormalization", CommandKind::clipNormalization, Target::clip, Value::number},
    {"clipPitch", CommandKind::clipPitch, Target::clip, Value::number},
    {"clipFadeInCurve", CommandKind::clipFadeInCurve, Target::clip, Value::number},
    {"clipFadeInSCurve", CommandKind::clipFadeInSCurve, Target::clip, Value::number},
    {"clipFadeOutCurve", CommandKind::clipFadeOutCurve, Target::clip, Value::number},
    {"clipFadeOutSCurve", CommandKind::clipFadeOutSCurve, Target::clip, Value::number},
};
bool dispatchCommand(NativeSession& session, const std::string& action, const json& args) {
    const auto found = std::find_if(std::begin(commands), std::end(commands), [&](const auto& spec) { return action == spec.name; });
    if (found == std::end(commands)) return false;
    if (found->target == Target::none) {
        if (found->value == Value::none) object(args, {}); else object(args, {"value"});
    } else {
        if (found->value == Value::none) object(args, {"id"}); else object(args, {"id", "value"});
    }
    Command command{found->kind};
    if (found->target != Target::none) {
        command.target = identifier(field(args, "id"));
        switch (found->target) {
            case Target::song: (void)song(session, command.target); break;
            case Target::region: (void)region(session, command.target); break;
            case Target::section: {
                const auto* target = findMarker(session, command.target);
                require(target && target->section.value_or(false) && !target->tempoBPM, "Unknown section marker");
                break;
            }
            case Target::track: (void)track(session, command.target); break;
            case Target::mixer: command.target = mixerID(session, field(args, "id")); break;
            case Target::clip: (void)clip(session, command.target); break;
            case Target::none: break;
        }
    }
    if (found->value == Value::number) command.value = number(field(args, "value"));
    if (found->value == Value::integer) command.value = integer(field(args, "value"));
    if (found->value == Value::boolean) command.value = boolean(field(args, "value")) ? 1 : 0;
    if (found->kind == CommandKind::volume)
        require(command.value >= 0 && command.value <= std::pow(10., 12. / 20.), "Volume is outside the fader range");
    if (found->kind == CommandKind::pan) require(command.value >= -1 && command.value <= 1, "Invalid pan");
    if (found->kind == CommandKind::seek || found->kind == CommandKind::editSeek || found->kind == CommandKind::subSeek
        || found->kind == CommandKind::loopStart || found->kind == CommandKind::loopEnd)
        require(command.value >= 0 && command.value <= currentSong(session).duration, "Position is outside the arrangement");
    session.command(command);
    return true;
}
} // namespace

// Contract:
//   {"action":"play","args":{}}
//   {"action":"clipGain","args":{"id":"item UUID","value":0.5}}
//   {"action":"setFX","args":{"id":"track UUID or master","fx":{...}}}
// Command names above use {id,value} only when the typed table requires them.
// Edit actions below use named arguments; nested clip/track fields match .jl.
// Markers: setMarker{marker}, setMarkers{markers,removing,retime},
// deleteManualMarker{id}. Timing: setProjectTiming{bpm,beats,unit,settings?}.
// Region edits: resizeRegion{id,start,end}, moveRegion{id,start},
// editRegion{id,name,color,uppercaseName?}, setRegionPitch{id,semitones,tracks,groups}.
// Item edits: moveClip{id,start,destination?}, regionFromClip{id,regionId},
// regionsFromClips{items:[{id,regionId}]}, pasteItems{songId,tracks,moving},
// insertAudioTracks{songId,tracks}, addRecordedClip{id,clip,replacing}.
// Tracks: addTrack{id,name,role}, editTrack{id,name,color}, groupTracks{ids},
// reorderTrack{id,before:null|id}, setTrackRouting{routes:[{id,routing}]},
// setOutputPatch{id,firstChannel,channelCount,slot?}, setOutputPatches{id,patches}.
// setMIDIInput/setMIDIChannel/setRecordingChannels{id,value};
// setInputMonitoring{id,enabled}, setRecording{id,firstChannel,channelCount,format},
// setTimecode{id,settings}, configureRegionSetlist{state}, editMasterColor{color},
// setClipText{id,text}, setClipFXBypass{id,bypassed}, setFX/setClipFX{id,fx}.
// FX/automation objects are opaque and never projected into a reduced schema.
// setFX/setClipFX accept null to remove all state; undo restores the complete state.
// Missing optional marker properties preserve existing values; explicit null clears.
// All mutations go through NativeSession history. Playback uses the engine clock;
// advance/load/save/finishCurrentSong and filesystem/evaluation are not UI actions.
// Returns {state,changed}; "document" additionally returns {document}.
json applySessionAction(NativeSession& session, const json& request) {
    object(request, {"action", "args"});
    finiteJSON(request);
    const auto action = identifier(field(request, "action"));
    const auto& args = field(request, "args");
    require(args.is_object(), "Expected an argument object");
    const auto before = session.revision();
    if (action == "state" || action == "document") {
        object(args, {});
        auto result = json{{"state", session.state()}, {"changed", false}};
        if (action == "document") result["document"] = session.document();
        return result;
    }
    if (action == "undo" || action == "redo") {
        object(args, {});
        const bool changed = action == "undo" ? session.undo() : session.redo();
        return {{"state", session.state()}, {"changed", changed}};
    }
    if (action == "setTimelineMovementLocked") {
        object(args, {"locked"}); const bool locked = boolean(field(args, "locked"));
        if (session.project().timelineMovementLocked.value_or(false) != locked)
            session.edit([=](auto& project) { project.timelineMovementLocked = locked; });
        return {{"state", session.state()}, {"changed", session.revision() != before}};
    }
    if (action == "duplicateTracks") {
        object(args, {"songId", "trackIds"});
        const auto songID = identifier(field(args, "songId"));
        const auto& arrangement = song(session, songID);
        const auto ids = identifiers(field(args, "trackIds"));
        for (const auto& id : ids) require(std::any_of(arrangement.tracks.begin(), arrangement.tracks.end(),
            [&](const auto& value) { return value.id == id; }), "Unknown track in arrangement");
        auto result = duplicateTracks(session.document(), songID, ids, freshIdentifier);
        if (!result.trackIDs.empty()) session.editDocument(result.document);
        return {{"state", session.state()}, {"changed", session.revision() != before},
            {"trackIds", result.trackIDs}, {"trackIdMap", result.trackIDMap}};
    }
    if (action == "setRecordingFormat") {
        object(args, {"id", "format"}); const auto id = identifier(field(args, "id"));
        const auto& target = track(session, id);
        require(target.role.id != "generatedClick" && target.role.id != "chords"
            && target.role.id != "teleprompt" && target.role.id != "teleprompt2"
            && target.role.id != "timecode" && target.role.id != "video", "This track cannot record audio");
        const auto& raw = field(args, "format");
        const auto format = raw.is_null() ? std::optional<std::string>{} : std::optional<std::string>{text(raw)};
        require(!format || *format == "wav" || *format == "wav32" || *format == "mp3", "Invalid recording format");
        if (target.recordingFormat != format) session.edit([=](auto& project) {
            for (auto& s : project.songs) for (auto& t : s.tracks) if (t.id == id) t.recordingFormat = format;
        });
        return {{"state", session.state()}, {"changed", session.revision() != before}};
    }
    if (dispatchCommand(session, action, args)) return {{"state", session.state()}, {"changed", session.revision() != before}};
    std::function<void(Engine&)> edit;
    if (action == "configureRegionSetlist") {
        object(args, {"state"}); const auto state = regionSetlist(field(args, "state"));
        edit = [state](auto& engine) { engine.configureRegionSetlist(state); };
    } else if (action == "setTrackRouting") {
        object(args, {"routes"}); std::vector<std::pair<ID, TrackRouting>> routes; std::set<ID> seen;
        for (const auto& raw : array(field(args, "routes"), 512)) {
            object(raw, {"id", "routing"}); const auto id = identifier(field(raw, "id")); (void)track(session, id);
            require(seen.insert(id).second, "Duplicate routing track"); routes.emplace_back(id, routing(field(raw, "routing")));
        }
        edit = [routes](auto& engine) { engine.setTrackRouting(routes); };
    } else if (action == "setOutputPatch") {
        object(args, {"id", "firstChannel", "channelCount", "slot"});
        const auto id = mixerID(session, field(args, "id"), true);
        const auto first = integer(field(args, "firstChannel")), count = integer(field(args, "channelCount"));
        const auto slot = args.contains("slot") ? integer(args.at("slot")) : 0;
        edit = [=](auto& engine) { engine.setOutputPatch(id, first, count, slot); };
    } else if (action == "setOutputPatches") {
        object(args, {"id", "patches"}); const auto id = mixerID(session, field(args, "id"), true);
        const auto values = patches(field(args, "patches")); edit = [=](auto& engine) { engine.setOutputPatches(id, values); };
    } else if (action == "groupTracks") {
        object(args, {"ids"}); const auto ids = identifiers(field(args, "ids")); for (const auto& id : ids) (void)track(session, id, true);
        edit = [ids](auto& engine) { engine.groupTracks(ids); };
    } else if (action == "reorderTrack") {
        object(args, {"id", "before"}); const auto id = identifier(field(args, "id")); (void)track(session, id, true);
        const auto& raw = field(args, "before"); const auto beforeID = raw.is_null() ? ID{} : identifier(raw);
        if (!beforeID.empty()) (void)track(session, beforeID, true);
        edit = [=](auto& engine) { engine.reorderTrack(id, beforeID); };
    } else if (action == "addTrack") {
        object(args, {"id", "name", "role"}); const auto id = identifier(field(args, "id"));
        const auto name = text(field(args, "name")), role = identifier(field(args, "role"));
        edit = [=](auto& engine) { engine.addTrack(id, name, {role}); };
    } else if (action == "resizeRegion" || action == "moveRegion") {
        requireGridMovement(session);
        if (action == "resizeRegion") object(args, {"id", "start", "end"}); else object(args, {"id", "start"});
        const auto id = identifier(field(args, "id")); (void)region(session, id);
        const auto start = number(field(args, "start"));
        if (action == "resizeRegion") { const auto end = number(field(args, "end")); edit = [=](auto& engine) { engine.resizeRegion(id, start, end); }; }
        else edit = [=](auto& engine) { engine.moveRegion(id, start); };
    } else if (action == "setFX" || action == "setClipFX") {
        object(args, {"id", "fx"}); const bool isClip = action == "setClipFX";
        const auto id = isClip ? identifier(field(args, "id")) : mixerID(session, field(args, "id"));
        if (isClip) (void)clip(session, id);
        const auto& raw = field(args, "fx");
        if (raw.is_null()) {
            session.edit([&](auto& project) {
                if (!isClip && id.empty()) { project.masterFXJSON.reset(); return; }
                for (auto& s : project.songs) for (auto& t : s.tracks) {
                    if (!isClip && t.id == id) { t.fxJSON.reset(); return; }
                    if (isClip) for (auto& c : t.clips) if (c.id == id) { c.fxJSON.reset(); return; }
                }
            });
        } else {
            const auto state = opaqueObject(raw);
            edit = [=](auto& engine) { if (isClip) engine.setClipFX(id, state); else engine.setFX(id, state); };
        }
    } else if (action == "setClipFXBypass") {
        object(args, {"id", "bypassed"}); const auto id = identifier(field(args, "id")); (void)clip(session, id);
        const auto bypassed = boolean(field(args, "bypassed")); edit = [=](auto& engine) { engine.setClipFXBypass(id, bypassed); };
    } else if (action == "setClipText") {
        object(args, {"id", "text"}); const auto id = identifier(field(args, "id")); (void)clip(session, id);
        const auto value = text(field(args, "text")); edit = [=](auto& engine) { engine.setClipText(id, value); };
    } else if (action == "setMIDIInput" || action == "setMIDIChannel" || action == "setRecordingChannels") {
        object(args, {"id", "value"}); const auto id = identifier(field(args, "id")); (void)track(session, id);
        const auto value = integer(field(args, "value"));
        edit = [=](auto& engine) { if (action == "setMIDIInput") engine.setMIDIInput(id, value);
            else if (action == "setMIDIChannel") engine.setMIDIChannel(id, value); else engine.setRecordingChannels(id, value); };
    } else if (action == "setInputMonitoring") {
        object(args, {"id", "enabled"}); const auto id = identifier(field(args, "id")); (void)track(session, id);
        const auto enabled = boolean(field(args, "enabled")); edit = [=](auto& engine) { engine.setInputMonitoring(id, enabled); };
    } else if (action == "setRecording") {
        object(args, {"id", "firstChannel", "channelCount", "format"}); const auto id = identifier(field(args, "id")); (void)track(session, id);
        const auto first = integer(field(args, "firstChannel")), count = integer(field(args, "channelCount"));
        const auto format = text(field(args, "format")); edit = [=](auto& engine) { engine.setRecording(id, first, count, format); };
    } else if (action == "pasteItems" || action == "insertAudioTracks") {
        if (action == "pasteItems") object(args, {"songId", "tracks", "moving"}); else object(args, {"songId", "tracks"});
        const auto id = identifier(field(args, "songId")); (void)song(session, id);
        std::vector<Track> tracks; for (const auto& raw : array(field(args, "tracks"), std::numeric_limits<std::size_t>::max())) tracks.push_back(importedTrack(raw));
        importedReferences(tracks, song(session, id));
        const auto moving = action == "pasteItems" ? boolean(field(args, "moving")) : false;
        if (moving) requireGridMovement(session);
        edit = [=](auto& engine) { if (action == "pasteItems") engine.pasteItems(id, tracks, moving); else engine.insertAudioTracks(id, tracks); };
    } else if (action == "addRecordedClip") {
        object(args, {"id", "clip", "replacing"}); const auto id = identifier(field(args, "id")); (void)track(session, id);
        const auto value = item(field(args, "clip")); const auto replacing = boolean(field(args, "replacing"));
        for (const auto& s : session.project().songs) if (std::any_of(s.tracks.begin(), s.tracks.end(), [&](const auto& t) { return t.id == id; })) {
            std::set<ID> available; for (const auto& t : s.tracks) available.insert(t.id); itemReferences(value, s, available); break;
        }
        edit = [=](auto& engine) { engine.addRecordedClip(id, value, replacing); };
    } else if (action == "setTimecode") {
        object(args, {"id", "settings"}); const auto id = identifier(field(args, "id")); (void)track(session, id);
        const auto settings = timecode(field(args, "settings")); edit = [=](auto& engine) { engine.setTimecode(id, settings); };
    } else if (action == "editTrack") {
        object(args, {"id", "name", "color"}); const auto id = identifier(field(args, "id")); (void)track(session, id);
        const auto name = text(field(args, "name")); const auto rgb = color(field(args, "color"));
        edit = [=](auto& engine) { engine.editTrack(id, name, rgb); };
    } else if (action == "editMasterColor") {
        object(args, {"color"}); const auto rgb = color(field(args, "color")); edit = [=](auto& engine) { engine.editMasterColor(rgb); };
    } else if (action == "setMarker") {
        object(args, {"marker"}); const auto& raw = field(args, "marker");
        object(raw, {"id", "name", "position", "color", "tempoBPM", "tempoBeats", "tempoUnit", "tempoTimebase", "section", "loopSection"});
        const auto value = marker(raw, session);
        requireMarkerPosition(session, value);
        edit = [=](auto& engine) { engine.setMarker(value.id, value.name, value.position, value.color,
            value.tempoBPM, value.tempoBeats, value.tempoUnit, value.tempoTimebase, value.section, value.loopSection); };
    } else if (action == "setMarkers") {
        object(args, {"markers", "removing", "retime"}); std::vector<TimelineMarker> markers; std::set<ID> seen;
        for (const auto& raw : array(field(args, "markers"), 100000)) {
            auto value = marker(raw, session); requireMarkerPosition(session, value);
            require(seen.insert(value.id).second, "Duplicate marker identifier"); markers.push_back(std::move(value));
        }
        const auto removing = identifiers(field(args, "removing"));
        for (const auto& id : removing) { const auto* value = findMarker(session, id); require(value && value->tempoBPM, "Only existing tempo markers may be removed by setMarkers"); }
        const auto retime = boolean(field(args, "retime")); edit = [=](auto& engine) { engine.setMarkers(markers, removing, retime); };
    } else if (action == "setProjectTiming") {
        object(args, {"bpm", "beats", "unit", "settings"}); const auto bpm = number(field(args, "bpm"));
        const auto beats = integer(field(args, "beats")), unit = integer(field(args, "unit"));
        auto settings = currentSong(session).timeSettings; optional(args, "settings", settings, timeSettings);
        edit = [=](auto& engine) { engine.setProjectTiming(bpm, beats, unit, settings); };
    } else if (action == "deleteManualMarker") {
        object(args, {"id"}); const auto id = identifier(field(args, "id")); require(findMarker(session, id), "Unknown marker");
        edit = [=](auto& engine) { engine.deleteManualMarker(id); };
    } else if (action == "setRegionPitch") {
        object(args, {"id", "semitones", "tracks", "groups"}); const auto id = identifier(field(args, "id")); (void)region(session, id);
        const auto semitones = integer(field(args, "semitones")); const auto tracks = identifiers(field(args, "tracks")), groups = identifiers(field(args, "groups"));
        edit = [=](auto& engine) { engine.setRegionPitch(id, semitones, tracks, groups); };
    } else if (action == "editRegion") {
        object(args, {"id", "name", "color", "uppercaseName"}); const auto id = identifier(field(args, "id")); (void)region(session, id);
        const auto name = text(field(args, "name")); const auto rgb = color(field(args, "color"));
        const auto uppercase = args.contains("uppercaseName") ? boolean(args.at("uppercaseName")) : true;
        edit = [=](auto& engine) { engine.editRegion(id, name, rgb, uppercase); };
    } else if (action == "moveClip") {
        requireGridMovement(session);
        object(args, {"id", "start", "destination"}); const auto id = identifier(field(args, "id")); (void)clip(session, id, true);
        const auto start = number(field(args, "start")); ID destination;
        if (args.contains("destination") && !args.at("destination").is_null()) { destination = identifier(args.at("destination")); (void)track(session, destination, true); }
        edit = [=](auto& engine) { engine.moveClip(id, start, destination); };
    } else if (action == "regionFromClip") {
        object(args, {"id", "regionId"}); const auto id = identifier(field(args, "id")); (void)clip(session, id, true);
        const auto regionID = identifier(field(args, "regionId")); edit = [=](auto& engine) { engine.regionFromClip(id, regionID); };
    } else if (action == "regionsFromClips") {
        object(args, {"items"}); std::vector<std::pair<ID, ID>> items; std::set<ID> clips, regions;
        for (const auto& raw : array(field(args, "items"))) {
            object(raw, {"id", "regionId"}); const auto id = identifier(field(raw, "id")), regionID = identifier(field(raw, "regionId"));
            (void)clip(session, id, true); require(clips.insert(id).second && regions.insert(regionID).second, "Duplicate clip/region identifier"); items.emplace_back(id, regionID);
        }
        edit = [=](auto& engine) { engine.regionsFromClips(items); };
    } else invalid("Unknown session action: " + action);
    if (edit) session.editEngine(edit);
    return {{"state", session.state()}, {"changed", session.revision() != before}};
}
}
