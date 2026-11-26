#include "NativeSession.h"
#include <iostream>
#include <cstdlib>
#include <new>
#include <stdexcept>

// Deterministic allocation failures exercise the complete prepare/commit
// boundary, including vector growth after copying the plugin snapshot.
namespace {
bool allocationFailureEnabled = false;
std::size_t allocationsUntilFailure = 0;
std::size_t allocationFailureMinimum = 0;
}
void* operator new(std::size_t size) {
    if (allocationFailureEnabled && size >= allocationFailureMinimum && allocationsUntilFailure-- == 0) throw std::bad_alloc();
    if (void* memory = std::malloc(size ? size : 1)) return memory;
    throw std::bad_alloc();
}
void* operator new[](std::size_t size) { return ::operator new(size); }
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete[](void* memory) noexcept { std::free(memory); }
#if defined(__cpp_sized_deallocation)
void operator delete(void* memory, std::size_t) noexcept { std::free(memory); }
void operator delete[](void* memory, std::size_t) noexcept { std::free(memory); }
#endif

using namespace catlive::native;
static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

static void playbackLoadGuard(const nlohmann::json& document) {
    for (bool subplay : {false, true}) {
        NativeSession session;
        session.loadDocument(document);
        session.command({jaras::CommandKind::volume, "track", 0.7});
        session.command({jaras::CommandKind::play, {}});
        if (subplay) session.command({jaras::CommandKind::subPlay, {}});
        require(session.transport().playing, "fixture must be playing");
        require(!subplay || session.transport().subPlay.playing, "fixture must start subplay");
        const auto before = session.document(), state = session.state();
        bool refused = false;
        try { session.loadDocument(nlohmann::json::array()); }
        catch (const std::runtime_error& error) {
            refused = std::string(error.what()).find("Pare a reprodução") != std::string::npos;
        }
        require(refused, "loading must refuse playback before decoding a new document");
        require(session.document() == before && session.state() == state,
                "refused load preserves transport, document, path, revision and history");
        session.command({jaras::CommandKind::stopAll, {}});
        session.loadDocument(document);
        require(!session.dirty() && !session.undo(), "stopped load clears previous history");
    }
}
static void allocationFailureHistory(const nlohmann::json& document, bool redo) {
    bool reachedSuccess = false;
    std::size_t failures = 0;
    for (std::size_t failAt = 0; failAt < 2048; ++failAt) {
        NativeSession session;
        session.loadDocument(document);
        session.edit([](auto& value) { value.songs[0].tracks[0].fxJSON.reset(); });
        if (redo) require(session.undo(), "prepare redo failure fixture");
        const auto before = session.document(), state = session.state();
        allocationsUntilFailure = failAt;
        allocationFailureEnabled = true;
        bool allocationFailed = false;
        try { if (redo) session.redo(); else session.undo(); }
        catch (const std::bad_alloc&) { allocationFailed = true; }
        catch (...) { allocationFailureEnabled = false; throw; }
        allocationFailureEnabled = false;
        if (!allocationFailed) { reachedSuccess = true; break; }
        ++failures;
        require(session.document() == before && session.state() == state,
                "failed history allocation must preserve complete logical state");
        require(redo ? session.redo() : session.undo(),
                "history remains executable after a failed allocation");
    }
    require(reachedSuccess && failures > 0, "failure sweep must reach a successful history operation");
}
static void allocationFailureLoad(const nlohmann::json& document) {
    auto replacement = document;
    replacement["name"] = "Outro projeto";
    replacement["futurePayload"] = std::string(8192, 'x');
    bool reachedSuccess = false;
    std::size_t failures = 0;
    for (std::size_t failAt = 0; failAt < 2048; ++failAt) {
        NativeSession session;
        session.loadDocument(document);
        session.command({jaras::CommandKind::volume, "track", 0.7});
        const auto before = session.document(), state = session.state();
        allocationsUntilFailure = failAt;
        // The JSON dependency allocates during its noexcept destructor. Target
        // the payload copies, not the dependency's destruction bookkeeping.
        allocationFailureMinimum = 8192;
        allocationFailureEnabled = true;
        bool allocationFailed = false;
        try { session.loadDocument(replacement); }
        catch (const std::bad_alloc&) { allocationFailed = true; }
        catch (...) { allocationFailureEnabled = false; throw; }
        allocationFailureEnabled = false;
        allocationFailureMinimum = 0;
        if (!allocationFailed) { reachedSuccess = true; break; }
        ++failures;
        require(session.document() == before && session.state() == state,
                "load allocation failure preserves the previous engine and original JSON together");
        require(session.undo(), "load allocation failure must preserve existing history");
    }
    require(reachedSuccess && failures >= 2, "failure sweep must cover decode and preserved-original payload copies");
}
static void editDocumentHistory(const nlohmann::json& document) {
    NativeSession session;
    session.loadDocument(document);
    session.command({jaras::CommandKind::editSeek, {}, 3.25});
    session.command({jaras::CommandKind::play, {}});
    session.advance(1.5);
    const auto before = session.document(), transport = session.state()["transport"];
    auto candidate = before;
    auto duplicate = candidate["songs"][0]["tracks"][0];
    duplicate["id"] = "duplicate-track";
    duplicate["name"] = "Piano 2";
    duplicate["clips"][0]["id"] = "duplicate-item";
    duplicate["vendorTrackState"] = {{"collapsed", true}, {"opaque", "future-format"}};
    duplicate["clips"][0]["vendorItemState"] = {{"loopDisplay", "triangular"}};
    candidate["songs"][0]["tracks"].push_back(duplicate);
    const auto revision = session.revision();
    session.editDocument(candidate);
    require(session.revision() == revision + 1 && session.dirty(),
            "full document edit is one committed action");
    require(session.state()["transport"] == transport, "document edit preserves running transport");
    const auto after = session.document();
    require(after["songs"][0]["tracks"][1]["vendorTrackState"] == duplicate["vendorTrackState"]
            && after["songs"][0]["tracks"][1]["clips"][0]["vendorItemState"] == duplicate["clips"][0]["vendorItemState"],
            "document edit preserves unknown fields on newly created tracks and items");
    require(session.undo() && session.document() == before && !session.undo(),
            "document edit has exactly one undo entry");
    require(session.state()["transport"] == transport, "document undo preserves running transport");
    require(session.redo() && session.document() == after, "redo restores all new unknown fields");
    auto anotherProject = candidate;
    anotherProject["id"] = "another-project";
    const auto state = session.state();
    bool refused = false;
    try { session.editDocument(anotherProject); }
    catch (const std::exception&) { refused = true; }
    require(refused && session.document() == after && session.state() == state,
            "document edit refuses a different project without mutation");
}
static void boundedHistory(const nlohmann::json& document) {
    constexpr std::size_t MiB = 1024 * 1024;
    {
        auto extended = document;
        extended["futurePayload"] = std::string(16 * MiB, 'x');
        NativeSession session;
        session.loadDocument(extended);
        extended.clear();
        for (int i = 0; i < 45; ++i)
            session.command({jaras::CommandKind::volume, "track", 0.01 * i});
        int undos = 0;
        while (session.undo()) ++undos;
        require(undos == 40, "shared unknown JSON must be charged once and retain 40 small edits");
        require(session.project().songs[0].tracks[0].volume == 0.04,
                "entry cap discards oldest actions, keeping the most recent ones");
        int redos = 0;
        while (session.redo()) ++redos;
        require(redos == 40, "all retained actions can be redone");
    }
    {
        NativeSession session;
        session.loadDocument(document);
        session.edit([=](auto& value) {
            auto& track = value.songs[0].tracks[0];
            auto& clip = track.clips[0];
            clip.waveform.assign(32 * MiB / sizeof(double), 0.2);
            clip.waveformChannels.assign(2, std::vector<double>(8 * MiB / sizeof(double), 0.3));
            track.fxJSON = "{\"inserted\":[\"External:kontakt\"],\"externalPlugins\":[{\"state\":\""
                + std::string(16 * MiB, 'a') + "\"}]}";
            for (int i = 1; i <= 100; ++i)
                clip.midi->notes.push_back({"note-" + std::to_string(i), 0, 1, 60, 100, 1});
        });
        for (int i = 2; i <= 7; ++i)
            session.command({jaras::CommandKind::volume, "track", 0.1 * i});
        int undos = 0;
        while (session.undo()) ++undos;
        require(undos == 3, "waveform, MIDI and opaque FX payloads enforce the combined 256 MiB budget");
        require(session.project().songs[0].tracks[0].volume == 0.4,
                "memory pressure retains the most recent undo snapshots");
        const auto& clip = session.project().songs[0].tracks[0].clips[0];
        require(clip.waveform.front() == 0.2 && clip.waveformChannels[0].front() == 0.3
                && clip.midi->notes.size() == 101, "retained history preserves full waveform and MIDI data");
        int redos = 0;
        while (session.redo()) ++redos;
        require(redos == 3, "memory-limited history preserves the redo chain");
    }
    {
        // One unusually large original document must not make every edit
        // irreversible. The last action remains available above the soft cap.
        auto oversized = document;
        oversized["futurePayload"] = std::string(257 * MiB, 'z');
        NativeSession session;
        session.loadDocument(oversized);
        oversized.clear();
        for (double volume : {0.2, 0.3, 0.4})
            session.command({jaras::CommandKind::volume, "track", volume});
        require(session.undo(), "retain the latest undo even above the memory budget");
        require(session.project().songs[0].tracks[0].volume == 0.3 && !session.undo(),
                "oversized history evicts older snapshots only");
        require(session.redo() && session.project().songs[0].tracks[0].volume == 0.4,
                "oversized last action can still be redone");
    }
}

