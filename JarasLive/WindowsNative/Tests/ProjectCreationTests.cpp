#include "ProjectCreation.h"
#include "ProjectCodec.h"
#include "Identifier.h"
#include <fstream>
#include <functional>
#include <iostream>
#include <set>
#include <stdexcept>

using namespace catlive::native;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
std::function<std::string()> factory() {
    return [index = 0]() mutable { return "new-id-" + std::to_string(++index); };
}
void thirtyTwoInputsMatchMacDocumentAndSessionIntent() {
    const auto result = createRecordingProject("Guilherme — REC", defaultRecordingChannels, factory());
    const auto& root = result.document;
    const auto decoded = ProjectCodec::decode(root);
    check(decoded.songs.size() == 1 && decoded.setlists.size() == 1 && decoded.songs[0].tracks.size() == 32,
        "REC project does not contain one 32-track song and one setlist.");
    const auto& song = decoded.songs[0];
    check(song.name == "Guilherme — REC" && song.duration == 300 && song.bpm == 120 && song.beatsPerBar == 4 && song.beatUnit == 4,
        "New recording project differs from Mac timing defaults.");
    check(song.timeSettings && song.timeSettings->timebase == jaras::ProjectTimebase::relative &&
        song.timeSettings->divisions == 4 && !song.timeSettings->affectsMIDIItems && song.timeSettings->affectsAutomationLength,
        "REC project changed empty-project timebase defaults.");
    check(decoded.masterColor == 0x414141 && !decoded.masterFXJSON, "Master defaults differ from Mac.");
    check(decoded.setlists[0].songIds == std::vector<std::string>{song.id}, "Setlist does not point to the recording song.");
    check(decoded.createdAt == decoded.updatedAt && decoded.createdAt.size() == 20 && decoded.createdAt.back() == 'Z',
        "Creation timestamps are missing or not UTC ISO 8601.");
    check(result.armedTrackIDs.size() == 32, "Not all recording tracks have transient arm intent.");
    std::set<std::string> identities{decoded.id, song.id, decoded.setlists[0].id};
    for (std::size_t index = 0; index < song.tracks.size(); ++index) {
        const auto& track = song.tracks[index];
        const auto& raw = root["songs"][0]["tracks"][index];
        check(identities.insert(track.id).second && result.armedTrackIDs[index] == track.id, "Track IDs/arm intent are not independent and ordered.");
        check(track.inputPatch && track.inputPatch->firstChannel == static_cast<int>(index + 1) && track.inputPatch->channelCount == 1,
            "Mono input sequence skipped, repeated or clamped an input channel.");
        check(track.recordingChannels == 1 && track.inputMonitoring == false && !track.recordingFormat,
            "REC routing enabled monitoring or overrode Advanced recording format.");
        check(track.outputs && track.outputs->size() == 1 && track.outputs->at(0).firstChannel == 0 && track.outputs->at(0).channelCount == 2,
            "A recording track does not feed Master.");
        check(track.role.id == "other" && track.color == 0x828282 && track.volume == 1 && track.pan == 0 && !track.mute && !track.solo,
            "Track appearance/mixer defaults differ from Mac.");
        check(track.clips.empty() && !track.fxJSON && !track.parentTrackID && !track.midiInput && !track.stereoLinkPartner,
            "New recording track contains unrelated material or routing.");
        check(!raw.contains("armed") && !raw.contains("recordArmed") && !raw.contains("recordingFormat"),
            "Session arming or Advanced preference leaked into the project schema.");
    }
    check(song.tracks.front().name == "Pista 01" && song.tracks[8].name == "Pista 09" && song.tracks.back().name == "Pista 32",
        "Track names are not consistently numbered.");
}
void channelBoundsAndLocalization() {
    const auto mono = createRecordingProject("Mono", 1, factory(), "Track");
    check(mono.armedTrackIDs.size() == 1 && mono.document["songs"][0]["tracks"][0]["name"] == "Track 01",
        "Single channel or localized prefix failed.");
    const auto maximum = createRecordingProject("REC128", maximumRecordingChannels, factory(), "Pista");
    const auto& tracks = maximum.document["songs"][0]["tracks"];
    check(tracks.size() == 128 && maximum.armedTrackIDs.size() == 128 && tracks[127]["name"] == "Pista 128" &&
        tracks[127]["inputPatch"]["firstChannel"] == 128, "Maximum channel setup was truncated to stereo or 32 channels.");
    check(ProjectCodec::encode(ProjectCodec::decode(maximum.document), maximum.document) == maximum.document,
        "Generated project changes when encoded/decoded again.");
}
void invalidRequestsHaveNoPartialResult() {
    const auto reject = [](const std::function<void()>& call) {
        bool rejected = false;
        try { call(); } catch (const std::exception&) { rejected = true; }
        check(rejected, "Invalid REC project creation was accepted.");
    };
    reject([&] { (void)createRecordingProject("REC", 0, factory()); });
    reject([&] { (void)createRecordingProject("REC", 129, factory()); });
    reject([&] { (void)createRecordingProject("", 32, factory()); });
    reject([&] { (void)createRecordingProject(" \t\n", 32, factory()); });
    reject([&] { (void)createRecordingProject("REC", 32, factory(), ""); });
    reject([&] { (void)createRecordingProject("REC", 32, {}); });
    reject([&] { (void)createRecordingProject("REC", 32, [] { return "same"; }); });
    reject([&] { (void)createRecordingProject("REC", 32, [] { return ""; }); });
    reject([&] { (void)createRecordingProject("REC", 1, [index = 0]() mutable {
        return ++index == 1 ? "AABBCCDD-0011-2233-4455-66778899AABB" : "aabbccdd00112233445566778899aabb";
    }); });
}
} // namespace
int main(int argc, char** argv) {
    int passed = 0, failed = 0;
    const auto test = [&](const char* name, const std::function<void()>& body) {
        try { body(); ++passed; std::cout << "PASS " << name << '\n'; }
        catch (const std::exception& error) { ++failed; std::cerr << "FAIL " << name << ": " << error.what() << '\n'; }
    };
    test("32-input REC project matches Mac defaults and transient arming", thirtyTwoInputsMatchMacDocumentAndSessionIntent);
    test("1 to 128 channels, localization and portable document roundtrip", channelBoundsAndLocalization);
    test("invalid names, counts and ID factories cannot create partial projects", invalidRequestsHaveNoPartialResult);
    if (argc == 3 && std::string(argv[1]) == "--write-fixture") test("export portable REC fixture for Mac decoder verification", [&] {
        const auto result = createRecordingProject("REC 32 — Windows", 32, freshIdentifier);
        std::ofstream output(std::filesystem::u8path(argv[2]), std::ios::binary);
        output << result.document.dump(2);
        check(static_cast<bool>(output), "Could not write requested portable fixture.");
    });
    std::cout << passed << " passed, " << failed << " failed\n";
    return failed ? 1 : 0;
}
