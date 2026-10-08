#include "../../Core/Transport/Engine.hpp"
#include <cmath>
#include <iostream>
#include <stdexcept>
using namespace jaras;

static void expect(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
static void near(double actual, double expected, const char* message) {
    if (std::abs(actual - expected) > 1e-8)
        throw std::runtime_error(std::string(message) + ": " + std::to_string(actual) + " vs " + std::to_string(expected));
}
static AudioClip audio(ID id, double start, double duration, std::optional<ID> owner = {}) {
    AudioClip result;
    result.id = std::move(id); result.name = result.id;
    result.startTime = start; result.duration = duration;
    result.audioFile = AudioFile{"Stems/source.wav"};
    result.sourceOffset = 2; result.gain = 0.5; result.regionOwnerID = std::move(owner);
    return result;
}
static AudioClip midi(ID id, double start, double duration, std::optional<ID> owner) {
    auto result = audio(std::move(id), start, duration, std::move(owner));
    result.audioFile.reset(); result.sourceOffset = 0;
    result.midi = MIDIItem{{{"note", 2, 8, 64, 101, 3}}, 120};
    return result;
}
static Project fixture(bool initialized = true) {
    Project project; project.id = "onset-project"; project.name = "Onset ownership";
    Song song; song.id = "song"; song.name = "Show"; song.duration = 100;
    song.regionOwnershipInitialized = initialized;
    song.parts = {{"a", "A", 0, 16}, {"b", "B", 10, 30}, {"group", "Unified", 0, 30}};
    song.parts[0].parentRegionID = "group"; song.parts[1].parentRegionID = "group";
    song.tracks = {Track{"track", "Audio", {"other"}}};
    project.songs = {song};
    return project;
}
static const AudioClip& clip(const Engine& engine, const ID& id) {
    for (const auto& track : engine.currentSong()->tracks)
        for (const auto& item : track.clips) if (item.id == id) return item;
    throw std::runtime_error("Missing test clip: " + id);
}
static void crossingOwner(const Engine& engine, const ID& id, const char* message) {
    const auto& item = clip(engine, id);
    expect(item.regionOwnerID == "a", message);
    near(item.startTime, 8, "ownership acquisition preserves the item onset");
    near(item.duration, 30, "ownership acquisition preserves the tail beyond both songs and their parent");
    near(item.sourceOffset, 2, "ownership acquisition preserves source trim");
}

int main() {
    try {
        {
            auto project = fixture(false);
            project.songs[0].tracks[0].clips = {audio("legacy", 8, 30)};
            Engine engine; engine.loadProject(project);
            crossingOwner(engine, "legacy", "legacy initialization assigns a crossing tail from its onset inside A");
            expect(engine.currentSong()->regionOwnershipInitialized, "legacy initialization records that membership was established");
            engine.moveRegion("group", 40);
            near(clip(engine, "legacy").startTime, 48, "the complete crossing item follows its assigned unified song");
            near(clip(engine, "legacy").duration, 30, "moving the unified region preserves outgoing tail length");
        }
        {
            Engine engine; engine.loadProject(fixture());
            auto next = engine.project();
            next.songs[0].tracks[0].clips.push_back(audio("created", 8, 30));
            engine.applyProjectEdit(next);
            crossingOwner(engine, "created", "new project-edit items acquire A despite their tail crossing B and the parent end");
        }
        {
            Engine engine; engine.loadProject(fixture());
            Track imported{"imported", "Imported audio", {"other"}};
            imported.clips = {audio("imported-tail", 8, 30)};
            engine.insertAudioTracks("song", {imported});
            crossingOwner(engine, "imported-tail", "audio import acquires its onset song instead of requiring full containment");
        }
        for (bool viaProjectEdit : {false, true}) {
            auto project = fixture();
            project.songs[0].tracks[0].clips = {audio("moved", 50, 30)};
            Engine engine; engine.loadProject(project);
            if (viaProjectEdit) {
                auto next = engine.project(); next.songs[0].tracks[0].clips[0].startTime = 8;
                engine.applyProjectEdit(next);
            } else engine.moveClip("moved", 8);
            crossingOwner(engine, "moved", "explicit item movement acquires the song at the new onset");
            engine.moveClip("moved", 50);
            expect(!clip(engine, "moved").regionOwnerID, "explicit movement back outside all regions detaches the item");
        }
        {
            auto project = fixture();
            project.songs[0].tracks[0].clips = {audio("owned", 8, 30, "b"), audio("loose", 9, 30)};
            Engine engine; engine.loadProject(project);
            expect(clip(engine, "owned").regionOwnerID == "b", "initialized reload preserves explicit membership even when the onset lies in A");
            expect(!clip(engine, "loose").regionOwnerID, "initialized reload preserves an intentionally loose crossing item");
            engine.moveRegion("group", 40);
            near(clip(engine, "owned").startTime, 48, "persisted foreign membership still follows its unified group");
            near(clip(engine, "loose").startTime, 9, "moving a region leaves its loose item stationary");
            engine.loadProject(engine.project());
            engine.moveRegion("group", 0);
            auto next = engine.project(); next.name = "Unrelated project edit";
            engine.applyProjectEdit(next);
            expect(!clip(engine, "loose").regionOwnerID, "moving a region over a loose onset, reloading, and unrelated edits never recapture it");
            near(clip(engine, "loose").startTime, 9, "loose audio remains stationary after the region returns");
            auto resized = engine.project(); resized.songs[0].tracks[0].clips[0].duration = 40;
            engine.applyProjectEdit(resized);
            expect(clip(engine, "owned").regionOwnerID == "b", "resizing an item without moving its onset preserves its explicit owner");
        }
        {
            auto project = fixture(); project.songs[0].parts.clear();
            project.songs[0].tracks[0].clips = {audio("wrapped", 8, 30)};
            Engine engine; engine.loadProject(project);
            auto next = engine.project(); next.songs[0].parts.push_back({"wrapper", "New region", 5, 10});
            engine.applyProjectEdit(next);
            expect(clip(engine, "wrapped").regionOwnerID == "wrapper", "a new region wraps an existing loose onset even when the tail exceeds its end");
            engine.moveRegion("wrapper", 20);
            near(clip(engine, "wrapped").startTime, 23, "an item acquired by a new wrapper follows that region");
            near(clip(engine, "wrapped").duration, 30, "new-wrapper attachment preserves the full tail");
        }
        {
            Engine engine; engine.loadProject(fixture());
            engine.addRecordedClip("track", audio("recorded-audio", 8, 30));
            crossingOwner(engine, "recorded-audio", "recorded audio acquires its onset song when finalized across the next song");
        }
        {
            Engine engine; engine.loadProject(fixture());
            const auto captured = midi("captured-owned", 8, 30, "a");
            engine.moveRegion("group", 40);
            engine.addRecordedClip("track", captured);
            const auto& item = clip(engine, "captured-owned");
            expect(item.regionOwnerID == "a", "MIDI finalization retains the owner frozen at capture even after its region moves away");
            near(item.startTime, 8, "MIDI finalization does not relocate the performance when its owner moved");
            expect(item.midi && item.midi->notes.size() == 1, "MIDI finalization preserves recorded notes");
            near(item.midi->notes[0].start, 2, "MIDI finalization preserves captured note-on beats");
            near(item.midi->notes[0].length, 8, "MIDI finalization preserves captured note duration");
            engine.loadProject(engine.project());
            expect(clip(engine, "captured-owned").regionOwnerID == "a", "captured owner remains frozen after reload");
        }
        {
            Engine engine; engine.loadProject(fixture());
            const auto captured = midi("captured-loose", 48, 30, {});
            engine.moveRegion("group", 40);
            engine.addRecordedClip("track", captured);
            expect(!clip(engine, "captured-loose").regionOwnerID, "MIDI finalization preserves frozen nil when a region moves over the capture onset");
            engine.loadProject(engine.project()); engine.moveRegion("group", 0);
            expect(!clip(engine, "captured-loose").regionOwnerID, "captured nil remains loose after reload and region departure");
            near(clip(engine, "captured-loose").startTime, 48, "a region passing over a MIDI take never transports it");
        }
        for (bool batch : {false, true}) {
            auto project = fixture();
            TimelineMarker owned{"owned-marker", "Foreign owner", 8, 0}; owned.regionOwnerID = "b";
            TimelineMarker loose{"loose-marker", "Loose", 9, 0};
            project.songs[0].markers = std::vector<TimelineMarker>{owned, loose};
            Engine engine; engine.loadProject(project);
            if (batch) {
                owned.name = "Edited owner"; owned.regionOwnerID.reset();
                loose.name = "Edited loose"; loose.regionOwnerID = "a";
                engine.setMarkers({owned, loose});
            } else {
                engine.setMarker("owned-marker", "Edited owner", 8, 0);
                engine.setMarker("loose-marker", "Edited loose", 9, 0);
            }
            for (const auto& marker : *engine.currentSong()->markers) {
                if (marker.id == "owned-marker") expect(marker.regionOwnerID == "b", "same-position marker edits preserve persisted foreign ownership");
                if (marker.id == "loose-marker") expect(!marker.regionOwnerID, "same-position marker edits preserve initialized nil ownership");
            }
        }
        std::cout << "REGION_ONSET_LEGACY_NEW_IMPORT_MOVE_WRAP_RECORDING_AND_PERSISTENCE_OK\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
