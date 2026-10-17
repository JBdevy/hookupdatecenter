#include "SessionActions.h"
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <functional>

using namespace catlive::native;
using nlohmann::json;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
json request(const char* name, json args = json::object()) { return {{"action", name}, {"args", std::move(args)}}; }
NativeSession fixture() {
    jaras::Project project; project.id = "project"; project.name = "Guilherme QA";
    jaras::Song song; song.id = "song"; song.name = "Real arrangement"; song.duration = 120;
    jaras::Track track; track.id = "track"; track.name = "Piano";
    track.fxJSON = json{{"inserted", json::array({"External:kontakt"})},
        {"externalPlugins", {{"kontakt", {{"stateBase64", "AAECA/+/instrument-library-state=="},
        {"preset", "Biblioteca alterada"}, {"futureVendorData", json::array({1, 2, 3})}}}}}}.dump();
    jaras::AudioClip clip; clip.id = "clip"; clip.name = "Piano.wav"; clip.startTime = 3; clip.duration = 4;
    clip.audioFile = jaras::AudioFile{"Stems/Piano.wav"}; clip.loopStart = 0; clip.loopLength = 4;
    clip.fxJSON = json{{"inserted", json::array({"EQ"})}, {"futureState", {{"binary", "unchanged=="}}}}.dump();
    track.clips.push_back(clip); song.tracks.push_back(track);
    jaras::Track another; another.id = "track2"; another.name = "Guitarra"; song.tracks.push_back(another);
    song.parts.push_back({"region", "Primeira", 0, 20, 0x223344});
    song.parts.push_back({"region2", "Segunda", 30, 60, 0x445566});
    song.markers = std::vector<jaras::TimelineMarker>{{"marker", "Refrão", 8, 0x556677}};
    project.songs.push_back(song);
    project.setlists.push_back({"setlist", "Show", {"song"}});
    auto document = ProjectCodec::encode(project); document["futureExtension"] = {{"keep", true}};
    NativeSession session; session.loadDocument(document); return session;
}
void rejected(NativeSession& session, const json& value) {
    const auto state = session.state(), document = session.document();
    bool failed = false;
    try { (void)applySessionAction(session, value); } catch (const std::exception&) { failed = true; }
    check(failed, "malformed or forbidden request must fail");
    check(session.state() == state && session.document() == document,
        "failed request changed document, transport, revision or history");
}
void malformedRequestsAreAtomic() {
    auto session = fixture();
    applySessionAction(session, request("loopStart", {{"value", 1}}));
    applySessionAction(session, request("loopEnd", {{"value", 12}}));
    applySessionAction(session, request("toggleLoop"));
    rejected(session, json::array());
    rejected(session, {{"action", "play"}});
    rejected(session, {{"action", 15}, {"args", json::object()}});
    rejected(session, request("command", {{"kind", 15}}));
    rejected(session, request("eval", {{"script", "anything"}}));
    rejected(session, request("open", {{"path", "/tmp/any.jl"}}));
    rejected(session, request("advance", {{"seconds", 1}}));
    rejected(session, request("select", {{"id", "missing"}}));
    rejected(session, request("selectRegion", {{"id", "missing"}}));
    rejected(session, request("clipGain", {{"value", 0.5}}));
    rejected(session, request("clipGain", {{"id", "clip"}, {"value", "0.5"}}));
    rejected(session, request("clipGain", {{"id", "clip"}, {"value", std::numeric_limits<double>::infinity()}}));
    rejected(session, request("clipPhase", {{"id", "clip"}, {"value", 1}}));
    rejected(session, request("setInputMonitoring", {{"id", "track"}, {"enabled", "false"}}));
    rejected(session, request("beatsPerBar", {{"value", 3.5}}));
    rejected(session, request("beatUnit", {{"value", 3}}));
    rejected(session, request("tempo", {{"value", 600}}));
    rejected(session, request("volume", {{"id", "master"}, {"value", -1}}));
    rejected(session, request("seek", {{"value", -1}}));
    rejected(session, request("play", {{"unused", true}}));
    rejected(session, request("setFX", {{"id", "track"}, {"fx", "{}"}}));
    rejected(session, request("setFX", {{"id", "missing"}, {"fx", json::object()}}));
    rejected(session, request("setFX", {{"id", "track"}, {"fx", {{"gain", std::numeric_limits<double>::quiet_NaN()}}}}));
    rejected(session, request("setMarker", {{"marker", {{"id", "new"}, {"name", "Bad"}, {"position", "5"}, {"color", 0}}}}));
    rejected(session, request("setMarker", {{"marker", {{"id", "new"}, {"name", "Bad"}, {"position", 5}, {"color", 0}, {"regionOwnerID", "missing"}}}}));
    rejected(session, request("resizeRegion", {{"id", "region"}, {"start", 5}, {"end", 4}}));
    rejected(session, request("groupTracks", {{"ids", json::array({"track", "track"})}}));
    rejected(session, request("moveClip", {{"id", "clip"}, {"start", 9}, {"destination", "missing"}}));
    rejected(session, request("setTrackRouting", {{"routes", json::array({
        {{"id", "track"}, {"routing", {{"receives", json::array()}, {"transmitters", json::array({"track2"})}}}},
        {{"id", "track2"}, {"routing", {{"receives", json::array()}, {"transmitters", json::array({"track"})}}}},
    })}}));
    check(!session.dirty() && !session.state()["canUndo"].get<bool>(), "transport or rejected actions dirtied project");
}
void fxRemovalAndRestoreKeepsEveryOpaqueField() {
    auto session = fixture(); const auto original = session.document();
    const auto result = applySessionAction(session, request("setFX", {{"id", "track"}, {"fx", nullptr}}));
    check(result["changed"] == true && session.dirty(), "FX removal must be an edit");
    check(!session.project().songs[0].tracks[0].fxJSON, "FX removal failed");
    applySessionAction(session, request("undo"));
    check(session.document() == original, "undo lost opaque plugin state or unknown project fields");
    applySessionAction(session, request("redo"));
    check(!session.project().songs[0].tracks[0].fxJSON, "redo failed");
    applySessionAction(session, request("undo"));
    applySessionAction(session, request("setClipFX", {{"id", "clip"}, {"fx", nullptr}}));
    applySessionAction(session, request("undo"));
    check(session.document() == original, "item FX undo lost state");
    const auto replacement = json{{"inserted", json::array({"External:vendor"})},
        {"externalPlugins", {{"vendor", {{"raw", "AQAAA=="}, {"unknownNested", {{"keep", "unchanged"}}}}}}}};
    applySessionAction(session, request("setFX", {{"id", "master"}, {"fx", replacement}}));
    check(json::parse(*session.project().masterFXJSON) == replacement, "dispatcher reduced opaque FX state");
}
void regionMovementPreservesOwnershipAndUndo() {
    auto session = fixture(); const auto original = session.document();
    applySessionAction(session, request("moveRegion", {{"id", "region"}, {"start", 80}}));
    const auto& song = session.project().songs[0];
    check(song.parts[0].startTime == 80 && song.parts[0].endTime == 100, "region move failed");
    check(song.tracks[0].clips[0].startTime == 83, "owned item did not move with region");
    check(song.markers->at(0).position == 88, "owned marker did not move with region");
    check(song.parts[1].startTime == 30, "unrelated region moved");
    applySessionAction(session, request("undo"));
    check(session.document() == original, "region undo was not atomic");
}
void timingEditsRetainEngineTransportAndHistory() {
    auto session = fixture();
    applySessionAction(session, request("editSeek", {{"value", 8}}));
    applySessionAction(session, request("setProjectTiming", {{"bpm", 240}, {"beats", 4}, {"unit", 4},
        {"settings", {{"divisions", 4}, {"timebase", "relative"}, {"affectsMIDIItems", true}, {"affectsAutomationLength", true}}}}));
    check(session.transport().editPosition == 4 && session.transport().position == 4,
        "timing edit dropped the engine's transport changes");
    check(session.project().songs[0].tracks[0].clips[0].startTime == 1.5, "relative tempo did not retime items");
    check(session.state()["canUndo"] == true, "timing edit has no history");
    applySessionAction(session, request("undo"));
    check(session.project().songs[0].bpm == 120, "timing undo failed");
}
void nestedItemImportRejectsBadTypesAndPreservesFX() {
    auto session = fixture();
    auto track = session.document()["songs"][0]["tracks"][0];
    track["clips"][0]["id"] = "copied-clip";
    track["clips"][0]["startTime"] = 12.25;
    auto bad = track; bad["clips"][0]["duration"] = "4";
    rejected(session, request("pasteItems", {{"songId", "song"}, {"tracks", json::array({bad})}, {"moving", false}}));
    bad = track; bad["clips"][0]["fxBypassed"] = 1;
    rejected(session, request("pasteItems", {{"songId", "song"}, {"tracks", json::array({bad})}, {"moving", false}}));
    applySessionAction(session, request("pasteItems", {{"songId", "song"}, {"tracks", json::array({track})}, {"moving", false}}));
    const auto& clips = session.project().songs[0].tracks[0].clips;
    check(clips.size() == 2 && clips[1].startTime == 12.25, "paste item placement differs");
    check(json::parse(*clips[1].fxJSON) == track["clips"][0]["fx"], "paste lost item FX fields");
    check(clips[1].loopLength == clips[0].loopLength, "paste lost repeat period");
    applySessionAction(session, request("undo"));
    check(session.project().songs[0].tracks[0].clips.size() == 1, "paste was not one undo step");
}
void mixerAndMarkerActionsAreUndoableAndValidateBatch() {
    auto session = fixture();
    applySessionAction(session, request("volume", {{"id", "track"}, {"value", 0.3}}));
    applySessionAction(session, request("undo"));
    check(session.project().songs[0].tracks[0].volume == 1, "volume undo failed");
    const auto markers = json::array({{{"id", "tempo"}, {"name", "Tempo"}, {"position", 10}, {"color", 0x333333},
        {"tempoBPM", 140}, {"tempoBeats", 4}, {"tempoUnit", 4}, {"tempoTimebase", "free"}}});
    auto invalidMarkers = markers; invalidMarkers.push_back(markers[0]);
    rejected(session, request("setMarkers", {{"markers", invalidMarkers}, {"removing", json::array()}, {"retime", false}}));
    applySessionAction(session, request("setMarkers", {{"markers", markers}, {"removing", json::array()}, {"retime", false}}));
    check(session.project().songs[0].markers->size() == 2, "tempo marker creation failed");
    applySessionAction(session, request("deleteManualMarker", {{"id", "marker"}}));
    check(session.project().songs[0].markers->size() == 1, "manual marker removal failed");
    applySessionAction(session, request("undo"));
    check(session.project().songs[0].markers->size() == 2, "marker removal undo failed");
}
void duplicateWholeTrackHasFreshIDsAndOneUndo() {
    auto session = fixture();
    auto document = session.document();
    auto& source = document["songs"][0]["tracks"][0];
    source["fx"] = {{"inserted", json::array({"External:kontakt"})},
        {"externalPlugins", json::array({{{"id", "kontakt"}, {"componentState", "AAAB+/=="},
            {"controllerState", "library/instrument edited"}, {"vendorFuture", {1, 2, 3}}}})}};
    source["futureTrackState"] = {{"nested", "preserved"}};
    source["clips"][0]["futureItemState"] = "preserved too";
    session.loadDocument(document);
    applySessionAction(session, request("play")); session.advance(1);
    const auto original = session.document();
    const auto result = applySessionAction(session, request("duplicateTracks", {{"songId", "song"}, {"trackIds", {"track"}}}));
    check(result["changed"] == true && result["trackIds"].size() == 1, "duplicate result missing selection");
    const auto duplicated = session.document();
    const auto& tracks = duplicated["songs"][0]["tracks"];
    check(tracks.size() == 3 && tracks[0] == original["songs"][0]["tracks"][0], "original changed during duplicate");
    check(tracks[1]["id"] == result["trackIds"][0] && tracks[1]["id"] != "track", "duplicate has no fresh identity");
    check(tracks[1]["clips"][0]["id"] != "clip", "item identity reused");
    check(tracks[1]["futureTrackState"] == tracks[0]["futureTrackState"]
        && tracks[1]["clips"][0]["futureItemState"] == "preserved too", "duplicate lost unknown state");
    check(tracks[1]["fx"]["externalPlugins"][0]["componentState"] == "AAAB+/=="
        && tracks[1]["fx"]["externalPlugins"][0]["controllerState"] == "library/instrument edited", "plugin snapshot lost");
    check(session.transport().playing && session.transport().position == 1, "duplication interrupted transport");
    applySessionAction(session, request("undo"));
    check(session.document() == original && !session.state()["canUndo"].get<bool>(), "duplication is not a single undo");
    applySessionAction(session, request("redo"));
    check(session.document() == duplicated, "redo changed IDs or plugin state");
    rejected(session, request("duplicateTracks", {{"songId", "song"}, {"trackIds", {"missing"}}}));
}
void gridLockBlocksGeometryButKeepsNamesColorsAndTempo() {
    auto session = fixture();
    check(session.state()["timelineMovementLocked"] == false, "legacy project must start unlocked");
    applySessionAction(session, request("setTimelineMovementLocked", {{"locked", true}}));
    const auto locked = session.document();
    check(locked["timelineMovementLocked"] == true && session.state()["timelineMovementLocked"] == true, "lock state was not saved");
    NativeSession reopened; reopened.loadDocument(locked);
    check(reopened.project().timelineMovementLocked == true, "lock lost at project reopen");
    rejected(session, request("moveClip", {{"id", "clip"}, {"start", 9}}));
    rejected(session, request("moveRegion", {{"id", "region"}, {"start", 80}}));
    rejected(session, request("resizeRegion", {{"id", "region"}, {"start", 1}, {"end", 20}}));
    rejected(session, request("setMarker", {{"marker", {{"id", "marker"}, {"name", "Refrão"}, {"position", 9}, {"color", 0x123456}}}}));
    applySessionAction(session, request("editRegion", {{"id", "region"}, {"name", "Nome novo"}, {"color", 0x123456}}));
    applySessionAction(session, request("setMarker", {{"marker", {{"id", "marker"}, {"name", "Nome novo"}, {"position", 8}, {"color", 0x123456}}}}));
    applySessionAction(session, request("setMarker", {{"marker", {{"id", "tempo"}, {"name", "Tempo"}, {"position", 10}, {"color", 0x333333}, {"tempoBPM", 140}}}}));
    applySessionAction(session, request("setMarker", {{"marker", {{"id", "tempo"}, {"name", "Tempo"}, {"position", 10}, {"color", 0x333333}, {"tempoBPM", 150}}}}));
    rejected(session, request("setMarker", {{"marker", {{"id", "tempo"}, {"name", "Tempo"}, {"position", 11}, {"color", 0x333333}, {"tempoBPM", 150}}}}));
    applySessionAction(session, request("clipFadeIn", {{"id", "clip"}, {"value", 0.5}}));
    check(session.project().songs[0].tracks[0].clips[0].fadeIn == 0.5, "lock must not disable item sound controls");
    applySessionAction(session, request("setTimelineMovementLocked", {{"locked", false}}));
    applySessionAction(session, request("moveClip", {{"id", "clip"}, {"start", 9}}));
    check(session.project().songs[0].tracks[0].clips[0].startTime == 9, "unlock did not restore item movement");
}
void recordingFormatOverrideDoesNotChangeInputAndCanFollowAdvanced() {
    auto session = fixture();
    applySessionAction(session, request("setRecording", {{"id", "track"}, {"firstChannel", 7}, {"channelCount", 1}, {"format", "wav"}}));
    for (const auto* format : {"wav32", "mp3", "wav"}) {
        applySessionAction(session, request("setRecordingFormat", {{"id", "track"}, {"format", format}}));
        const auto& track = session.project().songs[0].tracks[0];
        check(track.recordingFormat == format && track.inputPatch->firstChannel == 7
            && track.inputPatch->channelCount == 1, "format override changed input routing");
    }
    rejected(session, request("setRecordingFormat", {{"id", "track"}, {"format", "wav24"}}));
    applySessionAction(session, request("setRecordingFormat", {{"id", "track"}, {"format", nullptr}}));
    check(!session.project().songs[0].tracks[0].recordingFormat, "follow Advanced must clear the per-track override");
    applySessionAction(session, request("undo"));
    check(session.project().songs[0].tracks[0].recordingFormat == "wav", "recording format cannot be undone");
    for (const auto* role : {"video", "timecode"}) {
        auto special = fixture(); auto document = special.document();
        document["songs"][0]["tracks"][1]["role"] = role;
        document["songs"][0]["tracks"][1]["name"] = std::string(role) == "video" ? "Video" : "Timecode";
        special.loadDocument(document);
        rejected(special, request("setRecordingFormat", {{"id", "track2"}, {"format", "mp3"}}));
    }
}
}
int main() {
    const std::pair<const char*, std::function<void()>> tests[] = {
        {"atomic malformed requests", malformedRequestsAreAtomic},
        {"opaque FX undo/redo", fxRemovalAndRestoreKeepsEveryOpaqueField},
        {"region ownership movement", regionMovementPreservesOwnershipAndUndo},
        {"relative timing transport", timingEditsRetainEngineTransportAndHistory},
        {"typed item paste", nestedItemImportRejectsBadTypesAndPreservesFX},
        {"mixer and markers", mixerAndMarkerActionsAreUndoableAndValidateBatch},
        {"complete track duplication", duplicateWholeTrackHasFreshIDsAndOneUndo},
        {"grid movement lock", gridLockBlocksGeometryButKeepsNamesColorsAndTempo},
        {"recording format override", recordingFormatOverrideDoesNotChangeInputAndCanFollowAdvanced},
    };
    for (const auto& test : tests) {
        try { test.second(); std::cout << "PASS " << test.first << '\n'; }
        catch (const std::exception& error) { std::cerr << "FAIL " << test.first << ": " << error.what() << '\n'; return 1; }
    }
    std::cout << "SESSION_ACTIONS_9_GROUPS_PASSED\n";
}
