#include "Lighting.h"
#include <windows.h>
#include <winnls.h>
namespace catlive {
namespace {
String xml(String value) {
    return value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&apos;");
}
String header(const String &name, const String &type) {
    return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<?xml-stylesheet type=\"text/xsl\" "
           "href=\"styles/" +
           type +
           "@sheet.xsl\"?>\r\n"
           "<MA xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
           "xmlns=\"http://schemas.malighting.de/grandma2/xml/MA\" "
           "xsi:schemaLocation=\"http://schemas.malighting.de/grandma2/xml/MA "
           "http://schemas.malighting.de/grandma2/xml/3.9.61/MA.xsd\" major_vers=\"3\" "
           "minor_vers=\"9\" "
           "stream_vers=\"61\">\r\n"
           "  <Info datetime=\"" +
           Time::getCurrentTime().toISO8601(false).upToFirstOccurrenceOf("Z", false, false) +
           "\" showfile=\"" + xml(name) + "\" />\r\n";
}
void require(bool ok, const String &message) {
    if (!ok)
        throw std::runtime_error(utf8(message));
}
String csv(String s) { return "\"" + s.replace("\"", "\"\"") + "\""; }
int offsetValue(const var &value) {
    auto string = value.toString();
    if (string.isEmpty() || !string.containsOnly("0123456789"))
        return -1;
    auto n = string.getLargeIntValue();
    return n >= 0 && n < 9999 ? (int)n : -1;
}
} // namespace
Lighting::Lighting(Session &value) : Thread("CatLive MTC"), session(value) {
    loadSettings();
    startThread(Thread::Priority::high);
}
Lighting::~Lighting() {
    alive.reset();
    signalThreadShouldExit();
    stopThread(3000);
}
String Lighting::cleanName(const String &value, String fallback) {
    auto input = value.toWideCharPointer();
    int size = NormalizeString(NormalizationKD, input, -1, nullptr, 0);
    std::vector<wchar_t> output((size_t)std::max(1, size));
    if (size > 0)
        NormalizeString(NormalizationKD, input, -1, output.data(), size);
    String result;
    bool space = false;
    auto normal = size > 0 ? String(output.data()) : value;
    for (auto c : normal) {
        if (c >= 0x300 && c <= 0x36f)
            continue;
        if ((c >= 0x2010 && c <= 0x2015) || c == 0x2212)
            c = '-';
        bool keep = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                    c == '_' || c == '-';
        if (keep) {
            if (space && result.isNotEmpty())
                result += " ";
            result += String::charToString(c);
            space = false;
        } else
            space = true;
    }
    if (result.isEmpty())
        return fallback.isEmpty() ? String() : cleanName(fallback, {});
    return result.substring(0, 96).trim();
}
String Lighting::safeStem(const String &value) {
    auto stem = cleanName(value, "Projeto VS Hook");
    auto lower = stem.toLowerCase();
    if (lower == "con" || lower == "prn" || lower == "aux" || lower == "nul" ||
        (lower.length() == 4 && (lower.startsWith("com") || lower.startsWith("lpt")) &&
         lower[3] >= '1' && lower[3] <= '9'))
        stem = "_" + stem;
    return stem.substring(0, 96);
}
String Lighting::triggerTime(double seconds) {
    auto t = (int64)std::llround(std::max(0.0, seconds) * 100);
    return String(t / 360000) + "H" + String(t / 6000 % 60) + "M" + String(t / 100 % 60) + "." +
           String(t % 100).paddedLeft('0', 2) + "S";
}
var Lighting::buildAssignments(const std::vector<LightingRegion> &regions, const var &saved,
                               bool includeMissing) {
    auto result = object();
    std::set<int> occupied;
    if (auto *o = saved.getDynamicObject())
        for (const auto &property : o->getProperties()) {
            auto key = property.name.toString();
            auto offset = offsetValue(property.value);
            if (key.startsWith("region:") && offset >= 0 && occupied.insert(offset).second)
                put(result, Identifier(key), offset);
        }
    int next = occupied.empty() ? 0 : *occupied.rbegin() + 1;
    if (includeMissing)
        for (const auto &region : regions) {
            auto key = Identifier("region:" + text(region.id));
            if (!get(result, key).isVoid())
                continue;
            require(next < 9999,
                    String::fromUTF8("O mapa grandMA2 atingiu o limite de 9.999 músicas."));
            put(result, key, next++);
        }
    return result;
}
void Lighting::loadSettings() {
    auto raw = get(session.original, "windowsLighting");
    selectionInitialised = false;
    selected.clear();
    mapCommitted = flag(raw, "committed");
    assignments = get(raw, "assignments", object()).clone();
    starts = get(raw, "starts", object()).clone();
    auto ma = get(raw, "grandMA2");
    settings.sequence = (int)num(ma, "sequence", 1);
    settings.page = (int)num(ma, "page", 1);
    settings.executor = (int)num(ma, "executor", 1);
    settings.timecode = (int)num(ma, "timecode", 1);
    settings.slot = (int)num(ma, "slot", 2);
    host = str(raw, "resolumeHost", "127.0.0.1");
    port = (int)num(raw, "resolumePort", 7000);
    webPort = 8080;
    includeMarkers = flag(raw, "includeMarkers", true);
    auto resolume = get(session.original, "resolume");
    if (resolume.isObject()) {
        host = str(resolume, "host", host);
        port = (int)num(resolume, "oscPort", port);
        webPort = (int)num(resolume, "webPort", 8080);
        includeMarkers = flag(resolume, "includeMarkers", true);
        resolumeAssignments = get(resolume, "withMarkers", object()).clone();
        resolumeRegionsOnly = get(resolume, "regionsOnly", object()).clone();
        resolumeEnabled = flag(resolume, "enabled");
    } else {
        resolumeAssignments = object();
        resolumeRegionsOnly = object();
        resolumeEnabled = false;
    }
    refresh();
    if (resolumeEnabled)
        connectResolume();
}
void Lighting::saveSettings() {
    auto root = session.original.isObject() ? session.original.clone() : object();
    auto raw = get(root, "windowsLighting", object()).clone();
    auto ma = object();
    put(ma, "sequence", settings.sequence);
    put(ma, "page", settings.page);
    put(ma, "executor", settings.executor);
    put(ma, "timecode", settings.timecode);
    put(ma, "slot", settings.slot);
    put(raw, "grandMA2", ma);
    mapCommitted = true;
    put(raw, "committed", true);
    put(raw, "assignments", assignments.clone());
    put(raw, "starts", starts.clone());
    put(raw, "resolumeHost", host);
    put(raw, "resolumePort", port);
    put(raw, "includeMarkers", includeMarkers);
    put(root, "windowsLighting", raw);
    auto resolume = get(root, "resolume", object()).clone();
    put(resolume, "enabled", resolumeEnabled);
    put(resolume, "host", host);
    put(resolume, "oscPort", port);
    put(resolume, "webPort", webPort);
    put(resolume, "includeMarkers", includeMarkers);
    put(resolume, "withMarkers", resolumeAssignments.clone());
    put(resolume, "regionsOnly", resolumeRegionsOnly.clone());
    put(root, "resolume", resolume);
    session.original = root;
    session.dirty = true;
    session.notify();
}
void Lighting::refresh(bool assignMissing) {
    regions.clear();
    resolumeCues.clear();
    // Both exporters use the same leaf-song scope. Unified parent blocks and
    // markers in gaps never become a song, executor, deck or cue.
    resolumeRegions = buildResolumeRegions(session.project());
    if (!mapCommitted)
        starts = object();
    double nextStart = 0;
    if (auto *o = starts.getDynamicObject())
        for (const auto &entry : o->getProperties())
            nextStart = std::max(nextStart, num(entry.value, "end") + 60);
    for (const auto &song : session.project().songs) {
        auto key = Identifier(text(song.id));
        auto reservation = get(starts, key);
        double base = 0;
        if (session.project().songs.size() > 1) {
            if (reservation.isObject()) {
                base = num(reservation, "start");
                require(song.duration <= num(reservation, "end") - base,
                        String::fromUTF8("A música cresceu além do espaço MTC reservado. Crie um "
                                         "novo mapa após conferir "
                                         "o show de luz."));
            } else {
                base = std::ceil(nextStart);
                auto reserve = object();
                put(reserve, "start", base);
                put(reserve, "end", base + std::ceil(song.duration / 60 + 1) * 60);
                put(starts, key, reserve);
                nextStart = num(reserve, "end") + 60;
            }
        }
        for (const auto &source : resolumeRegions) if (source.songId == song.id) {
            auto region = source;
            region.start += base; region.end += base;
            for (auto &cue : region.cues) {
                cue.position += base;
            }
            regions.push_back(std::move(region));
        }
    }
    assignments = buildAssignments(regions, assignments, assignMissing);
    resolumeAssignments = buildResolumeAssignments(resolumeRegions, resolumeAssignments, true);
    resolumeRegionsOnly = buildResolumeAssignments(resolumeRegions, resolumeRegionsOnly, false);
    for (auto &r : regions) {
        r.offset = offsetValue(get(assignments, Identifier("region:" + text(r.id))));
    }
    for (auto &r : resolumeRegions) {
        for (size_t i = 0; i < r.cues.size(); ++i)
            if (i == 0 || includeMarkers) {
                auto key = Identifier((i == 0 ? "region:" : "marker:") +
                                      text(i == 0 ? r.id : r.cues[i].id));
                auto pair = StringArray::fromTokens(
                    get(includeMarkers ? resolumeAssignments : resolumeRegionsOnly, key).toString(),
                    ":", {});
                if (pair.size() == 2)
                    resolumeCues.emplace_back(r.songId, r.cues[i].position - r.start + r.localStart,
                                              pair[0].getIntValue() + 1, pair[1].getIntValue() + 1,
                                              r.start, r.end);
            }
    }
    if (!selectionInitialised) {
        for (auto &r : regions)
            selected.insert(r.id);
        selectionInitialised = true;
    }
}
StringArray Lighting::macroCommands(const LightingRegion &r, const MASettings &s,
                                    const String &stem) {
    StringArray commands{"SelectDrive 1", "ClearAll"};
    int index = 1;
    for (const auto &cue : r.cues) {
        auto prefix = "Sequence " + String(s.sequence) + " Cue " + String(index++);
        commands.add("Store " + prefix + " /nc");
        commands.add("Label " + prefix + " \"" + cleanName(cue.name) + "\"");
        commands.add("Assign " + prefix + " /Trig=Timecode /TrigTime=" +
                     triggerTime(std::round(cue.position * 30) / 30));
    }
    commands.add("Label Sequence " + String(s.sequence) + " \"" + cleanName(r.name) + "\"");
    commands.add("Assign Sequence " + String(s.sequence) + " At Executor " + String(s.page) + "." +
                 String(s.executor) + " /o");
    commands.add("Import \"" + stem + "-timecode\" At Timecode " + String(s.timecode));
    commands.add("Assign Timecode " + String(s.timecode) + " /Slot=" + String(s.slot));
    commands.add("Assign TimecodeSlot " + String(s.slot) + " /PreRoll=0");
    commands.add("Assign TimecodeSlot " + String(s.slot) + " /AfterRoll=0");
    commands.add("Assign Timecode " + String(s.timecode) + " /AutoStart=On");
    commands.add("Assign Timecode " + String(s.timecode) + " /StatusCall=On");
    commands.add("Assign Timecode " + String(s.timecode) + " /SwitchOff=\"Keep Playbacks\"");
    commands.add("Label Timecode " + String(s.timecode) + " \"" + cleanName(r.name) + "\"");
    commands.add("Go Timecode " + String(s.timecode));
    return commands;
}
String Lighting::macroXML(const String &show, const String &name, const StringArray &commands) {
    auto result = header(cleanName(show, "Projeto VS Hook"), "macro") +
                  "  <Macro index=\"0\" name=\"" + xml(cleanName(name)) + "\">\r\n";
    for (int i = 0; i < commands.size(); ++i)
        result += "    <Macroline index=\"" + String(i) + "\">\r\n      <text>" + xml(commands[i]) +
                  "</text>\r\n    </Macroline>\r\n";
    return result + "  </Macro>\r\n</MA>\r\n";
}
String Lighting::timecodeXML(const LightingRegion &r, const std::vector<LightingRegion> &all,
                             const MASettings &s) {
    struct Event {
        int64 frame;
        int cue;
        String name;
    };
    std::vector<Event> events;
    int cue = 1;
    double end = 0;
    for (auto &c : r.cues)
        events.push_back({(int64)std::llround(c.position * 30), cue++, cleanName(c.name)});
    for (auto &other : all) {
        end = std::max(end, other.end);
        if (other.id != r.id)
            events.push_back({(int64)std::llround(other.start * 30), 0, {}});
    }
    std::stable_sort(events.begin(), events.end(), [](auto &a, auto &b) {
        return a.frame == b.frame ? a.cue < b.cue : a.frame < b.frame;
    });
    auto length =
        std::max((int64)std::ceil(end * 30), events.empty() ? int64(0) : events.back().frame + 30);
    auto result = header(cleanName(r.name), "timecode") + "  <Timecode index=\"" +
                  String(s.timecode - 1) + "\" name=\"" + xml(cleanName(r.name)) +
                  "\" slot=\"TC Slot " + String(s.slot) + "\" frame_format=\"30 FPS\" lenght=\"" +
                  String(length) +
                  "\" offset=\"0\">\r\n"
                  "    <Track index=\"0\" active=\"true\" expanded=\"true\">\r\n      <Object "
                  "name=\"Executor " +
                  String(s.page) + "." + String(s.executor) +
                  "\">\r\n        <No>30</No>\r\n        <No>1</No>\r\n        <No>" +
                  String(s.page) + "</No>\r\n        <No>" + String(s.executor) +
                  "</No>\r\n      </Object>\r\n      <SubTrack index=\"0\">\r\n";
    for (size_t i = 0; i < events.size(); ++i) {
        auto &e = events[i];
        auto prefix = "        <Event index=\"" + String((int)i) + "\" time=\"" + String(e.frame) +
                      "\" command=\"";
        if (e.cue == 0)
            result += prefix + "Off\" pressed=\"true\" />\r\n";
        else
            result += prefix + "Goto\" pressed=\"true\" step=\"" + String(e.cue) +
                      "\">\r\n          <Cue name=\"" + xml(e.name) + "\">\r\n            <No>" +
                      String(s.page) + "</No>\r\n            <No>" + String(s.executor) +
                      "</No>\r\n            <No>" + String(e.cue) +
                      "</No>\r\n          </Cue>\r\n        </Event>\r\n";
    }
    return result +
           "      </SubTrack>\r\n      <SubTrack index=\"1\" fader_command=\"Master\">\r\n     "
           "   <Event index=\"0\" fader_level=\"1\" />\r\n      </SubTrack>\r\n    "
           "</Track>\r\n  </Timecode>\r\n</MA>\r\n";
}
std::vector<MAExport> Lighting::buildExports(bool selectedOnly) const {
    for (int v : {settings.sequence, settings.page, settings.executor, settings.timecode})
        require(
            v >= 1 && v <= 9999,
            String::fromUTF8("Sequence, página, executor e timecode devem estar entre 1 e 9999."));
    require(settings.slot >= 1 && settings.slot <= 8, "O slot MTC deve estar entre 1 e 8.");
    StringArray base, reserved, used{"00-vs-hook-instalar-tudo"};
    for (auto &r : regions) {
        auto stem = safeStem(r.name);
        base.add(stem);
        reserved.add(stem.toLowerCase());
    }
    std::vector<MAExport> result;
    for (size_t i = 0; i < regions.size(); ++i) {
        const auto &r = regions[i];
        require(r.end <= 86400, "O projeto ultrapassa o limite de 24 horas do MTC.");
        auto stem = base[(int)i];
        int occurrence = 2;
        while (used.contains(stem.toLowerCase()) ||
               (stem != base[(int)i] && reserved.contains(stem.toLowerCase()))) {
            auto suffix = "-" + String(occurrence++);
            stem = base[(int)i].substring(0, 96 - suffix.length()).trimEnd() + suffix;
        }
        used.add(stem.toLowerCase());
        if (selectedOnly && !selected.count(r.id))
            continue;
        require(r.offset >= 0, "Mapa grandMA2 incompleto.");
        MAExport e;
        e.region = r;
        e.settings = settings;
        e.settings.sequence += r.offset;
        e.settings.executor += r.offset;
        e.settings.timecode += r.offset;
        e.stem = stem;
        require(e.settings.sequence <= 9999 && e.settings.executor <= 9999 &&
                    e.settings.timecode <= 9999,
                String::fromUTF8("Numeração inicial sem espaço para todas as músicas."));
        e.commands = macroCommands(r, e.settings, stem);
        e.macro = macroXML(r.name, r.name, e.commands);
        e.timecode = timecodeXML(r, regions, e.settings);
        result.push_back(std::move(e));
    }
    return result;
}
String Lighting::exportMapCSV() const {
    String result = String::fromUTF8(
        "Música,Sequence,Página,Executor,Timecode,Slot,Cue,Nome,Timecode 30 FPS\r\n");
    for (const auto &e : buildExports(false))
        for (size_t i = 0; i < e.region.cues.size(); ++i) {
            const auto &c = e.region.cues[i];
            result += csv(e.region.name) + "," + String(e.settings.sequence) + "," +
                      String(e.settings.page) + "," + String(e.settings.executor) + "," +
                      String(e.settings.timecode) + "," + String(e.settings.slot) + "," +
                      String((int)i + 1) + "," + csv(c.name) + "," + clockText(c.position, true) +
                      ":" + String((int)std::llround(c.position * 30) % 30).paddedLeft('0', 2) +
                      "\r\n";
        }
    return result;
}
var Lighting::buildResolumeAssignments(const std::vector<LightingRegion> &regions, const var &saved,
                                       bool markers) {
    auto result = object();
    std::set<int> decks;
    auto parse = [](const var &value) {
        auto pair = StringArray::fromTokens(value.toString(), ":", {});
        if (pair.size() != 2 || pair[0].isEmpty() || pair[1].isEmpty() ||
            !pair[0].containsOnly("0123456789") || !pair[1].containsOnly("0123456789"))
            return std::pair<int, int>{-1, -1};
        const auto deck = pair[0].getLargeIntValue(), column = pair[1].getLargeIntValue();
        if (deck < 0 || column < 0 || deck >= 99999 || column >= 99999)
            return std::pair<int, int>{-1, -1};
        return std::pair<int, int>{(int)deck, (int)column};
    };
    std::vector<const LightingRegion *> ordered;
    for (const auto &region : regions)
        ordered.push_back(&region);
    std::stable_sort(ordered.begin(), ordered.end(), [&](auto *a, auto *b) {
        auto left = parse(get(saved, Identifier("region:" + text(a->id)))).first,
             right = parse(get(saved, Identifier("region:" + text(b->id)))).first;
        return (left < 0 ? INT_MAX : left) < (right < 0 ? INT_MAX : right);
    });
    for (const auto *region : ordered) {
        auto key = Identifier("region:" + text(region->id));
        const auto assigned = parse(get(saved, key));
        if (assigned.first >= 0 && assigned.second == 0 && decks.insert(assigned.first).second)
            put(result, key, String(assigned.first) + ":0");
    }
    int next = decks.empty() ? 0 : *decks.rbegin() + 1;
    for (const auto &region : regions) {
        auto key = Identifier("region:" + text(region.id));
        if (get(result, key).isVoid()) {
            require(next < 99999, "Resolume deck limit reached.");
            put(result, key, String(next++) + ":0");
        }
    }
    if (markers)
        for (const auto &region : regions) {
            const auto deck = parse(get(result, Identifier("region:" + text(region.id)))).first;
            std::set<int> columns{0};
            for (size_t i = 1; i < region.cues.size(); ++i) {
                auto key = Identifier("marker:" + text(region.cues[i].id));
                auto assigned = parse(get(saved, key));
                if (assigned.first == deck && assigned.second > 0 &&
                    columns.insert(assigned.second).second)
                    put(result, key, String(deck) + ":" + String(assigned.second));
            }
            int nextColumn = *columns.rbegin() + 1;
            for (size_t i = 1; i < region.cues.size(); ++i) {
                auto key = Identifier("marker:" + text(region.cues[i].id));
                if (get(result, key).isVoid()) {
                    require(nextColumn < 99999, "Resolume column limit reached.");
                    put(result, key, String(deck) + ":" + String(nextColumn++));
                }
            }
        }
    return result;
}
std::vector<LightingRegion> Lighting::buildResolumeRegions(const jaras::Project &project) {
    std::vector<LightingRegion> result;
    for (const auto &song : project.songs) {
        std::set<ID> parents;
        for (const auto &part : song.parts)
            if (part.parentRegionID)
                parents.insert(*part.parentRegionID);
        std::vector<LightingRegion> regions;
        for (const auto &part : song.parts)
            if (!parents.count(part.id)) {
                LightingRegion r;
                r.id = part.id;
                r.songId = song.id;
                r.name = cleanName(text(part.name), "Musica");
                r.start = r.localStart = part.startTime;
                r.end = part.endTime;
                r.cues.push_back({"region-" + part.id, "Inicio", part.startTime, true});
                regions.push_back(std::move(r));
            }
        std::sort(regions.begin(), regions.end(), [](const auto &a, const auto &b) {
            return a.start == b.start ? a.id < b.id : a.start < b.start;
        });
        if (song.markers)
            for (const auto &marker : *song.markers)
                if (!marker.tempoBPM && !marker.sourceRegionID && !marker.unifiedRegionID) {
                    LightingRegion *owner = nullptr;
                    for (auto &r : regions)
                        if (marker.position > r.start + .0005 && marker.position < r.end - .0005 &&
                            (!owner || r.end - r.start < owner->end - owner->start))
                            owner = &r;
                    if (owner)
                        owner->cues.push_back(
                            {marker.id, cleanName(text(marker.name)), marker.position, false});
                }
        for (auto &region : regions) {
            std::sort(region.cues.begin() + 1, region.cues.end(), [](const auto &a, const auto &b) {
                return a.position == b.position ? a.id < b.id : a.position < b.position;
            });
            result.push_back(std::move(region));
        }
    }
    return result;
}
String Lighting::resolumeMapCSV() const {
    String output = "Music / Marker,Deck,Column\r\n";
    for (const auto &r : resolumeRegions)
        for (size_t i = 0; i < r.cues.size(); ++i)
            if (i == 0 || includeMarkers) {
                auto key = Identifier((i == 0 ? "region:" : "marker:") +
                                      text(i == 0 ? r.id : r.cues[i].id));
                auto pair = StringArray::fromTokens(
                    get(includeMarkers ? resolumeAssignments : resolumeRegionsOnly, key).toString(),
                    ":", {});
                if (pair.size() == 2)
                    output += csv(r.name + " / " + r.cues[i].name) + "," +
                              String(pair[0].getIntValue() + 1) + "," +
                              String(pair[1].getIntValue() + 1) + "\r\n";
            }
    return output;
}
String Lighting::exportGrandMA2(const File &folder, bool selectedOnly) {
    refresh();
    auto exports = buildExports(selectedOnly);
    require(!exports.empty(), String::fromUTF8("Selecione pelo menos uma música para exportar."));
    auto macros = folder.getChildFile("macros"), imports = folder.getChildFile("import");
    require(macros.createDirectory().wasOk() && imports.createDirectory().wasOk(),
            String::fromUTF8("Não foi possível criar as pastas de exportação."));
    StringArray commands{"SelectDrive 1"}, occupied;
    // Preflight the complete export before writing any XML.
    for (auto &e : exports) {
        occupied.add((e.stem + "-macro.xml").toLowerCase());
        for (auto &command : e.commands)
            if (command.toLowerCase() != "selectdrive 1")
                commands.add(command);
    }
    auto installer = safeStem("00-Importar tudo - " + text(session.project().name)) + "-macro.xml";
    int count = 2;
    while (occupied.contains(installer.toLowerCase()))
        installer = safeStem("00-Importar tudo - " + text(session.project().name)) + "-" +
                    String(count++) + "-macro.xml";
    for (auto &e : exports) {
        require(macros.getChildFile(e.stem + "-macro.xml").replaceWithText(e.macro),
                "Falha ao gravar macro.");
        require(imports.getChildFile(e.stem + "-timecode.xml").replaceWithText(e.timecode),
                "Falha ao gravar timecode.");
    }
    require(macros.getChildFile(installer).replaceWithText(
                macroXML(text(session.project().name),
                         "Importar tudo - " + text(session.project().name), commands)),
            "Falha ao gravar macro geral.");
    require(folder.getChildFile("Mapa grandMA2.csv").replaceWithText(exportMapCSV()),
            "Falha ao gravar mapa.");
    folder.getChildFile("LEIA-ME.txt")
        .replaceWithText(
            String::fromUTF8(
                "CatLive Windows — grandMA2\r\nCopie as pastas macros e import para o diretório de "
                "importação do grandMA2.\r\nImporte somente o macro ") +
            installer +
            String::fromUTF8(" e execute uma vez.\r\nConfigure a mesma saída MIDI virtual no "
                             "CatLive e entrada no "
                             "grandMA2, a 30 FPS, TC Slot ") +
            String(settings.slot) +
            String::fromUTF8(".\r\nO envio MTC segue o cursor principal; Sub Play não troca a "
                             "iluminação até ser "
                             "promovido.\r\nSalve o projeto .jl para levar o mapa estável a outro "
                             "computador.\r\n"));
    saveSettings();
    return installer;
}
bool Lighting::connectResolume() {
    ++oscGeneration;
    osc.disconnect();
    bool ok = osc.connect(host, port);
    error = ok ? String() : String::fromUTF8("Não foi possível abrir a saída OSC.");
    lastColumn = lastDeck = -1;
    lastResolumeClock = 0;
    return ok;
}
void Lighting::enableResolume(bool value) {
    if (resolumeEnabled && !value)
        osc.send("/composition/speed", String("a"), 1.0f);
    if (resolumeEnabled != value)
        ++oscGeneration;
    resolumeEnabled = value;
    lastResolumeClock = 0;
    lastColumn = lastDeck = -1;
}
bool Lighting::testResolume(int column) {
    if (!connectResolume())
        return false;
    auto address = "/composition/columns/" + String(column) + "/connect";
    bool ok = osc.send(address, (int32)1);
    Timer::callAfterDelay(45, [this, weak = std::weak_ptr<int>(alive), address] {
        if (!weak.expired())
            osc.send(address, (int32)0);
    });
    if (!ok)
        error = "Falha ao enviar OSC.";
    return ok;
}
double Lighting::absolutePosition(const ID &song, double local) const {
    auto reservation = get(starts, Identifier(text(song)));
    return local + (reservation.isObject() ? num(reservation, "start") : 0);
}
void Lighting::update(const jaras::TransportState &state) {
    mtcPosition = absolutePosition(state.songId.value_or(""), state.position);
    mtcBase = absolutePosition(state.songId.value_or(""), 0);
    if (mtcPlaying.load() != state.playing)
        notify();
    mtcPlaying = state.playing;
    if (!resolumeEnabled) {
        wasPlaying = false;
        lastResolumeClock = 0;
        return;
    }
    const auto now = Time::getMillisecondCounterHiRes() / 1000.;
    const bool jump =
        wasPlaying && state.playing && lastResolumeClock > 0 &&
        (state.position < lastResolumePosition - .08 ||
         state.position > lastResolumePosition + std::max(.35, now - lastResolumeClock + .25));
    if (state.playing != wasPlaying || lastResolumeClock == 0)
        osc.send("/composition/speed", String("a"), state.playing ? 1.0f : 0.0f);
    lastResolumePosition = state.position;
    lastResolumeClock = now;
    wasPlaying = state.playing;
    if (!state.songId)
        return;
    int deck = -1, column = -1;
    double best = -1;
    for (auto &cue : resolumeCues)
        if (std::get<0>(cue) == *state.songId && std::get<1>(cue) <= state.position + .0001 &&
            std::get<1>(cue) >= best && state.position >= std::get<4>(cue) - .0005 &&
            state.position < std::get<5>(cue) - .0005) {
            best = std::get<1>(cue);
            deck = std::get<2>(cue);
            column = std::get<3>(cue);
        }
    if (deck < 0)
        return;
    bool changedDeck = deck != lastDeck;
    if (changedDeck) {
        if (!osc.send("/composition/decks/" + String(deck) + "/select", (int32)1))
            error = "Falha ao selecionar deck Resolume.";
        lastDeck = deck;
        lastColumn = -1;
    }
    if (column != lastColumn || jump) {
        auto generation = ++oscGeneration;
        auto weak = std::weak_ptr<int>(alive);
        auto address = "/composition/columns/" + String(column) + "/connect";
        Timer::callAfterDelay(changedDeck ? 70 : 0, [this, weak, generation, address] {
            if (weak.expired() || generation != oscGeneration || !resolumeEnabled)
                return;
            if (!osc.send(address, (int32)1))
                error = "Falha OSC.";
            Timer::callAfterDelay(45, [this, weak, address] {
                if (!weak.expired())
                    osc.send(address, (int32)0);
            });
        });
        lastColumn = column;
    }
}
void Lighting::setMidiOutput(const String &identifier) {
    const ScopedLock lock(midiLock);
    midi.reset();
    midiIdentifier = identifier;
    if (identifier.isNotEmpty()) {
        midi = MidiOutput::openDevice(identifier);
        if (!midi) {
            midiIdentifier.clear();
            throw std::runtime_error("Não foi possível abrir a saída MIDI.");
        }
    }
}
void Lighting::run() {
    int piece = 0;
    int frame = 0, sec = 0, min = 0, hour = 0;
    bool previous = false;
    double lastPosition = 0, next = Time::getMillisecondCounterHiRes();
    while (!threadShouldExit()) {
        if (!mtcEnabled.load()) {
            wait(100);
            next = Time::getMillisecondCounterHiRes();
            previous = false;
            continue;
        }
        auto now = Time::getMillisecondCounterHiRes();
        if (now < next) {
            wait(1);
            continue;
        }
        next += 1000.0 / 120;
        if (now - next > 100)
            next = now + 1000.0 / 120;
        const auto audible = session.audio.presentationState();
        const bool active = mtcEnabled.load() && mtcPlaying.load() && audible.playing;
        const double position = mtcPlaying.load() ? audible.position + mtcBase.load()
                                                  : mtcPosition.load();
        const ScopedLock lock(midiLock);
        if (midi && (active || std::abs(position - lastPosition) > .0001)) {
            const int64 frames = (int64)std::llround(std::max(0.0, position) * 30);
            if (piece == 0) {
                frame = (int)(frames % 30);
                sec = (int)(frames / 30 % 60);
                min = (int)(frames / 1800 % 60);
                hour = (int)(frames / 108000 % 24);
            }
            if ((!previous && active) || std::abs(position - lastPosition) > .2 || !active) {
                frame = (int)(frames % 30);
                sec = (int)(frames / 30 % 60);
                min = (int)(frames / 1800 % 60);
                hour = (int)(frames / 108000 % 24);
                midi->sendMessageNow(
                    MidiMessage::fullFrame(hour, min, sec, frame, MidiMessage::fps30));
                piece = 0;
            }
            const int parts[]{frame & 15, frame >> 4, sec & 15,  sec >> 4,
                              min & 15,   min >> 4,   hour & 15, (hour >> 4) | 6};
            if (active) {
                midi->sendMessageNow(MidiMessage::quarterFrame(piece, parts[piece]));
                piece = (piece + 1) % 8;
            }
        }
        previous = active;
        lastPosition = position;
    }
}
} // namespace catlive
