#include "TrackDuplication.h"
#include "ProjectCodec.h"
#include <algorithm>
#include <functional>
#include <iostream>
#include <set>
#include <stdexcept>

using namespace catlive::native;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
json track(const std::string& identity, const std::string& parent = {}) {
    json value{{"id", identity}, {"name", identity}, {"role", "keys"}, {"clips", json::array()}};
    if (!parent.empty()) value["parentTrackID"] = parent;
    return value;
}
json project(json tracks) {
    return {{"id", "project"}, {"name", "Track copy test"}, {"minimumJarasVersion", "1.0.0"},
        {"songs", json::array({{{"id", "song"}, {"name", "Show"}, {"duration", 120}, {"tracks", std::move(tracks)},
            {"parts", json::array({{{"id", "region"}, {"name", "Region"}, {"startTime", 0}, {"endTime", 120}}})}}})},
        {"futureDocumentField", {{"literal", "track"}}}};
}
std::function<std::string()> factory() {
    return [counter = 0]() mutable { return "fresh-" + std::to_string(++counter); };
}
const json& find(const json& document, const std::string& identity) {
    for (const auto& value : document["songs"][0]["tracks"]) if (value["id"] == identity) return value;
    throw std::runtime_error("Track not found: " + identity);
}
std::vector<std::string> order(const json& document) {
    std::vector<std::string> result;
    for (const auto& value : document["songs"][0]["tracks"]) result.push_back(value["id"]);
    return result;
}
void originalsUnchanged(const json& original, const json& result) {
    for (const auto& value : original["songs"][0]["tracks"])
        check(find(result, value["id"]) == value, "An original track was changed.");
    check(original["futureDocumentField"] == result["futureDocumentField"], "Unknown project state was lost.");
}
json band() { return {{"id", "shared-band"}, {"frequency", 824.25}, {"gain", -3.2}, {"q", 1.9}, {"futureShape", "shared-band"}}; }
json fx() {
    return {{"instrumentID", "plugin"}, {"inserted", json::array({"Instruments", "EQ", "Native:native", "External:plugin"})},
        {"bands", json::array({band()})},
        {"instances", json::array({{{"id", "native"}, {"kind", "EQ"}, {"settings", {
            {"inserted", json::array({"EQ"})}, {"bands", json::array({band()})}, {"futureNativeState", "native"}}}}})},
        {"externalPlugins", json::array({{{"id", "plugin"}, {"classID", "00112233445566778899AABBCCDDEEFF"},
            {"name", "Kontakt"}, {"path", "plugin"}, {"componentState", "AAECA/+/instrument-library-state=="},
            {"controllerState", "plugin"}, {"futureVendorData", {{"id", "native"}, {"instrumentID", "plugin"}}}}})},
        {"futureSettings", {{"id", "shared-band"}, {"preserve", json::array({1, "plugin", nullptr})}}}};
}
json automation() {
    auto envelope = [](const std::string& identity, json target) {
        return json{{"id", identity}, {"name", identity}, {"target", target}, {"defaultValue", .3},
            {"enabled", true}, {"futureEnvelope", identity}, {"points", json::array({{
                {"id", identity + "-point"}, {"time", 3.125}, {"value", .75}, {"shape", "smooth"}, {"futureCurve", identity}}})}};
    };
    return {{"mode", "latch"}, {"enabled", true}, {"lanesVisible", true}, {"envelopes", json::array({
        envelope("base-envelope", {{"kind", "nativeFX"}, {"native", {{"effect", "EQ"}, {"band", "shared-band"}, {"key", "eqGain"}}}}),
        envelope("native-envelope", {{"kind", "nativeFX"}, {"native", {{"effect", "Native:native"}, {"band", "shared-band"}, {"key", "eqGain"}}}}),
        envelope("external-envelope", {{"kind", "externalFX"}, {"plugin", "plugin"}, {"parameter", 4096}})
    })}};
}
json richTrack() {
    auto value = track("track");
    value["name"] = "Piano completo";
    value["color"] = 0x45aaff;
    value["volume"] = .73; value["pan"] = -.24; value["phaseInverted"] = true;
    value["heightScale"] = .5; value["mute"] = false; value["solo"] = true;
    value["inputPatch"] = {{"firstChannel", 3}, {"channelCount", 2}};
    value["outputs"] = json::array({{{"firstChannel", 5}, {"channelCount", 2}}});
    value["midiInput"] = 2; value["midiChannel"] = 7; value["inputMonitoring"] = true;
    value["recordingChannels"] = 2; value["recordingFormat"] = "wav32";
    value["futureTrackState"] = {{"id", "plugin"}, {"theme", "track"}};
    value["fx"] = fx(); value["automation"] = automation();
    auto itemFX = fx(); itemFX.erase("instrumentID"); itemFX["inserted"] = json::array({"EQ", "Native:native", "External:plugin"});
    itemFX["externalPlugins"][0]["futureVendorData"].erase("instrumentID");
    value["clips"] = json::array({{
        {"id", "item"}, {"name", "Audio"}, {"startTime", 8.125}, {"duration", 12.25}, {"sourceOffset", 3.5},
        {"playbackRate", .997}, {"audioFile", {{"path", "Stems/plugin.wav"}, {"sha256", "plugin"}}},
        {"gain", .64}, {"pan", .2}, {"phaseInverted", true}, {"fadeIn", .125}, {"fadeOut", 2.4},
        {"fadeInCurve", -.25}, {"fadeOutSCurve", .5}, {"fadeTimelineStart", 7.5}, {"fadeTimelineDuration", 13.2},
        {"loopStart", 2.5}, {"loopLength", 3.75}, {"regionOwnerID", "region"},
        {"waveform", json::array({.1, .3, .7})}, {"fx", itemFX}, {"automation", automation()},
        {"futureItemState", {{"id", "item"}, {"raw", "plugin"}}}
    }});
    return value;
}
void completeTrackAndOpaqueState() {
    const auto original = project(json::array({richTrack(), track("other")}));
    const auto before = original;
    auto result = duplicateTracks(original, "song", {"track"}, factory());
    check(original == before && result.trackIDs.size() == 1, "Duplication mutated input or returned wrong selection.");
    originalsUnchanged(original, result.document);
    const auto& source = find(original, "track");
    const auto& copy = find(result.document, result.trackIDMap.at("track"));
    check(order(result.document) == std::vector<std::string>({"track", result.trackIDs[0], "other"}), "Copy is not immediately after source.");
    auto unchangedSource = source, unchangedCopy = copy;
    for (const auto* key : {"id", "fx", "automation", "clips"}) { unchangedSource.erase(key); unchangedCopy.erase(key); }
    check(unchangedSource == unchangedCopy, "Mixer, routing, input or unknown track settings changed.");
    const auto& originalFX = source["fx"]; const auto& copiedFX = copy["fx"];
    check(copiedFX["instrumentID"] == originalFX["instrumentID"], "Instrument identity was remapped.");
    check(copiedFX["futureSettings"] == originalFX["futureSettings"], "Unknown FX state was rewritten.");
    auto originalPlugin = originalFX["externalPlugins"][0], copiedPlugin = copiedFX["externalPlugins"][0];
    check(originalPlugin["id"] != copiedPlugin["id"], "External plugin instance was shared.");
    originalPlugin.erase("id"); copiedPlugin.erase("id");
    check(originalPlugin == copiedPlugin, "Plugin component/controller/vendor state changed.");
    const auto baseBand = copiedFX["bands"][0]["id"], nestedBand = copiedFX["instances"][0]["settings"]["bands"][0]["id"];
    check(baseBand != "shared-band" && nestedBand != "shared-band" && baseBand != nestedBand, "EQ-band ownership was shared.");
    const auto nativeKey = "Native:" + copiedFX["instances"][0]["id"].get<std::string>();
    const auto pluginID = copiedFX["externalPlugins"][0]["id"].get<std::string>();
    check(copiedFX["inserted"] == json::array({"Instruments", "EQ", nativeKey, "External:" + pluginID}), "FX chain order/references changed.");
    const auto& envelopes = copy["automation"]["envelopes"];
    check(envelopes[0]["target"]["native"]["band"] == baseBand && envelopes[1]["target"]["native"]["band"] == nestedBand &&
        envelopes[1]["target"]["native"]["effect"] == nativeKey && envelopes[2]["target"]["plugin"] == pluginID,
        "Automation no longer addresses its copied effect/band/plugin.");
    for (std::size_t index = 0; index < envelopes.size(); ++index) {
        check(envelopes[index]["id"] != source["automation"]["envelopes"][index]["id"] &&
            envelopes[index]["points"][0]["id"] != source["automation"]["envelopes"][index]["points"][0]["id"], "Envelope identities were shared.");
        check(envelopes[index]["points"][0]["time"] == 3.125 && envelopes[index]["points"][0]["shape"] == "smooth", "Envelope timing/shape changed.");
    }
    const auto& sourceItem = source["clips"][0]; const auto& item = copy["clips"][0];
    auto itemA = sourceItem, itemB = item;
    for (const auto* key : {"id", "fx", "automation"}) { itemA.erase(key); itemB.erase(key); }
    check(itemA == itemB && item["id"] != sourceItem["id"], "Item media, trim, fades, loops or region ownership changed.");
    check(item["fx"]["externalPlugins"][0]["id"] != copiedFX["externalPlugins"][0]["id"], "Track and item share copied plugin identity.");
    check(item["automation"]["envelopes"][2]["target"]["plugin"] == item["fx"]["externalPlugins"][0]["id"], "Item automation addressed the track plugin.");
    check(item["automation"]["envelopes"][1]["target"]["native"]["band"] == item["fx"]["instances"][0]["settings"]["bands"][0]["id"], "Item automation addressed the track EQ band.");
    result.document["songs"][0]["tracks"][1]["fx"]["externalPlugins"][0]["componentState"] = "edited independently";
    originalsUnchanged(original, result.document);
}
void midiAndCrossTrackReferences() {
    auto source = track("midi");
    source["clips"] = json::array({{{"id", "midi-item"}, {"name", "Keys"}, {"startTime", 2}, {"duration", 8},
        {"sourceOffset", 1.25}, {"fadeIn", .5}, {"fadeOut", 1.5}, {"separatedStemTracks", json::array({"stem", "outside"})},
        {"midi", {{"sourceBPM", 96.5}, {"notes", json::array({{{"id", "note"}, {"start", .25}, {"length", .75}, {"pitch", 66}, {"velocity", 91}, {"channel", 4}}})},
            {"futureCC", json::array({{{"id", "note"}, {"controller", 7}, {"value", 96}}})}}}}});
    const auto original = project(json::array({source, track("stem"), track("outside")}));
    const auto result = duplicateTracks(original, "song", {"midi", "stem"}, factory());
    const auto& copy = find(result.document, result.trackIDMap.at("midi"))["clips"][0];
    check(copy["midi"]["notes"][0]["id"] != "note", "MIDI note identity was shared.");
    auto a = source["clips"][0]["midi"]["notes"][0], b = copy["midi"]["notes"][0]; a.erase("id"); b.erase("id");
    check(a == b && copy["midi"]["futureCC"] == source["clips"][0]["midi"]["futureCC"], "MIDI content or unknown events changed.");
    check(copy["separatedStemTracks"] == json::array({result.trackIDMap.at("stem"), "outside"}), "Stem references were indiscriminately rewritten.");
    originalsUnchanged(original, result.document);
}
void folderOrderAndRoutingFromBothEndpoints() {
    auto input = track("input"), folder = track("folder"), child = track("child", "folder"), nested = track("nested", "folder"), leaf = track("leaf", "nested"), output = track("output");
    input["routing"] = {{"transmitters", json::array({"child"})}};
    output["routing"] = {{"receives", json::array({"folder"})}};
    child["routing"] = {{"transmitters", json::array({nullptr, "nested"})}, {"futureRoute", "child"}};
    child["outputs"] = json::array({{{"firstChannel", -1}, {"channelCount", 2}}});
    const auto original = project(json::array({input, folder, child, nested, leaf, output}));
    const auto result = duplicateTracks(original, "song", {"folder", "child", "folder"}, factory());
    const auto& map = result.trackIDMap;
    check(map.size() == 4, "Folder selection omitted descendants or duplicated an overlapping selection twice.");
    check(order(result.document) == std::vector<std::string>({"input", "folder", "child", "nested", "leaf", map.at("folder"), map.at("child"), map.at("nested"), map.at("leaf"), "output"}), "Folder copy split an existing hierarchy.");
    check(find(result.document, map.at("child"))["parentTrackID"] == map.at("folder") &&
        find(result.document, map.at("leaf"))["parentTrackID"] == map.at("nested"), "Folder parents were not remapped.");
    const auto& copiedChild = find(result.document, map.at("child"));
    check(copiedChild["routing"]["receives"] == json::array({"input"}), "Incoming connection stored at the other endpoint was lost.");
    check(copiedChild["routing"]["transmitters"] == json::array({nullptr, map.at("nested")}), "Internal route/null slot was not preserved.");
    check(find(result.document, map.at("folder"))["routing"]["transmitters"] == json::array({"output"}), "Outgoing connection stored at the other endpoint was lost.");
    originalsUnchanged(original, result.document);
    const auto member = duplicateTracks(original, "song", {"child"}, factory());
    check(find(member.document, member.trackIDs[0])["parentTrackID"] == "folder", "An independently copied member left its group.");
    check(order(member.document)[3] == member.trackIDs[0], "Member copy was not next to its original.");
}
void stereoPairAndUnlinkState() {
    auto left = track("left", "folder"), right = track("right", "folder");
    left["inputPatch"] = {{"firstChannel", 1}, {"channelCount", 1}};
    right["inputPatch"] = {{"firstChannel", 2}, {"channelCount", 1}};
    left["stereoLink"] = {{"partner", "right"}, {"left", true}, {"original", {{"name", "Before link"}, {"routing", {{"transmitters", json::array({"right"})}}}}}};
    right["stereoLink"] = {{"partner", "left"}, {"left", false}, {"original", {{"name", "Before link R"}, {"routing", {{"receives", json::array({"left"})}}}}}};
    const auto original = project(json::array({track("folder"), left, right, track("tail")}));
    const auto result = duplicateTracks(original, "song", {"left"}, factory());
    const auto& map = result.trackIDMap;
    check(map.size() == 2 && order(result.document) == std::vector<std::string>({"folder", "left", "right", map.at("left"), map.at("right"), "tail"}), "Stereo pair copy was split or incomplete.");
    const auto& copiedLeft = find(result.document, map.at("left"));
    check(copiedLeft["parentTrackID"] == "folder" && copiedLeft["stereoLink"]["partner"] == map.at("right"), "Stereo pair/group reference changed.");
    check(copiedLeft["stereoLink"]["original"]["routing"]["transmitters"] == json::array({map.at("right")}), "Unlink would restore references to the original pair.");
    originalsUnchanged(original, result.document);
}
void regionPitchAndMultiLoopRules() {
    auto original = project(json::array({track("folder"), track("child", "folder"), track("other")}));
    auto& part = original["songs"][0]["parts"][0];
    part["pitchTrackIDs"] = json::array({"child", "other"}); part["pitchGroupIDs"] = json::array({"folder"});
    part["multiLoops"] = json::array({{{"id", "loop"}, {"name", "Loop"}, {"marker1", "start"}, {"marker2", "end"}, {"fadeSeconds", 2},
        {"tracks", json::array({{{"id", "child"}, {"gain", .6}, {"mute", true}, {"solo", false}, {"autoFader", true}, {"futureRule", "child"}},
            {{"id", "other"}, {"gain", .9}}})}}});
    const auto result = duplicateTracks(original, "song", {"folder"}, factory());
    const auto& copy = result.document["songs"][0]["parts"][0];
    check(copy["pitchTrackIDs"] == json::array({"child", "other", result.trackIDMap.at("child")}) &&
        copy["pitchGroupIDs"] == json::array({"folder", result.trackIDMap.at("folder")}), "Explicit region pitch targeting omitted copied tracks.");
    check(copy["multiLoops"][0]["tracks"].size() == 3, "Multi-loop rules were not copied once.");
    auto expectedRule = part["multiLoops"][0]["tracks"][0]; expectedRule["id"] = result.trackIDMap.at("child");
    check(copy["multiLoops"][0]["tracks"][2] == expectedRule, "Multi-loop gain/mute/auto-fader state changed.");
    auto nilPitch = original; nilPitch["songs"][0]["parts"][0]["pitchTrackIDs"] = nullptr; nilPitch["songs"][0]["parts"][0].erase("pitchGroupIDs");
    const auto nilCopy = duplicateTracks(nilPitch, "song", {"child"}, factory());
    check(nilCopy.document["songs"][0]["parts"][0]["pitchTrackIDs"].is_null() && !nilCopy.document["songs"][0]["parts"][0].contains("pitchGroupIDs"), "All-tracks pitch selection became an explicit list.");
    originalsUnchanged(original, result.document);
}
void legacyPluginDictionaryAndUnknownFields() {
    auto source = track("track");
    source["fx"] = {{"inserted", json::array({"External:legacy"})}, {"externalPlugins", {{"legacy", {{"componentState", "legacy"}, {"future", {{"id", "legacy"}}}}}}}};
    source["automation"] = automation(); source["automation"]["envelopes"] = json::array({source["automation"]["envelopes"][2]});
    source["automation"]["envelopes"][0]["target"]["plugin"] = "legacy";
    const auto original = project(json::array({source}));
    const auto result = duplicateTracks(original, "song", {"track"}, factory());
    const auto& copy = find(result.document, result.trackIDs[0]);
    const auto pluginID = copy["fx"]["externalPlugins"].begin().key();
    check(pluginID != "legacy" && copy["fx"]["externalPlugins"].begin().value() == source["fx"]["externalPlugins"]["legacy"], "Legacy plugin state was lost or rewritten.");
    check(copy["fx"]["inserted"] == json::array({"External:" + pluginID}) && copy["automation"]["envelopes"][0]["target"]["plugin"] == pluginID, "Legacy plugin references were not remapped.");
}
void specialTracksAndNoSelection() {
    auto click = track("click"); click["role"] = "generatedClick"; click["name"] = "Click";
    auto video = track("video"); video["role"] = "video"; video["name"] = "Video";
    const auto original = project(json::array({click, video, track("standard")}));
    for (const auto& selection : {std::vector<std::string>{}, std::vector<std::string>{"click", "video", "missing", "master"}}) {
        const auto result = duplicateTracks(original, "song", selection, {});
        check(result.document == original && result.trackIDs.empty(), "Special/no selection duplicated a singleton track.");
    }
    const auto result = duplicateTracks(original, "song", {"click", "standard"}, factory());
    check(result.trackIDs.size() == 1 && result.trackIDMap.count("standard"), "Mixed selection did not retain only standard tracks.");
    check(duplicateTracks(original, "missing-song", {"standard"}, {}).document == original, "Missing song changed the project.");
}
void validationAndFailedIDFactoryAreAtomic() {
    const auto original = project(json::array({richTrack()})), before = original;
    (void)ProjectCodec::decode(original);
    for (const auto& make : {std::function<std::string()>{}, std::function<std::string()>{[] { return "track"; }},
        std::function<std::string()>{[] { return ""; }}, std::function<std::string()>{[] { return "always-the-same"; }}}) {
        bool rejected = false;
        try { (void)duplicateTracks(original, "song", {"track"}, make); } catch (const std::exception&) { rejected = true; }
        check(rejected && original == before, "Bad ID factory was accepted or partially changed input.");
    }
    auto invalid = original; invalid["songs"][0]["tracks"][0]["routing"] = {{"transmitters", json::array({"track"})}};
    bool rejected = false;
    try { (void)duplicateTracks(invalid, "song", {"track"}, factory()); } catch (const std::exception&) { rejected = true; }
    check(rejected, "Invalid source routing was copied.");
    auto many = json::array(); std::vector<std::string> selection;
    for (int index = 0; index < 257; ++index) { selection.push_back("track-" + std::to_string(index)); many.push_back(track(selection.back())); }
    const auto full = project(many);
    rejected = false;
    try { (void)duplicateTracks(full, "song", selection, factory()); } catch (const std::exception&) { rejected = true; }
    check(rejected && full["songs"][0]["tracks"].size() == 257, "Track count overflow was partially committed.");
}
} // namespace
int main(int argc, char** argv) {
    int passed = 0, failed = 0;
    const auto test = [&](const char* name, const std::function<void()>& body) {
        try { body(); ++passed; std::cout << "PASS " << name << '\n'; }
        catch (const std::exception& error) { ++failed; std::cerr << "FAIL " << name << ": " << error.what() << '\n'; }
    };
    test("complete track, item, FX state and automation retain independent identities", completeTrackAndOpaqueState);
    test("MIDI notes, media and selected stem references copy independently", midiAndCrossTrackReferences);
    test("folder trees and one-sided routing connections are preserved", folderOrderAndRoutingFromBothEndpoints);
    test("stereo pairs retain order, group and unlink routing", stereoPairAndUnlinkState);
    test("region pitch and multi-loop track rules include copies", regionPitchAndMultiLoopRules);
    test("legacy plugin dictionaries retain opaque state", legacyPluginDictionaryAndUnknownFields);
    test("master and special singleton tracks cannot be duplicated", specialTracksAndNoSelection);
    test("invalid factories, routing and track limits fail atomically", validationAndFailedIDFactoryAreAtomic);
    if (argc > 1) test("existing project copies a populated track without changing originals", [&] {
        const auto original = ProjectCodec::read(std::filesystem::u8path(argv[1]));
        for (const auto& song : original["songs"]) {
            for (const auto& source : song["tracks"]) {
                const auto role = source.value("role", std::string());
                if (role == "generatedClick" || role == "timecode" || role == "video" || role == "teleprompt" || role == "teleprompt2" || role == "chords" || source.value("clips", json::array()).empty()) continue;
                const auto result = duplicateTracks(original, song["id"], {source["id"]}, factory());
                check(!result.trackIDs.empty(), "Existing track was not copied.");
                for (std::size_t index = 0; index < original["songs"].size(); ++index) {
                    const auto& copiedSong = result.document["songs"][index];
                    for (const auto& oldTrack : original["songs"][index]["tracks"]) {
                        const auto found = std::find_if(copiedSong["tracks"].begin(), copiedSong["tracks"].end(), [&](const json& value) { return value["id"] == oldTrack["id"]; });
                        check(found != copiedSong["tracks"].end() && *found == oldTrack, "Original real-project track changed.");
                    }
                }
                (void)ProjectCodec::decode(result.document);
                return;
            }
        }
        throw std::runtime_error("Fixture has no populated standard track.");
    });
    std::cout << passed << " passed, " << failed << " failed\n";
    return failed ? 1 : 0;
}
