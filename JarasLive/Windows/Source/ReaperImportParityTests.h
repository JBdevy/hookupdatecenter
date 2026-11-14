#pragma once
#include "ProjectMigration.h"
#include "Automation.h"
#include "../../Core/Timecode/TimecodePlayback.hpp"

namespace catlive::reaperImportParityTests {
inline void require(bool condition, const String &message) {
    if (!condition)
        throw std::runtime_error(utf8(message));
}
inline MigratedProject read(const File &directory, const String &body,
                            const ReaperVST3Resolver &resolver = {}) {
    const auto file = directory.getNonexistentChildFile("reaper-parity", ".rpp");
    require(file.replaceWithText("<REAPER_PROJECT 0.1 \"7.0\" 1\nTEMPO 120 4 4\n" + body + "\n>\n"),
            "Cannot write REAPER fixture");
    struct Cleanup {
        File file;
        ~Cleanup() { file.deleteFile(); }
    } cleanup{file};
    return readReaperProject(file, resolver);
}
// The same captured REAPER GainFixture chunk used by ReaperAutomationImportTests.swift.
inline String effect(const String &identity = "0:7001", bool bypass = false) {
    return String("BYPASS ") + (bypass ? "1" : "0") +
           " 0 0\n"
           "<VST \"VST3: Gain fixture\" GainFixture.vst3 0 \"\" "
           "526044762{1234123456785678ABCDEF0012345678} \"\"\n"
           "Ws5aH+5e7f4CAAAAAQAAAAAAAAACAAAAAAAAAAIAAAABAAAAAAAAAAIAAAAAAAAAKAAAAAEAAAD//wAA\n"
           "DAAAAAEAAABI4To/AAAAAAAAAAAMAAAAAAAAAEjhOj8AAAAAAAAAAA==\n"
           "AAAAAAAA\n>\n"
           "<PARMENV \"" +
           identity +
           "\" 0 1 0.5 \"Gain / Gain fixture\"\n"
           "ACT 1 -1\nVIS 0 1 1\nARM 1\nPT 0 0.23 0\nPT 4 0.81 1\n>\n";
}
inline var settings(const std::optional<std::string> &json) {
    return json ? JSON::parse(text(*json)) : var();
}
inline var restored(const var &plugin, const std::set<int> &indices) {
    require(indices == std::set<int>{0}, "Resolver did not receive the REAPER parameter index");
    require(str(plugin, "componentState") == "SOE6PwAAAAAAAAAA" &&
                str(plugin, "controllerState") == "SOE6PwAAAAAAAAAA",
            "Routing header was passed as VST3 state, or the captured state changed");
    auto result = plugin.clone(), ids = object();
    put(result, "path", "C:\\Plugins\\GainFixture.vst3");
    put(ids, "0", 7001);
    put(result, "parameterIDs", ids);
    return result;
}
template <typename Test> void registerTests(const File &directory, Test &test) {
    test("REAPER ignored items identify each source and reason while retaining valid media", [&] {
        const auto result = read(directory, "<TRACK\nNAME Keys\n"
            "<ITEM\nPOSITION nan\nLENGTH 2\n<SOURCE WAVE\nFILE First.wav\n>\n>\n"
            "<ITEM\nPOSITION 4\nLENGTH 2\nPLAYRATE invalid\n<SOURCE SECTION\n<SOURCE WAVE\nFILE Second.wav\n>\n>\n>\n"
            "<ITEM\nPOSITION 8\nLENGTH 2\n<SOURCE UNKNOWN\nFILE Third.xyz\n>\n>\n"
            "<ITEM\nPOSITION 12\nLENGTH 2\n<SOURCE WAVE\nFILE Valid.wav\n>\n>\n>");
        require(result.project.songs.front().tracks.front().clips.size() == 1, "A bad item blocked valid media");
        for (const auto *file : {"First.wav", "Second.wav", "Third.xyz"}) {
            const auto found = std::find_if(result.warnings.begin(), result.warnings.end(), [&](const auto &notice) {
                return notice.contains(file) && notice.contains("Keys") && notice.contains("\n");
            });
            require(found != result.warnings.end(), "An ignored file lost its identity or reason");
        }
    });
    test("REAPER take rate preserves full double precision through project save", [&] {
        const auto result=read(directory,"<TRACK\nNAME Precision\n<ITEM\nPOSITION 0.667123456789\nLENGTH 184.66123456789\nSOFFS 0.123456789012345\nPLAYRATE 1.1234567890123456 1 0\n<SOURCE WAVE\nFILE missing-reference.wav\n>\n>\n>");
        const double expected=1.1234567890123456;
        require(result.project.songs.front().tracks.front().clips.front().playbackRate==expected,"REAPER rate was rounded while importing");
        const auto saved=directory.getNonexistentChildFile("rate-precision",".jl");
        struct Cleanup {File file;~Cleanup(){file.deleteFile();}} cleanup{saved};
        ProjectCodec::write(saved,ProjectCodec::encode(result.project));
        const auto reopened=ProjectCodec::decode(ProjectCodec::read(saved));
        const auto& clip=reopened.songs.front().tracks.front().clips.front();
        require(clip.playbackRate==expected && clip.duration==184.66123456789,"Project save changed imported rate or item duration");
    });
    test("REAPER region-free items stay region-free", [&] {
        const auto result = read(directory, "<TRACK\nNAME Piano\n<ITEM\nPOSITION 3\nLENGTH 10\nNAME Piano.wav\n<SOURCE WAVE\nFILE missing.wav\n>\n>\n>");
        const auto &song = result.project.songs.front();
        require(song.parts.empty() && (!song.markers || song.markers->empty()), "Importer invented regions or markers");
        require(song.duration == 13 && song.tracks.front().clips.size() == 1, "Region-free item timing changed");
        require(result.project.importedTimeline == true, "Importer lost the imported timing flag");
        auto project = result.project;
        project.songs.front().bpm = 140;
        for (int pass = 0; pass < 3; ++pass) {
            project = ProjectCodec::decode(ProjectCodec::encode(project, object()));
            require(project.importedTimeline == true, "Saving/reopening lost imported timing protection");
            require(project.songs.front().bpm == 140 && project.songs.front().tracks.front().clips.front().playbackRate == 1,
                    "Saving/reopening changed the imported BPM or item rate");
        }
    });
    test("REAPER special overlaps recover compatible items and independent projection layers", [&] {
        const auto item = [](double start, double duration, const String &content = {}) {
            return "<ITEM\nPOSITION " + String(start, 9) + "\nLENGTH " + String(duration, 9) + "\n" +
                (content.isEmpty() ? String() : "<NOTES\n|" + content + "\n>\n") + ">\n";
        };
        const auto items = item(10, 2, "Later") + item(0, 4, "First") + item(2, 5, "Conflicting") +
            item(0, 1, "Duplicate") + item(4, 2, "Next") + item(20, 3) + item(21, 3);
        String body;
        for (const auto &name : StringArray{"Teleprompt 1", "Teleprompt 2", "CIFRAS"})
            body += "<TRACK\nNAME \"" + name + "\"\n" + items + ">\n";
        body += "<TRACK\nNAME \"Teleprompt 1\"\n" + item(0, 4, "Lyrics");
        for (int start : {0, 2, 4})
            body += "<ITEM\nPOSITION " + String(start) + "\nLENGTH 4\n<SOURCE VIDEO\nFILE \"video" + String(start) + ".mp4\"\n>\n>\n";
        body += ">\n<TRACK\nNAME Audio\n" + item(0, 4) + item(2, 4) + ">\n";
        const auto result = read(directory, body);
        require(result.project.songs[0].tracks.size() == 5, "Overlap discarded a track or project");
        for (const auto &track : result.project.songs[0].tracks) {
            if (track.name == "Audio") { require(track.clips.empty(), "Empty audio placeholders must be ignored"); continue; }
            const bool media = std::any_of(track.clips.begin(), track.clips.end(), [](const auto &clip) { return clip.audioFile.has_value(); });
            if (media) {
                require(track.clips.size() == 3, "Text/media layers were merged or conflicting media retained");
                require(track.clips[0].startTime == 0 && track.clips[1].startTime == 0 && track.clips[2].startTime == 4,
                        "Projection timing differs from Mac");
            } else if(jaras::isTeleprompterRole(track.role)) {
                require(track.clips.size()==7, "Overlapping lyrics must all survive import");
                require(track.clips[0].text=="First" && track.clips[1].text=="Duplicate" && track.clips[2].text=="Conflicting", "Lyrics source order/timing changed");
                require(ItemLanes(track).count==2, "Simultaneous lyrics must occupy separate grid lanes");
                auto copy=track;copy.clips[1].startTime=1;
                clipEditing::requireSpace(copy,copy.clips[1],1,2);
                require(clipEditing::constrainedStart(copy,copy.clips[1],2)==2, "Lyrics drag still rejects overlap");
            } else {
                require(track.clips.size() == 4, "Wrong special items were recovered");
                require(track.clips[0].startTime == 0 && track.clips[0].duration == 4 && track.clips[0].text == "First" &&
                            track.clips[1].startTime == 4 && track.clips[2].startTime == 10 && track.clips[3].startTime == 20,
                        "Recovery moved/trimmed content or depends on source order");
            }
        }
        require(result.warnings.joinIntoString("\n").contains("Conflicting"), "Recovery must report affected items");
        jaras::validate(result.project);
    });
    test("REAPER MIDI keeps pre-zero tempo and exact trimmed loop repetitions", [&] {
        const auto tempo = read(directory,
            "<TEMPOENVEX\nPT -2 60 1\n>\n<TRACK\n<ITEM\nPOSITION 0\nLENGTH 4\n"
            "<SOURCE MIDI\nHASDATA 1 960 QN\nE 0 90 3c 64\nE 960 80 3c 00\n>\n>\n>\n");
        const auto &note = tempo.project.songs[0].tracks[0].clips[0].midi->notes[0];
        require(note.start == 0 && note.length == 2, "Initial project tempo incorrectly replaced a pre-zero tempo marker");
        const auto loop = read(directory,
            "<TRACK\n<ITEM\nPOSITION 10\nLENGTH 2\nLOOP 1\nSOFFS 0.25 0.5\nPLAYRATE 2 1 0\n"
            "<SOURCE MIDI\nHASDATA 1 960 QN\nE 0 90 3c 7f\nE 960 80 3c 00\nE 960 b0 7b 00\n>\n>\n>\n");
        const auto &notes = loop.project.songs[0].tracks[0].clips[0].midi->notes;
        const double starts[] = {0, .75, 1.75, 2.75, 3.75}, lengths[] = {.25, .5, .5, .5, .25};
        require(notes.size() == 5, "Trimmed MIDI loop repetition count differs from Mac");
        for(size_t i=0;i<notes.size();++i)
            require(std::abs(notes[i].start-starts[i])<1e-8 && std::abs(notes[i].length-lengths[i])<1e-8,
                    "Trimmed MIDI loop position or length differs from Mac");
    });
    test("REAPER empty special-track placeholders do not obscure lyrics or reject import", [&] {
        const auto result = read(directory,
            "<TRACK\nNAME \"Teleprompter 1\"\n"
            "<ITEM\nPOSITION 0\nLENGTH 8\n>\n"
            "<ITEM\nPOSITION 2\nLENGTH 4\n<NOTES\n|Letra principal\n>\n>\n>\n");
        const auto &clips = result.project.songs[0].tracks[0].clips;
        require(clips.size() == 1 && clips[0].text == "Letra principal", "Overlapping placeholder was not removed");
    });
    test("REAPER restores independent track, take and master VST3 presets and parameter IDs", [&] {
        int calls = 0;
        const auto result = read(directory,
                                 "<MASTERFXLIST\n" + effect("0") +
                                     ">\n"
                                     "<TRACK\nNAME Audio\n<FXCHAIN\n" +
                                     effect("0:7001", true) +
                                     ">\n"
                                     "<ITEM\nPOSITION 2\nLENGTH 8\nSOFFS 3\n<TAKEFX\n" +
                                     effect() +
                                     ">\n"
                                     "<SOURCE WAVE\nFILE offline.wav\n>\n>\n>\n",
                                 [&](const var &plugin, const std::set<int> &indices) {
                                     ++calls;
                                     return restored(plugin, indices);
                                 });
        require(calls == 3, "All three FX chains must resolve their own presets");
        const auto &track = result.project.songs.front().tracks.front();
        const auto &clip = track.clips.front();
        const auto master = settings(result.project.masterFXJSON), fx = settings(track.fxJSON),
                   take = settings(clip.fxJSON);
        std::set<String> ids;
        for (const auto &chain : {master, fx, take}) {
            const auto plugins = list(get(chain, "externalPlugins"));
            require(plugins.size() == 1 && list(get(chain, "inserted")).size() == 1,
                    "Resolved FX was omitted");
            require(str(plugins[0], "path") == "C:\\Plugins\\GainFixture.vst3" &&
                        str(plugins[0], "componentState") == "SOE6PwAAAAAAAAAA",
                    "Preset or resolved path was lost");
            ids.insert(str(plugins[0], "id"));
        }
        require(ids.size() == 3 && flag(list(get(fx, "externalPlugins"))[0], "bypassed") &&
                    !flag(list(get(take, "externalPlugins"))[0], "bypassed"),
                "Instance identity or bypass leaked across chains");
        for (const auto &automation :
             {settings(result.project.masterAutomationJSON), settings(track.automationJSON)}) {
            AutomationProgram compiled;
            compiled.prepare(automation);
            require(
                compiled.curves.size() == 1 &&
                    compiled.curves[0].target == AutomationCurve::externalFX &&
                    compiled.curves[0].parameter == 7001 &&
                    std::abs(compiled.curves[0].value(2) - .52) < 1e-8,
                "Imported hidden parameter envelope does not play or uses an index instead of ParamID");
        }
        AutomationProgram compiled;
        compiled.prepare(settings(clip.automationJSON), true);
        require(compiled.curves.size() == 1 && compiled.curves[0].points[0].time == 3 &&
                    compiled.curves[0].points[1].time == 7,
                "Audio take envelope must use the source-offset clock");
    });
    test("REAPER missing and rejected VST3 presets remain recoverable without inserting defaults", [&] {
        const auto check = [&](const ReaperVST3Resolver &resolver) {
            const auto result = read(directory, "<TRACK\n<FXCHAIN\n" + effect() + ">\n>\n", resolver);
            const auto fx = settings(result.project.songs.front().tracks.front().fxJSON);
            const auto plugins = list(get(fx, "externalPlugins"));
            require(plugins.size() == 1 && list(get(fx, "inserted")).isEmpty() &&
                        flag(plugins[0], "bypassed") &&
                        str(plugins[0], "componentState") == "SOE6PwAAAAAAAAAA",
                    "Failed restoration discarded the preset or inserted its default");
            require(!result.warnings.isEmpty(), "Missing or rejected plugin must be reported");
        };
        check({});
        check([](const var &, const std::set<int> &) -> var {
            throw std::runtime_error("Fixture rejected state");
        });
    });
    test("REAPER rejects malformed parameter identities without losing neighboring items", [&] {
        for (const auto &identity :
             StringArray{"", ":", "0:", "::", "0:invalid", "0:1:2", "-1", "invalid", "0:4294967296"}) {
            const auto result =
                read(directory,
                     "<TRACK\n<FXCHAIN\n" + effect(identity) + ">\n<ITEM\nPOSITION 0\nLENGTH 2\n<SOURCE WAVE\nFILE neighbor.wav\n>\n>\n>\n",
                     restored);
            const auto &track = result.project.songs.front().tracks.front();
            require(track.clips.size() == 1 && !track.fxJSON && !result.warnings.isEmpty(),
                    "Malformed FX identity escaped recovery: " + identity);
        }
    });
    test("REAPER automation preserves gain-domain interpolation, modes and negative-time boundary", [&] {
        const auto result = read(
            directory, "<PANENV2\nPT -10 -1 0\nPT 10 1 0\n>\n"
                       "<TRACK\nNAME Mix\nAUTOMODE 1\n<VOLENV2\nACT 1\nVIS 0\nPT 0 1 0\nPT 10 0.1 1\n>\n"
                       "<PANENV2\nPT 0 -1 2\nPT 10 1 0\n>\n<MUTEENV\nPT 0 1 1\nPT 5 0 1\n>\n>\n");
        AutomationProgram master;
        master.prepare(settings(result.project.masterAutomationJSON));
        require(master.curves.size() == 1 && master.curves[0].points.front().time == 0 &&
                    std::abs(master.curves[0].value(0) - .5) < 1e-8,
                "Negative envelope was not clipped at its interpolated value");
        AutomationProgram track;
        track.prepare(settings(result.project.songs.front().tracks.front().automationJSON));
        const auto values = track.evaluate(5, .2, .1);
        require(!track.trim && track.curves.size() == 3 && std::abs(values.gain - .55) < 1e-8 &&
                    std::abs(values.pan) < 1e-8 && values.mute,
                "Mix envelopes or gain interpolation differ from Mac");
        const auto before = track.evaluate(0, .2, .1);
        require(!before.mute && before.pan == -1 && std::abs(before.gain - 1) < 1e-8,
                "Mute polarity differs from REAPER");
    });
    test("REAPER fader-scaled and Bezier envelopes are resampled without changing audible gain", [&] {
        const auto result =
            read(directory,
                 "<TRACK\nAUTOMODE 1\n<VOLENV2\nVOLTYPE 1\nPT 0 0 0\nPT 4 3.9810717055349722 0\n>\n>\n"
                 "<TRACK\n<PANENV2\nPT 0 -1 5 0 0 0 0\nPT 4 1 0\n>\n>\n");
        AutomationProgram track;
        track.prepare(settings(result.project.songs.front().tracks[0].automationJSON));
        const double expected = std::pow(10., .6) / 2 * .125 * 1.125;
        require(track.curves[0].points.size() > 2 &&
                    std::abs(track.evaluate(2, 1, 0).gain - expected) < 2e-5,
                "Fader-scaled envelope became a linear-gain ramp");
        AutomationProgram bezier;
        bezier.prepare(settings(result.project.songs.front().tracks[1].automationJSON));
        require(std::abs(bezier.curves[0].value(2) - .5) < 2e-5, "Symmetric Bezier midpoint changed");
    });
    test("REAPER MIDI retains exact imported rate without changing audible note times", [&] {
        const double rate=1.1234567890123456;
        const auto result=read(directory,"<TRACK\nNAME MIDI\n<ITEM\nPOSITION 2\nLENGTH 4\nPLAYRATE 1.1234567890123456 1 0\n<SOURCE MIDI\nHASDATA 1 960 QN\nE 960 90 3c 64\nE 960 80 3c 00\n>\n>\n>\n");
        const auto& clip=result.project.songs.front().tracks.front().clips.front();
        require(clip.playbackRate==rate && clip.midi && clip.midi->notes.size()==1,"Imported MIDI lost its editable rate");
        const auto& note=clip.midi->notes.front();
        require(std::abs(note.start*.5/rate-.5/rate)<1e-12 && std::abs(note.length*.5/rate-.5/rate)<1e-12,"Imported MIDI changed audible note timing");
    });
    test("REAPER timecode retains rate with its source offset and configured FPS", [&] {
        const auto result=read(directory,"<TRACK\nNAME TIMECODE\n<ITEM\nPOSITION 5\nLENGTH 7\nSOFFS 2\nPLAYRATE 1.159123456789 1 0\n<SOURCE LTC\nSTARTTIME 3600\nFRAMERATE 25 0\nSEND 2\nUSERDATA 0 0 0 0\n>\n>\n>\n");
        const auto& song=result.project.songs.front();const auto& track=song.tracks.front();const auto& clip=track.clips.front();
        require(clip.playbackRate==1.159123456789 && clip.timecode && clip.timecode->frameRate==25 && clip.timecode->offset==3602,"Imported timecode lost rate, offset or FPS");
        const jaras::TimecodeProgram program(song,track);
        require(std::abs(program.at(6)->time(6)-(3602+clip.playbackRate))<1e-10,"Imported timecode counter did not follow its take rate");
    });
    test("REAPER pooled MIDI accounts for SysEx time, take rate, source offsets and muted notes", [&] {
        const auto result =
            read(directory,
                 "<TRACK\nNAME MIDI\n<ITEM\nPOSITION 0\nLENGTH 2\n<SOURCE MIDI\nHASDATA 1 960 "
                 "QN\nPOOLEDEVTS {POOL}\n"
                 "<X 480\n00\n>\nE 0 90 3c 64\nE 960 80 3c 00\nEm 0 90 40 64\nEm 480 80 40 00\n>\n>\n"
                 "<ITEM\nPOSITION 4\nLENGTH 2\nPLAYRATE 2 1 0\n<VOLENV\nPT 0 1 0\nPT 4 0.5 0\n>\n"
                 "<SOURCE MIDI\nPOOLEDEVTS {POOL}\n>\n>\n>\n");
        const auto &clips = result.project.songs.front().tracks.front().clips;
        require(clips.size() == 2 && clips[0].midi && clips[1].midi, "Pooled MIDI item was discarded");
        require(clips[0].midi->notes.size() == 1 && clips[1].midi->notes.size() == 1,
                "Muted notes were imported or notes lost");
        const auto &a = clips[0].midi->notes[0], &b = clips[1].midi->notes[0];
        require(a.start == .5 && a.length == 1 && b.start == .5 && b.length == 1 &&
                    clips[1].playbackRate == 2,
                "MIDI event clock or rate was applied incorrectly");
        const auto env = list(get(settings(clips[1].automationJSON), "envelopes"));
        require(num(list(get(env[0], "points"))[1], "time") == 4,
                "MIDI take envelope must retain its editable source-rate clock");
        require(result.warnings.joinIntoString(" ").contains("SysEx"),
                "Unsupported MIDI content must be reported");
    });
    test("REAPER ordinary video preserves source sections and projection routing", [&] {
        const auto result=read(directory,
            "<TRACK\nNAME \"Teleprompt 1\"\n<ITEM\nPOSITION 0\nLENGTH 30\n<SOURCE VIDEO\nFILE lyrics.mov\n>\n>\n>\n"
            "<TRACK\nNAME Opening\n<ITEM\nPOSITION 10\nLENGTH 3\nSOFFS 1\nPLAYRATE 2 1 0\nVOLPAN 0.5 -0.25 1\nLOOP 1\n"
            "<SOURCE SECTION\nSTARTPOS 5\nLENGTH 8\n<SOURCE VIDEO\nFILE intro.mp4\n>\n>\n>\n>\n"
            "<TRACK\nNAME Background\n<ITEM\nPOSITION 10\nLENGTH 20\n<SOURCE WAVE\nFILE backdrop.MOV\n>\n>\n>\n");
        const auto &song=result.project.songs[0];const auto &clip=song.tracks[1].clips[0];
        require(clip.audioFile && clip.audioFile->path=="Videos/intro.mp4" && clip.startTime==10 && clip.duration==3 && clip.sourceOffset==6 && clip.playbackRate==2 && clip.loopStart==5 && clip.loopLength==8 && clip.gain==.5 && clip.pan==-.25, "Video timing, trim or mixer state changed");
        require(firstProjectionItem(song,10,"video")==&clip, "Top ordinary video is not selected");
        require(firstProjectionItem(song,13,"video")==&song.tracks[2].clips[0], "Lower video does not take over at the cut");
        require(firstProjectionItem(song,0,"video")==nullptr, "Teleprompter media leaked into video window");
        jaras::validate(result.project);
    });
    test("REAPER partial recovery retains supported audio and clips regions at timeline zero", [&] {
        const auto result = read(
            directory, "MARKER 1 -2 Song 1\nMARKER 1 10 \"\" 1\n"
                       "<TRACK\nAUTOMODE invalid\n<VOLENV2\nPT 0 1 0\nPT broken 0.5 0\nPT 2 0.5 0\n>\n"
                       "<ITEM\nPOSITION -1\nLENGTH 3\n>\n"
                       "<ITEM\nPOSITION 0\nLENGTH 2\n<SOURCE VIDEO\nFILE source.mp4\n>\n>\n"
                       "<ITEM\nPOSITION 2\nLENGTH 3\n<SOURCE WAVE\nFILE offline.wav\n>\n>\n>\n");
        const auto &song = result.project.songs.front();
        require(song.tracks[0].clips.size() == 2 && song.tracks[0].clips[0].audioFile && song.tracks[0].clips[0].audioFile->path=="Videos/source.mp4",
                "Video on an ordinary track was discarded");
        require(song.parts.front().startTime == 0 && song.parts.front().endTime == 10 &&
                    !result.warnings.isEmpty(),
                "Negative region boundary or partial recovery failed");
    });
}
} // namespace catlive::reaperImportParityTests
