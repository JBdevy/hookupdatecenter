#pragma once
#include "Lighting.h"
#include "ResolumeComposition.h"
namespace catlive::lightingRegionTests {
inline void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
inline jaras::Project fixture() {
    jaras::Project project; project.id = uuid(); project.name = "Lighting scope";
    jaras::Song song; song.id = uuid(); song.name = "Timeline"; song.duration = 50;
    jaras::Part parent{uuid(), "Block", 0, 45}, a{uuid(), "A", 0, 20}, b{uuid(), "B", 25, 40};
    a.parentRegionID = parent.id; b.parentRegionID = parent.id;
    song.parts = {a, b, parent}; song.markers.emplace();
    auto marker = [&](const char *name, double at, bool section = false) -> jaras::TimelineMarker & {
        song.markers->push_back({uuid(), name, at, 0});
        if (section) song.markers->back().section = true;
        return song.markers->back();
    };
    marker("A normal", 2); marker("A section", 5, true); marker("A loop", 7, true).loopSection = true;
    marker("Near start", .001); marker("Near end", 19.999);
    marker("B normal", 29); marker("B section", 35, true);
    marker("Outside", 22); marker("Outside section", 43, true);
    marker("Tempo", 12).tempoBPM = 130;
    marker("Linked region", 10).sourceRegionID = a.id;
    marker("Legacy unified boundary", 11).unifiedRegionID = parent.id;
    for (double position : {0., 20., 25., 40.}) marker("Boundary", position);
    project.songs = {song}; return project;
}
inline std::set<String> names(const LightingRegion &region) {
    std::set<String> result;
    for (const auto &cue : region.cues) result.insert(cue.name);
    return result;
}
template <typename Test> void registerTests(const File &, Test &test) {
    test("Resolume and grandMA2 create only interior normal/section cues for each leaf song", [] {
        const auto project = fixture(); const auto &song = project.songs.front();
        const auto regions = Lighting::buildResolumeRegions(project);
        require(regions.size() == 2 && regions[0].id == song.parts[0].id && regions[1].id == song.parts[1].id,
                "Unified parent became a deck or leaf songs were lost");
        require(names(regions[0]) == std::set<String>{"Inicio", "A normal", "A section", "A loop", "Near start", "Near end"},
                "First song missed valid markers or included another song, gap, boundary, tempo or region marker");
        require(names(regions[1]) == std::set<String>{"Inicio", "B normal", "B section"},
                "Second song included markers outside its bounds");
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Lighting lighting(session);
        require(lighting.regions.size() == 2, "grandMA2 created executors for unified parents");
        for (size_t i = 0; i < regions.size(); ++i) {
            const auto expected = names(regions[i]);
            require(lighting.regions[i].id == regions[i].id && names(lighting.regions[i]) == expected,
                    "grandMA2 and Resolume used different song marker scopes");
        }
        const auto exports = lighting.buildExports(false);
        require(exports.size() == 2 && exports[0].region.cues.size() == 6 && exports[1].region.cues.size() == 3,
                "grandMA2 export count includes non-song markers");
        require(exports[0].macro.contains("A section") && !exports[0].macro.contains("B section") &&
                exports[1].macro.contains("B section") && !exports[1].macro.contains("A section"),
                "grandMA2 cue labels leaked across songs");
        for (const auto &item : exports)
            for (const auto *excluded : {"Outside", "Tempo", "Linked region", "Legacy unified boundary", "Boundary"})
                require(!item.macro.contains(excluded) && !item.timecode.contains(excluded),
                        "grandMA2 exported a marker outside its eligible scope");
        const auto plan = ResolumeComposition::plan(lighting, "Scoped composition");
        require(plan.decks.size() == 2 && plan.decks.begin()->second.columns.size() == 6 && plan.decks.rbegin()->second.columns.size() == 3,
                "Resolume composition did not preserve the filtered columns");
    });
    test("Lighting output names are ASCII and preserve cue positions mappings and unique export files", [] {
        const std::vector<std::pair<String, String>> examples{
            {String::fromUTF8("$ Refrão"), "Refrao"},
            {String::fromUTF8("Ação ç Ç"), "Acao c C"},
            {String::fromUTF8("  \"Intro\" & <Parte> / \\ 🎶  "), "Intro Parte"},
            {String::fromUTF8("* Solo — 2_a"), "Solo - 2_a"},
            {String::fromUTF8("🎶<>$"), "Marcador"}};
        for (const auto &example : examples)
            require(Lighting::cleanName(example.first) == example.second,
                    "Export names must transliterate accents and remove incompatible symbols");
        auto project = fixture(); auto &song = project.songs.front();
        project.name = utf8(String::fromUTF8("Show Açúcar 🎶"));
        song.parts[0].name = utf8(String::fromUTF8("Ação")); song.parts[1].name = "Acao";
        song.markers->clear();
        for (size_t i = 0; i < examples.size(); ++i) {
            song.markers->push_back({uuid(), utf8(examples[i].first), 2. + (double)i, 0});
            song.markers->back().section = true; // Legacy names may retain the literal $ prefix.
        }
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Lighting lighting(session);
        const auto plan = ResolumeComposition::plan(lighting, text(project.name));
        require(plan.name == "Show Acucar" && plan.decks.size() == 2,
                "Resolume composition name bypassed output normalization");
        const auto exports = lighting.buildExports(false);
        require(exports.size() == 2 && exports[0].stem != exports[1].stem,
                "Names that normalize identically overwrote another music's export files");
        require(exports[0].stem == "Acao" && exports[1].stem == "Acao-2",
                "Export filenames are not stable ASCII names");
        for (size_t i = 0; i < exports.size(); ++i) {
            const auto &item = exports[i]; const auto &deck = plan.decks.at((int)i + 1);
            require(item.region.name == "Acao" && deck.name == "Acao",
                    "Sequence and deck labels disagree after normalization");
            require(item.region.cues.front().name == "Inicio" && deck.columns.at(1) == "Inicio" &&
                    item.region.cues.front().position == song.parts[i].startTime,
                    "Cue/column one must always be Inicio at the region start");
            require(item.commands.contains("Label Sequence " + String(item.settings.sequence) + " Cue 1 \"Inicio\"") &&
                    item.timecode.contains("<Cue name=\"Inicio\">"),
                    "grandMA2 XML and macro labels disagree with the start cue");
            require(XmlDocument::parse(item.macro) != nullptr && XmlDocument::parse(item.timecode) != nullptr,
                    "Sanitized export produced invalid XML");
        }
        const auto maCSV = lighting.exportMapCSV(), resolumeCSV = lighting.resolumeMapCSV();
        for (size_t i = 0; i < examples.size(); ++i) {
            require(exports[0].region.cues[i + 1].name == examples[i].second &&
                    plan.decks.at(1).columns.at((int)i + 2) == examples[i].second,
                    "Markers must begin at column/cue two using the same sanitized label");
            require(maCSV.contains("\"" + examples[i].second + "\"") &&
                    resolumeCSV.contains("Acao / " + examples[i].second),
                    "CSV labels differ from composition/XML labels");
            require(text(project.songs[0].markers->at(i).name) == examples[i].first,
                    "Export normalization changed the project marker name");
        }
        const auto saved = JSON::toString(lighting.resolumeAssignments);
        lighting.saveSettings(); lighting.loadSettings();
        require(JSON::toString(lighting.resolumeAssignments) == saved,
                "Reloading saved names renumbered destination assignments");
        lighting.selected = {exports[1].region.id};
        require(lighting.buildExports(true).front().stem == exports[1].stem,
                "Partial export changed a duplicate-name filename");
        require(session.project().name == project.name && session.project().songs[0].parts[0].name == song.parts[0].name,
                "Export normalization modified project or region names");
        lighting.resolumeRegions[0].name = String::fromUTF8("🎶");
        const auto fallback = ResolumeComposition::plan(lighting, String::fromUTF8("🎶"));
        require(fallback.name == "Projeto CatLive" && fallback.decks.at(1).name == "Musica",
                "Symbol-only composition/deck labels must never be empty");
    });
    test("Lighting mappings preserve destinations and reject orphan marker assignments and regionless timelines", [] {
        auto project = fixture(); const auto regions = Lighting::buildResolumeRegions(project);
        auto saved = object();
        put(saved, Identifier("region:" + text(regions[0].id)), "4:0");
        put(saved, Identifier("marker:" + text(regions[0].cues[1].id)), "4:7");
        const auto outside = std::find_if(project.songs[0].markers->begin(), project.songs[0].markers->end(),
                                          [](const auto &m) { return m.name == "Outside"; })->id;
        put(saved, Identifier("marker:" + text(outside)), "4:99");
        const auto mapped = Lighting::buildResolumeAssignments(regions, saved, true);
        require(get(mapped, Identifier("region:" + text(regions[0].id))).toString() == "4:0" &&
                get(mapped, Identifier("marker:" + text(regions[0].cues[1].id))).toString() == "4:7",
                "Scope filtering changed an existing valid deck/column");
        require(get(mapped, Identifier("marker:" + text(outside))).isVoid(), "Stale mapping reintroduced an outside marker");
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Lighting lighting(session);
        const auto first = lighting.buildExports(false);
        lighting.selected = {first.back().region.id};
        const auto partial = lighting.buildExports(true);
        require(partial.size() == 1 && partial[0].settings.executor == first.back().settings.executor &&
                partial[0].settings.sequence == first.back().settings.sequence,
                "Selecting one song renumbered its executor/sequence");
        auto multiple = project; multiple.songs.push_back(fixture().songs.front());
        session.restoreSnapshot(ProjectCodec::encode(multiple)); lighting.refresh();
        require(lighting.regions.size() == 4, "Multiple timelines lost a leaf song");
        const auto &secondTimeline = lighting.regions[2];
        require(secondTimeline.songId == multiple.songs[1].id && secondTimeline.start > multiple.songs[0].duration &&
                secondTimeline.localStart == 0, "grandMA2 lost the reserved absolute MTC offset");
        for (const auto &cue : secondTimeline.cues)
            require(cue.position >= secondTimeline.start && cue.position < secondTimeline.end,
                    "A cue escaped its song after applying the absolute MTC offset");
        require(lighting.resolumeRegions[2].start == 0,
                "grandMA2 absolute offsets leaked into local Resolume deck positions");
        project.songs[0].parts.clear();
        session.restoreSnapshot(ProjectCodec::encode(project)); lighting.refresh();
        require(lighting.regions.empty() && lighting.resolumeRegions.empty() && lighting.buildExports(false).empty(),
                "A regionless timeline exported arbitrary markers as an invented song");
    });
}
}
