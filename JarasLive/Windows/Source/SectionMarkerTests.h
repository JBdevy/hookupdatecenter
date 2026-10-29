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
    test("Automatic section editor reveals its source song without changing the project", [&] {
        jaras::Project p;p.id=uuid();p.name="Long song list";jaras::Song song;song.id=uuid();song.name="Arrangement";song.duration=700;
        for(int i=0;i<60;++i)song.parts.push_back({uuid(),"Song "+std::to_string(i),double(i*10),double(i*10+10)});
        auto marker=typed(song,"$Cue",595);song.markers=std::vector<jaras::TimelineMarker>{marker};p.songs={song};
        Session session;session.inspection=true;session.restoreSnapshot(ProjectCodec::encode(p));
        const auto before=JSON::toString(session.snapshot());String failure;
        AutomaticSectionPanel editor(session,marker.id,[&](String s){failure=s;});editor.setSize(660,420);
        auto* left=dynamic_cast<ListBox*>(editor.getChildComponent(0));
        require(left && left->getViewport()->getViewPositionY()>0,"Source song was left outside the visible list");
        require(failure.isEmpty() && JSON::toString(session.snapshot())==before,"Opening the editor changed the project");
    });

    test("Automatic section arms once and manual cancellation or replacement wins", [&] {
        jaras::Project p;p.id=uuid();p.name="Auto sections";
        jaras::Song song;song.id=uuid();song.name="Arrangement";song.duration=80;
        song.parts={{uuid(),"First",0,40},{uuid(),"Second",40,80}};
        auto source=typed(song,"$Source",10),target=typed(song,"$Target",50),other=typed(song,"$Other",60);
        source.automaticSectionTargetID=target.id;song.markers=std::vector<jaras::TimelineMarker>{source,target,other};p.songs={song};
        jaras::Engine core;core.loadProject(p);core.execute({jaras::CommandKind::play});core.advance(5.1);
        require(core.transport().queuedSectionMarkerId==target.id,"Automatic destination was not queued at warning time");
        core.execute({jaras::CommandKind::cancelSection});core.advance(5);
        require(!core.transport().queuedSectionMarkerId && std::abs(core.transport().position-10.1)<1e-7,"Automatic queue ignored cancellation");
        core.execute({jaras::CommandKind::seek,{},0});core.advance(5.1);
        core.execute({jaras::CommandKind::queueSection,other.id});core.advance(5);
        require(std::abs(core.transport().position-60.1)<1e-7,"Automatic queue overrode manual replacement");
        auto earlier=typed(song,"$Earlier",8);p.songs.front().markers->push_back(earlier);
        jaras::Engine close;close.loadProject(p);close.execute({jaras::CommandKind::play});close.advance(5.1);
        require(close.nextSectionTrigger()==10 && partsPresentation::trigger(*close.currentSong(),close.currentSong()->parts.front(),close.transport())==10,
                "Close markers changed the automatic jump or remote warning boundary");
        close.advance(3);require(std::abs(close.transport().position-8.1)<1e-7,"Jump happened at the preceding marker");
        close.advance(2);require(std::abs(close.transport().position-50.1)<1e-7,"Configured jump boundary was missed");
    });

    test("REAPER special tracks normalize names, solo and folders like the Mac importer", [&] {
        auto result = read(directory,
            "<TRACK {GROUP}\nNAME \"Audio Group\"\nISBUS 1 1\n>\n"
            "<TRACK {TP1}\nNAME \"TELEPROMPT 1\"\nMUTESOLO 1 1\n<ITEM\nPOSITION 0\nLENGTH 2\nNAME \"Texto\"\nVOLPAN 0.5 0.3\nMUTE 1\n<NOTES\n|Primeira linha\n|Segunda linha\n>\n>\n>\n"
            "<TRACK {TP2}\nNAME \"teleprompter2\"\nMUTESOLO 1 1\n>\n"
            "<TRACK {CHORDS}\nNAME \"Cifras\"\nMUTESOLO 1 1\n>\n"
            "<TRACK {TC}\nNAME \"TIME CODE\"\nMUTESOLO 0 1\n<ITEM\nPOSITION 0\nLENGTH 2\n<SOURCE LTC\nSEND 1\nFRAMERATE 25\nSTARTTIME 10\n>\n>\n>\n"
            "<TRACK {AUDIO}\nNAME \"Voz\"\nISBUS 2 -1\nMUTESOLO 0 1\n>\n");
        const auto &song=result.project.songs.front();
        require(song.tracks.size()==6,"Imported special tracks were lost or duplicated");
        require(song.tracks[0].role.id=="timecode" && song.tracks[1].role.id=="teleprompt" &&
                song.tracks[2].role.id=="teleprompt2" && song.tracks[3].role.id=="chords","Fixed special-track order differs from Mac");
        for(const auto &track:song.tracks) if(!jaras::fixedTrackName(track.role).empty()) {
            require(track.name==jaras::fixedTrackName(track.role) && !track.solo && !track.parentTrackID,
                    "Special track retained a noncanonical name, solo or audio-folder parent");
            if(jaras::isTeleprompterRole(track.role)||track.role.id=="chords")require(!track.mute,"Text special tracks must not retain imported mute");
        }
        require(song.tracks.back().parentTrackID==song.tracks[4].id && song.tracks.back().solo,"Normal audio grouping and solo must be preserved");
        require(song.tracks.front().timecode && song.tracks.front().patch && song.tracks.front().patch->firstChannel==-1,
                "Timecode must initialize its settings without routing to Master");
        const auto &textItem=song.tracks[1].clips.front();
        require(textItem.text && *textItem.text=="Primeira linha\nSegunda linha" && !textItem.gain && !textItem.pan && !textItem.muted && textItem.sourceOffset==0,
                "Teleprompter text retained incompatible audio controls after migration");
        require(song.tracks.front().clips.front().timecode && song.tracks.front().timecode->frameRate==25 && song.tracks.front().timecode->offset==10,
                "Imported SMPTE generator lost its actual frame rate or start offset");
        jaras::validate(result.project);
        auto video=read(directory,"<TRACK {MEDIA}\nNAME \"Media\"\nMUTESOLO 0 1\n<ITEM\nPOSITION 0\nLENGTH 1\n<SOURCE VIDEO\nFILE \"missing-video.mp4\"\n>\n>\n>\n");
        const auto &videoTrack=video.project.songs.front().tracks.front();
        require(videoTrack.role.id=="other" && videoTrack.name=="Video" && videoTrack.solo &&
                videoTrack.clips.front().audioFile->path.rfind("Videos/",0)==0,"Media must import into a standard video-capable track, like Mac");
        auto recovered=read(directory,"<TRACK {TP_FOLDER}\nNAME \"Teleprompter 1\"\nISBUS 1 1\n>\n<TRACK {CLOSE}\nNAME \"Audio\"\nISBUS 2 -1\n>\n");
        require(recovered.project.songs.front().tracks.size()==2,"An invalid special folder discarded otherwise valid tracks");
        require(!recovered.warnings.isEmpty(),"Recovered folder structure must be reported");
        jaras::validate(recovered.project);
    });
    test("REAPER recovery keeps valid items and markers around malformed elements", [&] {
        const ScopedValueSetter<bool> restoreLanguage(localization::english, localization::english);
        for (const bool english : {false, true}) {
        localization::english = english;
        auto recovered=read(directory,
            "<TRACK {RECOVER}\nNAME Recover\n"
            "<ITEM\nPOSITION 0\nLENGTH 2\nNAME Before\n>\n"
            "<ITEM\nPOSITION nan\nLENGTH 3\n>\n"
            "<ITEM\nPOSITION 5\nLENGTH 2\nNAME After\n>\n>\n"
            "MARKER invalid\nMARKER 1 1 Good 0\n");
        const auto &song=recovered.project.songs.front();
        require(song.tracks.size()==1 && song.tracks.front().clips.size()==2,"Bad item discarded valid neighbors");
        require(song.tracks.front().clips[0].name=="Before" && song.tracks.front().clips[1].name=="After","Recovered item order changed");
        const auto warnings = recovered.warnings.joinIntoString(" ");
        require(warnings.contains(migration::message("REAPER item ignored: ")) && warnings.contains(migration::message("REAPER marker ignored: ")),"Skipped elements were not reported in the app language");
        require(warnings.contains(english ? "item ignored" : "ignorado"), "Import diagnostics ignored the selected language");
        jaras::validate(recovered.project);
        }
    });
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
