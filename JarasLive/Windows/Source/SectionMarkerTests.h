#pragma once
#include "FloatingControlTests.h"
#include "MarkerEditing.h"
#include "PartsPanel.h"
#include "ProjectMigration.h"

namespace catlive::sectionMarkerTests {
using floatingControlTests::require;
inline String binary(const String &key, const String &value) {
    auto terminated = value.toUTF8();
    return "<BIN " + key + "\n" + Base64::toBase64(terminated.getAddress(), value.getNumBytesAsUTF8() + 1) + "\n>";
}
inline MigratedProject read(const File &directory, const String &body) {
    const auto file = directory.getNonexistentChildFile("section-import", ".rpp");
    require(file.replaceWithText("<REAPER_PROJECT 0.1 \"7.0\" 1\nTEMPO 120 4 4\n" + body + "\n>\n"),
            "Cannot write section import fixture");
    return readReaperProject(file);
}
inline jaras::TimelineMarker typed(const jaras::Song &song, const String &name, double position) {
    jaras::TimelineMarker marker{uuid(), utf8(name), position, 0x51ef93};
    return markerEditing::prepare(song, marker);
}
template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Typed section prefixes populate Parts, persist clean names and drive real queued section jumps", [&] {
        auto project = floatingControlTests::fixture();
        auto &song = project.songs.front(); song.parts.resize(1); song.parts.front().endTime = 30;
        const auto verse = typed(song, " $verse ", 5), chorus = typed(song, String::fromUTF8(" $Refrão "), 10),
                   outro = typed(song, "*1 outro", 20);
        song.markers = std::vector<jaras::TimelineMarker>{verse, chorus, outro};
        require(verse.name == "VERSE" && markerEditing::editorName(verse) == "$VERSE" &&
                    chorus.name == utf8(String::fromUTF8("REFRÃO")) &&
                    outro.name == "OUTRO" && markerEditing::editorName(outro) == "*OUTRO" &&
                    outro.loopSection == true && verse.loopSection == false,
                "Typed markers did not normalize names and preserve their section/loop meaning");
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        String error; PartsPanel panel(session, [&](String value) { error = value; }); panel.setSize(360, 640); panel.refresh();
        require(num(get(panel.diagnostics(), "current"), "count") == 4 && error.isEmpty(),
                "Parts omitted a typed section or its start pad");
        jaras::Engine core; core.loadProject(ProjectCodec::decode(session.snapshot()));
        core.execute({jaras::CommandKind::queueSection, chorus.id});
        require(core.transport().editPosition == 10 && !core.transport().playing,
                "Selecting a stopped section did not move the edit cursor");
        core.execute({jaras::CommandKind::editSeek, {}, 0}); core.execute({jaras::CommandKind::play});
        core.execute({jaras::CommandKind::queueSection, outro.id});
        require(core.nextSectionTrigger() == 5 && core.transport().queuedSectionMarkerId == outro.id &&
                    core.transport().editPosition == 20 && core.transport().position == 0 && core.transport().playing,
                "Typed section did not arm the next section boundary");
        core.advance(5);
        require(std::abs(core.transport().position - 20) < 1e-8 && !core.transport().queuedSectionMarkerId,
                "Queued section did not jump at its boundary");
        const auto saved = directory.getNonexistentChildFile("typed-sections", ".jl");
        ProjectCodec::write(saved, session.snapshot());
        const auto restored = ProjectCodec::decode(ProjectCodec::read(saved));
        require(restored.songs.front().markers->at(1).name == chorus.name &&
                    restored.songs.front().markers->at(2).loopSection == true,
                "Encrypted project round trip lost typed section data");
    });
    test("Section marker edits protect loop references and boundaries and repair old Windows literal prefixes", [&] {
        auto project = floatingControlTests::fixture(); auto &song = project.songs.front();
        song.parts.resize(1); song.parts.front().startTime = 10; song.parts.front().endTime = 30;
        auto start = typed(song, "*1 start", 12), end = typed(song, "*1 end", 25);
        song.markers = std::vector<jaras::TimelineMarker>{start, end};
        jaras::MultiLoop loop; loop.id = uuid(); loop.name = "Loop"; loop.marker1 = start.id; loop.marker2 = end.id;
        song.parts.front().multiLoops = {loop};
        const auto rejected = [&](auto operation) { try { operation(); } catch (const std::exception &) { return true; } return false; };
        auto changed = start; changed.name = "$start";
        require(rejected([&] { markerEditing::prepare(song, changed); }), "Changing a referenced loop marker broke its loop silently");
        require(rejected([&] { typed(song, "$outside", 5); }) && rejected([&] { typed(song, "$end", 30); }),
                "A new section was accepted outside the song or on its ending edge");
        require(rejected([&] { typed(song, "$duplicate", 12); }), "A second marker was accepted at an occupied point");
        changed = end; changed.position = 30;
        require(markerEditing::prepare(song, changed).position == 30, "Existing loop endpoint could not move to the region end");
        jaras::TimelineMarker legacy{uuid(), "$old Windows cue", 18, 0};
        jaras::TimelineMarker outside{uuid(), "$outside", 2, 0};
        song.markers->push_back(legacy); song.markers->push_back(outside);
        auto restored = ProjectCodec::decode(ProjectCodec::encode(project));
        const auto &markers = *restored.songs.front().markers;
        require(markers[2].section == true && markers[2].name == "OLD WINDOWS CUE" &&
                    !markers[3].section.value_or(false) && markers[3].name == "$outside",
                "Legacy repair missed an in-song prefix or changed an out-of-song marker");
    });
    test("REAPER section and loop prefixes import without creating drawer songs and retain disabled loop pairs", [&] {
        auto result = read(directory, String::fromUTF8(
            "MARKER 1 0 \"Canção\" 1\nMARKER 1 20 \"\" 1\n"
            "MARKER 4 2 \"$ Refrão\" 0\nMARKER 5 6 \"$Preço $5 * final\" 0\n"
            "MARKER 6 10 \"*1 entrada\" 0\nMARKER 7 20.0004 \"*1 saída\" 0"));
        const auto &song = result.project.songs.front();
        require(song.parts.size() == 1 && song.markers && song.markers->size() == 4,
                "Technical section flags created extra drawer songs or disappeared");
        require(song.markers->at(0).name == utf8(String::fromUTF8("REFRÃO")) &&
                    song.markers->at(1).name == utf8(String::fromUTF8("PREÇO $5 * FINAL")) &&
                    std::all_of(song.markers->begin(), song.markers->end(), markerEditing::isSection),
                "REAPER import lost section typing, accents or internal symbols");
        require(song.parts.front().multiLoops.size() == 1 && !song.parts.front().multiLoops.front().enabled.value_or(false) &&
                    !song.parts.front().multiLoops.front().mixerEnabled.value_or(false) && song.markers->back().position == 20,
                "REAPER loop pair lost its disabled state or normalized boundary");
    });
    test("VS Hook import retains family children, playlist namespaces, loop state, tuner and Resolume mappings", [&] {
        const String playlist = "PLAYLIST\tShow\nITEM\tblock\t-1\t0\t0\tAbertura\tgreen\n"
            "ITEM\tsong\t100\t0\t20\tFilha A\t\tmarker\t0\t1\t7\n"
            "ITEM\tsong\t7\t50\t70\tSolta\t\tregion\nEND";
        auto mapping = object(); put(mapping, "region:100", "1:0"); put(mapping, "marker:7", "2:0");
        put(mapping, "marker:30", "3:4"); put(mapping, "marker:999", "8:9"); put(mapping, "region:7", "invalid");
        const String body = String::fromUTF8(
            "MARKER 100 0 \"-- Família\" 1\nMARKER 100 40 \"\" 1\n"
            "MARKER 7 50 \"Solta\" 1\nMARKER 7 70 \"\" 1\n"
            "MARKER 7 0 \"Filha A\" 0\nMARKER 8 20 \"Filha B\" 0\n"
            "MARKER 30 22 \"*2 início\" 0\nMARKER 31 27 \"*2 fim\" 0\nMARKER 32 24 \"$ponte\" 0\n"
            "<TRACK {AAAAAAAA-1111-1111-1111-111111111111}\nNAME \"# Keys\"\n>\n"
            "<EXTSTATE\n<CHATGPT_REGION_PLAYLIST\n") + binary("PLAYLISTS_DB_V3", playlist) +
            "\nTUNER_OFFSETS_V1 \"7=3|8=-7|100=12\"\n>\n<VS_HOOK_MULTILOOPS\n" +
            binary("STATE_V2", "E\t8\t0\t1\t0\t0\t0\t0\t0\t0") +
            "\n>\n<VS_HOOK_LOADER\n" + binary("RESOLUME_MAP_ASSIGNMENTS_WITH_MARKERS_V1", JSON::toString(mapping)) + "\n>\n>";
        auto result = read(directory, body); const auto &song = result.project.songs.front();
        const jaras::Part *parent = nullptr, *first = nullptr, *second = nullptr, *standalone = nullptr;
        for (const auto &part : song.parts) {
            if (part.name == utf8(String::fromUTF8("Família"))) parent = &part;
            else if (part.name == "Filha A") first = &part;
            else if (part.name == "Filha B") second = &part;
            else if (part.name == "Solta") standalone = &part;
        }
        require(parent && first && second && standalone && song.parts.size() == 4,
                "VS Hook family conversion lost or duplicated songs");
        require(first->parentRegionID == parent->id && second->parentRegionID == parent->id &&
                    first->pitchSemitones == 3 && second->pitchSemitones == -7 && standalone->pitchSemitones == 3 &&
                    parent->pitchSemitones.value_or(0) == 0,
                "VS Hook confused marker and region namespaces or transposed the family twice");
        require(second->multiLoops.size() == 1 && second->multiLoops.front().enabled == true,
                "VS Hook child lost its enabled multiloop");
        require(result.project.regionSetlist && result.project.regionSetlist->playlists.size() == 1 &&
                    result.project.regionSetlist->playlists.front().regionIds == std::vector<ID>{parent->id, standalone->id} &&
                    result.project.regionSetlist->blocks && result.project.regionSetlist->blocks->front().color == 0x2ebd5c,
                "VS Hook playlist lost family ownership, order or its block");
        require(result.project.resolumeJSON.has_value(), "VS Hook loader assignments were omitted");
        const auto map = get(JSON::parse(text(*result.project.resolumeJSON)), "withMarkers");
        require(str(map, "region:" + text(parent->id)) == "1:0" && str(map, "region:" + text(first->id)) == "2:0" &&
                    map.getDynamicObject()->getProperties().size() == 3,
                "VS Hook Resolume references were not remapped to imported regions and cues");
        const auto saved = saveMigratedProject(result, directory.getNonexistentChildFile("imported-hook", ".jl"));
        const auto raw = ProjectCodec::read(saved); const auto restored = ProjectCodec::decode(raw);
        require(restored.songs.front().parts.size() == 4 &&
                    JSON::toString(get(get(raw, "resolume"), "withMarkers")) == JSON::toString(map),
                "Saving the imported project lost songs or Resolume assignments");
    });
}
} // namespace catlive::sectionMarkerTests