int main() {
    jaras::Project project;
    project.id = "project"; project.name = "Sessão";
    jaras::Song song;
    song.id = "song"; song.name = "Música"; song.duration = 60;
    jaras::Track track;
    track.id = "track"; track.name = "Piano";
    track.fxJSON = R"({"inserted":["External:kontakt"],"externalPlugins":[{"id":"kontakt","format":"VST3","state":"library-state-base64","bypassed":false,"parameters":{"gain":0.7}}]})";
    jaras::AudioClip item;
    item.id = "item"; item.name = "MIDI"; item.duration = 8;
    item.midi = jaras::MIDIItem{{{"note", 0, 1, 60, 100, 1}}};
    item.loopStart = 0; item.loopLength = 4;
    track.clips.push_back(item);
    song.tracks.push_back(track); project.songs.push_back(song);
    project.setlists.push_back({"setlist", "Show", {"song"}});
    auto document = ProjectCodec::encode(project);
    document["futureExtension"] = {{"enabled", true}};
    NativeSession session;
    session.loadDocument(document);
    require(!session.dirty(), "loading must not mark a document edited");
    require(session.project().songs[0].tracks[0].fxJSON.has_value(), "fixture must load an actual effect chain");
    const auto original = session.document();
    session.edit([](auto& value) { value.songs[0].tracks[0].fxJSON.reset(); });
    require(!session.project().songs[0].tracks[0].fxJSON, "delete effect");
    require(session.undo(), "effect removal is undoable");
    require(nlohmann::json::parse(*session.project().songs[0].tracks[0].fxJSON)
                ["externalPlugins"][0]["state"] == "library-state-base64", "undo restores the loaded plugin state");
    require(session.document() == original, "undo restores opaque plugin state and extension fields");
    require(session.redo(), "effect removal is redoable");
    require(!session.project().songs[0].tracks[0].fxJSON, "redo removes effect again");
    session.undo();
    const auto beforeFailure = session.document();
    const auto revision = session.revision();
    bool failed = false;
    try { session.edit([](auto& value) { value.songs[0].tracks[0].clips[0].duration = -1; }); }
    catch (const std::exception&) { failed = true; }
    require(failed && session.document() == beforeFailure && session.revision() == revision,
            "invalid edit is atomic, preserves state and history");
    session.command({jaras::CommandKind::editSeek, {}, 3.125});
    require(session.transport().editPosition == 3.125, "edit cursor preserves sub-frame precision");
    session.command({jaras::CommandKind::volume, "track", 0.4});
    require(session.project().songs[0].tracks[0].volume == 0.4, "mixer command applies");
    session.undo();
    require(session.project().songs[0].tracks[0].volume == 1, "mixer command is undoable");
    require(session.transport().editPosition == 3.125, "undo preserves edit cursor");
    require(session.document()["futureExtension"]["enabled"] == true, "unknown fields survive editing");
    playbackLoadGuard(document);
    allocationFailureHistory(document, false);
    allocationFailureHistory(document, true);
    allocationFailureLoad(document);
    editDocumentHistory(document);
    boundedHistory(document);
    std::cout << "NATIVE_SESSION_HISTORY_OPAQUE_FX_ATOMIC_EDIT_CURSOR_MEMORY_PLAYBACK_OK\n";
}
