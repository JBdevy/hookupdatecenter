#include "ProjectMigration.h"
#include "MediaPath.h"
#include "VSHookMigration.h"
#include <deque>
namespace catlive {
namespace migration {
void require(bool condition, const String &message) {
    if (!condition)
        throw std::runtime_error(utf8(message));
}
jaras::Project emptyProject(const String &name) {
    jaras::Project project;
    project.id = uuid();
    project.masterColor = 0x414141;
    project.name = utf8(name);
    project.createdAt = project.updatedAt = utf8(Time::getCurrentTime().toISO8601(true));
    jaras::Song song;
    song.id = uuid();
    song.name = project.name;
    song.duration = 1;
    song.markers = std::vector<jaras::TimelineMarker>{};
    song.timeSettings = jaras::ProjectTimeSettings{};
    song.timeSettings->timebase = jaras::ProjectTimebase::relative;
    project.songs.push_back(song);
    project.setlists.push_back({uuid(), "Setlist", {song.id}});
    return project;
}
void finish(MigratedProject &result) {
    auto &song = result.project.songs.front();
    for (auto &track : song.tracks) {
        std::stable_sort(track.clips.begin(), track.clips.end(),
                         [](const auto &a, const auto &b) { return a.startTime < b.startTime; });
        for (auto &clip : track.clips)
            song.duration = std::max(song.duration, clip.startTime + clip.duration);
    }
    for (auto &part : song.parts)
        song.duration = std::max(song.duration, part.endTime);
    for (auto &marker : *song.markers)
        song.duration = std::max(song.duration, marker.position);
    if (song.parts.empty()) {
        jaras::Part part;
        part.id = uuid();
        part.name = song.name;
        part.endTime = song.duration;
        song.parts.push_back(part);
    }
    jaras::orderSpecialTracks(result.project);
    jaras::synchronizeRegionOwnership(result.project);
    jaras::validate(result.project);
}
} // namespace migration
File saveMigratedProject(const MigratedProject &result, const File &selection) {
    using migration::require;
    auto selected = selection.withFileExtension("jl");
    auto parent = selected.getParentDirectory();
    require(parent.createDirectory().wasOk(), "Cannot create the destination directory.");
    auto folder = parent.getNonexistentChildFile(selected.getFileNameWithoutExtension(), "", true);
    require(folder.createDirectory().wasOk(), "Cannot create the project directory.");
    for (const auto &entry : result.media) {
        if (entry.second == File())
            continue; // Keep offline references for relinking, as on Mac.
        auto target = ProjectCodec::resolveMedia(folder, entry.first);
        require(target.getParentDirectory().createDirectory().wasOk() &&
                    entry.second.copyFileTo(target),
                "Could not copy media: " + entry.second.getFileName());
    }
    auto raw = ProjectCodec::encode(result.project, object());
    // Imported connection assignments use the same original-document storage
    // as Lighting, so later user edits are not overwritten by a stale core copy.
    if (result.project.resolumeJSON) put(raw, "resolume", JSON::parse(text(*result.project.resolumeJSON)));
    put(raw, "importedTimeline", true);
    auto document = folder.getChildFile(selected.getFileName());
    ProjectCodec::write(document, raw);
    return document;
}
namespace {
using migration::require;
struct RppChunk {
    StringArray header;
    std::vector<StringArray> lines;
    StringArray notes;
    std::vector<std::unique_ptr<RppChunk>> children;
    StringArray line(const String &key) const {
        for (const auto &row : lines)
            if (row[0] == key)
                return row;
        return {};
    }
    String value(const String &key, int index = 1, String fallback = {}) const {
        auto row = line(key);
        return index < row.size() ? row[index] : fallback;
    }
    double number(const String &key, int index = 1, double fallback = 0) const {
        auto row = line(key);
        if (index >= row.size())
            return fallback;
        auto value = utf8(row[index]);
        char *end = nullptr;
        double result = std::strtod(value.c_str(), &end);
        require(end != value.c_str() && *end == 0 && std::isfinite(result),
                "REAPER: invalid numeric value.");
        return result;
    }
    const RppChunk *child(const String &key) const {
        for (const auto &node : children)
            if (node->header[0] == key)
                return node.get();
        return nullptr;
    }
};
StringArray rppTokens(const String &line) {
    StringArray result;
    int i = 0;
    while (i < line.length()) {
        if (CharacterFunctions::isWhitespace(line[i])) {
            ++i;
            continue;
        }
        auto quote = line[i];
        bool quoted = quote == '"' || quote == '\'' || quote == '`';
        if (quoted)
            ++i;
        int begin = i;
        while (i < line.length() &&
               (quoted ? line[i] != quote : !CharacterFunctions::isWhitespace(line[i])))
            ++i;
        result.add(line.substring(begin, i));
        if (quoted) {
            require(i < line.length(), "REAPER: unterminated quoted value.");
            ++i;
        }
    }
    return result;
}
std::unique_ptr<RppChunk> parseRpp(const File &file, StringArray *warnings = nullptr) {
    require(file.getSize() > 0 && file.getSize() <= 256 * 1024 * 1024,
            "REAPER: invalid project size.");
    auto lines = StringArray::fromLines(file.loadFileAsString());
    require(lines.size() <= 2000000, "REAPER: project is too large.");
    std::unique_ptr<RppChunk> root;
    std::vector<RppChunk *> stack;
    for (auto raw : lines) {
        try {
        auto line = raw.trim();
        if (line.isEmpty())
            continue;
        if (line.startsWithChar('<')) {
            require(stack.size() < 128, "REAPER: invalid chunk nesting.");
            auto node = std::make_unique<RppChunk>();
            node->header = rppTokens(line.substring(1));
            auto *ptr = node.get();
            require(!node->header.isEmpty(), "REAPER: invalid chunk.");
            if (stack.empty()) {
                require(!root && node->header[0] == "REAPER_PROJECT",
                        "Select a valid REAPER .rpp project.");
                root = std::move(node);
            } else
                stack.back()->children.push_back(std::move(node));
            stack.push_back(ptr);
        } else if (line == ">") {
            require(!stack.empty(), "REAPER: unexpected chunk end.");
            if (stack.back()->header[0] == "TAKE_INLINE")
                stack.pop_back();
            require(!stack.empty(), "REAPER: invalid take nesting.");
            stack.pop_back();
        } else {
            require(!stack.empty(), "REAPER: data outside project.");
            if (stack.back()->header[0] == "NOTES" && line.startsWithChar('|')) {
                stack.back()->notes.add(line.substring(1));
                continue;
            }
            if (stack.back()->header[0] == "VST" || stack.back()->header[0] == "BIN") {
                stack.back()->notes.add(line);
                continue;
            }
            auto row = rppTokens(line);
            if (row[0] == "TAKE" &&
                (stack.back()->header[0] == "ITEM" || stack.back()->header[0] == "TAKE_INLINE")) {
                if (stack.back()->header[0] == "TAKE_INLINE")
                    stack.pop_back();
                auto node = std::make_unique<RppChunk>();
                node->header = row;
                node->header.set(0, "TAKE_INLINE");
                auto *ptr = node.get();
                stack.back()->children.push_back(std::move(node));
                stack.push_back(ptr);
            } else
                stack.back()->lines.push_back(row);
        }

        } catch (const std::exception &error) {
            if (!warnings) throw;
            warnings->addIfNotAlreadyThere("REAPER line ignored: " + String::fromUTF8(error.what()));
            if (raw.trimStart().startsWithChar('<')) break;
        }
}
    require(root != nullptr, "REAPER: no readable project data was found.");
    if (!stack.empty()) {
        require(warnings != nullptr, "REAPER: incomplete project.");
        warnings->addIfNotAlreadyThere("REAPER: incomplete project; the available arrangement was recovered.");
    }
    return root;
}
std::optional<unsigned> rppColor(String text) {
    auto value = (uint32)text.getLargeIntValue();
    if (!(value & 0x1000000))
        return {};
    return ((value & 255) << 16) | (value & 0xff00) | ((value >> 16) & 255);
}
struct TempoMap {
    struct Point {
        double time = 0, bpm = 120, beat = 0;
        bool linear = false;
    };
    std::vector<Point> points;
    explicit TempoMap(const RppChunk &root, StringArray *warnings = nullptr) {
        double initial=120;
        try { initial=root.number("TEMPO",1,120); }
        catch (const std::exception &error) { if(!warnings)throw;warnings->addIfNotAlreadyThere("REAPER tempo ignored: "+String::fromUTF8(error.what())); }
        points.push_back({0, initial, 0, false});
        if (auto *tempo = root.child("TEMPOENVEX"))
            for (auto &row : tempo->lines)
                if (row[0] == "PT" && row.size() > 2)
                    points.push_back(
                        {row[1].getDoubleValue(), row[2].getDoubleValue(), 0, row[3] == "0"});
        std::stable_sort(points.begin(), points.end(),
                         [](auto &a, auto &b) { return a.time < b.time; });
        std::vector<Point> unique;
        for (auto point : points) {
            if (!(point.bpm>0 && std::isfinite(point.bpm) && std::isfinite(point.time))) {
                require(warnings != nullptr, "REAPER: invalid tempo.");
                warnings->addIfNotAlreadyThere("REAPER: invalid tempo point was ignored."); continue;
            }
            if (!unique.empty() && unique.back().time == point.time)
                unique.pop_back();
            unique.push_back(point);
        }
        if(unique.empty())unique.push_back({0,120,0,false});
        points = std::move(unique);
        for (size_t i = 1; i < points.size(); ++i) {
            auto &a = points[i - 1];
            auto &b = points[i];
            b.beat = a.beat + (b.time - a.time) * (a.linear ? (a.bpm + b.bpm) * .5 : a.bpm) / 60;
        }
    }
    double beat(double time) const {
        size_t i = 0;
        while (i + 1 < points.size() && points[i + 1].time <= time)
            ++i;
        auto &p = points[i];
        double e = time - p.time;
        double slope = p.linear && i + 1 < points.size() && e >= 0
                           ? (points[i + 1].bpm - p.bpm) / (points[i + 1].time - p.time)
                           : 0;
        return p.beat + (p.bpm * e + slope * e * e * .5) / 60;
    }
    double time(double beat) const {
        size_t i = 0;
        while (i + 1 < points.size() && points[i + 1].beat <= beat)
            ++i;
        auto &p = points[i];
        double e = beat - p.beat;
        double slope = p.linear && i + 1 < points.size() && e >= 0
                           ? (points[i + 1].bpm - p.bpm) / (points[i + 1].time - p.time)
                           : 0;
        return p.time +
               (std::abs(slope) < 1e-12
                    ? e * 60 / p.bpm
                    : 120 * e / (p.bpm + std::sqrt(std::max(0., p.bpm * p.bpm + 120 * slope * e))));
    }
};
jaras::MIDIItem rppMIDI(const RppChunk &source, const RppChunk &take, const RppChunk &item,
                        const jaras::AudioClip &clip, const TempoMap &tempo, const File &base,
                        StringArray &warnings) {
    std::vector<jaras::MIDINote> notes;
    double length = 0, ppq = source.number("HASDATA", 2, 960);
    require(ppq > 0 && ppq <= 1000000, "REAPER: invalid MIDI resolution.");
    struct Pending {
        double start;
        int velocity;
        bool muted;
    };
    std::map<int, std::deque<Pending>> active;
    if (source.value("FILE").isNotEmpty()) {
        auto path = source.value("FILE").replaceCharacter('\\', '/');
        auto file = File::isAbsolutePath(path) ? File(path) : base.getChildFile(path);
        FileInputStream input(file);
        MidiFile midi;
        require(input.openedOk() && midi.readFrom(input) && midi.getTimeFormat() > 0,
                "REAPER: missing or invalid MIDI source.");
        ppq = midi.getTimeFormat();
        for (int t = 0; t < midi.getNumTracks(); ++t) {
            auto sequence = *midi.getTrack(t);
            sequence.updateMatchedPairs();
            for (int i = 0; i < sequence.getNumEvents(); ++i) {
                auto *event = sequence.getEventPointer(i);
                length = std::max(length, event->message.getTimeStamp() / ppq);
                if (event->message.isNoteOn() && event->noteOffObject) {
                    jaras::MIDINote note;
                    note.id = uuid();
                    note.start = event->message.getTimeStamp() / ppq;
                    note.length = event->noteOffObject->message.getTimeStamp() / ppq - note.start;
                    note.pitch = event->message.getNoteNumber();
                    note.velocity = event->message.getVelocity();
                    note.channel = event->message.getChannel();
                    if (note.length > 0)
                        notes.push_back(note);
                }
            }
        }
    } else {
        double ticks = 0;
        for (auto &row : source.lines) {
            if (row[0].toLowerCase() != "e" && row[0].toLowerCase() != "em")
                continue;
            require(row.size() >= 4, "REAPER: incomplete MIDI event.");
            ticks += row[1].getDoubleValue();
            int status = row[2].getHexValue32(), pitch = row[3].getHexValue32(),
                velocity = row[4].getHexValue32();
            int kind = status & 0xf0, channel = (status & 15) + 1, key = channel * 128 + pitch;
            bool muted = row[0].containsIgnoreCase("m");
            require(pitch < 128 && velocity < 128 && std::abs(ticks) < 1e13,
                    "REAPER: invalid MIDI event.");
            if (kind == 0x90 && velocity > 0)
                active[key].push_back({ticks / ppq, velocity, muted});
            else if ((kind == 0x80 || kind == 0x90) && !active[key].empty()) {
                auto begin = active[key].front();
                active[key].pop_front();
                if (!begin.muted && !muted && ticks / ppq > begin.start)
                    notes.push_back({uuid(), begin.start, ticks / ppq - begin.start, pitch,
                                     begin.velocity, channel});
            } else if (kind != 0xb0 || pitch != 123)
                warnings.addIfNotAlreadyThere("MIDI controllers, program changes and SysEx are not "
                                              "migrated; review instrument settings.");
            require(notes.size() < 100000, "REAPER: too many MIDI notes.");
            length = std::max(length, ticks / ppq);
        }
    }
    double rate = clip.playbackRate, fixed = source.number("IGNTEMPO", 2, 120),
           startBeat = tempo.beat(clip.startTime);
    require(rate >= 1. / 32 && rate <= 32 && fixed > 0, "REAPER: invalid MIDI rate or tempo.");
    bool ignore = source.number("IGNTEMPO") != 0;
    double offset =
        take.line("SOFFS").size() > 2 ? take.number("SOFFS", 2)
        : ignore                      ? clip.sourceOffset * fixed / 60
                 : (startBeat - tempo.beat(clip.startTime - clip.sourceOffset / rate)) * rate;
    auto sourceBeat = [&](double time) {
        return offset +
               (ignore ? (time - clip.startTime) * fixed / 60 : tempo.beat(time) - startBeat) *
                   rate;
    };
    auto time = [&](double beat) {
        return ignore ? clip.startTime + (beat - offset) * 60 / fixed / rate
                      : tempo.time(startBeat + (beat - offset) / rate);
    };
    bool loop = item.number("LOOP") != 0 && length > 0;
    double endBeat = sourceBeat(clip.startTime + clip.duration);
    jaras::MIDIItem result;
    for (auto &note : notes) {
        double first = loop ? std::floor((offset - note.start - note.length) / length) + 1 : 0,
               last = loop ? std::ceil((endBeat - note.start) / length) - 1 : 0;
        require(std::isfinite(first) && std::isfinite(last) && last - first < 100000 &&
                    std::abs(first) < 1e12 && std::abs(last) < 1e12,
                "REAPER: too many MIDI repetitions.");
        for (int64 i = (int64)first; i <= (int64)last; ++i) {
            double shift = loop ? i * length : 0,
                   a = std::max(clip.startTime, time(note.start + shift)),
                   b = std::min(clip.startTime + clip.duration,
                                time(note.start + note.length + shift));
            if (b > a)
                result.notes.push_back({uuid(), (a - clip.startTime) * 2, (b - a) * 2, note.pitch,
                                        note.velocity, note.channel});
            require(result.notes.size() <= 100000, "REAPER: too many MIDI notes.");
        }
    }
    std::stable_sort(result.notes.begin(), result.notes.end(),
                     [](auto &a, auto &b) { return a.start < b.start; });
    warnings.addIfNotAlreadyThere("MIDI notes were imported. Choose an instrument in CatLive.");
    return result;
}
} // namespace
MigratedProject readReaperProject(const File &file) {
    MigratedProject result;
    auto root = parseRpp(file, &result.warnings);
    migration::VSHookMigration hook;
    if (auto *ext = root->child("EXTSTATE")) for (const auto &section : ext->children) {
        const auto name = section->header[0];
        if (name != "CHATGPT_REGION_PLAYLIST" && name != "VS_HOOK_MULTILOOPS" && name != "VS_HOOK_LOADER") continue;
        auto &values = hook.state[name];
        for (const auto &row : section->lines) if (row.size() >= 2) values[row[0]] = row.joinIntoString(" ", 1);
        for (const auto &binary : section->children) if (binary->header[0] == "BIN" && binary->header.size() == 2) {
            try {
            MemoryOutputStream decoded;
            require(Base64::convertFromBase64(decoded, binary->notes.joinIntoString("")), "Invalid VS Hook project metadata.");
            const auto *bytes = static_cast<const char *>(decoded.getData());
            auto size = decoded.getDataSize();
            while (size && bytes[size-1] == 0) --size;
            require(CharPointer_UTF8::isValidString(bytes, (int)size), "Invalid VS Hook project metadata UTF-8.");
            values[binary->header[1]] = String::fromUTF8(bytes, (int)size);

            } catch (const std::exception &error) { result.warnings.addIfNotAlreadyThere("VS Hook metadata ignored: " + String::fromUTF8(error.what())); }
}
    }
    result.project = migration::emptyProject(file.getFileNameWithoutExtension());
    auto &project = result.project;
    auto &song = project.songs.front();
    auto scalar = [&](const RppChunk &node, const String &key, int index=1, double fallback=0.) {
        try { return node.number(key,index,fallback); }
        catch (const std::exception &error) { result.warnings.addIfNotAlreadyThere("REAPER setting "+key+" ignored: "+String::fromUTF8(error.what())); return fallback; }
    };
    song.bpm = scalar(*root, "TEMPO", 1, 120);
    if (!(song.bpm>0)) {song.bpm=120;result.warnings.addIfNotAlreadyThere("REAPER: invalid initial tempo ignored; 120 BPM was used.");}
    const double beats=scalar(*root,"TEMPO",2,4),unit=scalar(*root,"TEMPO",3,4);
    song.beatsPerBar = beats>=1 && beats<=32 ? (int)beats : 4;
    song.beatUnit = unit>=1 && unit<=32 ? (int)unit : 4;
    if(beats!=song.beatsPerBar || unit!=song.beatUnit) result.warnings.addIfNotAlreadyThere("REAPER: invalid time signature ignored; defaults were used.");
    project.masterVolume = std::clamp(scalar(*root, "MASTER_VOLUME", 1, 1), 0., std::pow(10., .6));
    project.masterPan = std::clamp(scalar(*root, "MASTER_VOLUME", 2),-1.,1.);
    project.masterMute = ((int)scalar(*root, "MASTERMUTESOLO") & 1) != 0;
    TempoMap tempo(*root, &result.warnings);
    AudioFormatManager formats;
    registerAudioFormats(formats);
    std::map<String, std::string> references;
    std::vector<ID> folders;
    auto reference = [&](String path, bool video) {
        path = path.replaceCharacter('\\', '/');
        auto found = references.find(path);
        if (found != references.end())
            return found->second;
        auto candidate = existingMediaPath(
            File::isAbsolutePath(path) ? File(path) : file.getParentDirectory().getChildFile(path));
        String name = path.fromLastOccurrenceOf("/", false, false);
        if (name.isEmpty())
            name = path;
        require(name.isNotEmpty() && name != ".." && !name.containsChar(':'),
                "REAPER: invalid media filename.");
        auto relative = utf8(String(video ? "Videos/REAPER/" : "Stems/REAPER/") +
                             String(references.size() + 1) + "/" + name);
        references[path] = relative;
        result.media[relative] = candidate.existsAsFile() ? candidate : File();
        if (!candidate.existsAsFile())
            result.warnings.addIfNotAlreadyThere("Missing media: " + name);
        return relative;
    };
    for (auto &owned : root->children) {
        auto &node = *owned;
        if (node.header[0] != "TRACK")
            continue;
        jaras::Track track;
        track.id = uuid();
        if (node.header[1].isNotEmpty()) hook.tracks[node.header[1].toUpperCase()] = track.id;
        track.name = utf8(node.value("NAME", 1, "Track " + String(song.tracks.size() + 1)));
        track.volume = std::clamp(scalar(node, "VOLPAN", 1, 1), 0., std::pow(10., .6));
        track.pan = std::clamp(scalar(node, "VOLPAN", 2),-1.,1.);
        track.mute = scalar(node, "MUTESOLO") != 0;
        track.solo = scalar(node, "MUTESOLO", 2) != 0;
        track.phaseInverted = scalar(node, "IPHASE") != 0;
        track.color = rppColor(node.value("PEAKCOL"));
        if (!folders.empty())
            track.parentTrackID = folders.back();
        auto key =
            text(track.name).toLowerCase().retainCharacters("abcdefghijklmnopqrstuvwxyz0123456789");
        if (key == "teleprompter1" || key == "teleprompt1")
            track.role.id = "teleprompt";
        if (key == "teleprompter2" || key == "teleprompt2")
            track.role.id = "teleprompt2";
        if (key == "media")
            track.role.id = "video";
        if (key == "cifras")
            track.role.id = "chords";
        if (key == "timecode")
            track.role.id = "timecode";
        // Match the current Mac importer before validating special-track invariants.
        const bool importedVideo = track.role.id == "video";
        const auto specialName = jaras::fixedTrackName(track.role);
        if (!specialName.empty()) {
            track.name = specialName;
            track.parentTrackID.reset();
            track.color = track.role.id == "timecode" ? 0xffdc52u
                        : track.role.id == "chords" ? 0x529effu
                        : importedVideo ? 0xb47affu : 0x54ff93u;
            if (!importedVideo) track.solo = false;
            if (jaras::isTeleprompterRole(track.role) || track.role.id == "chords") track.mute = false;
            if (track.role.id == "timecode") {
                track.timecode.emplace(); track.importedTimecodeItems = true;
                track.patch = jaras::OutputPatch{-1,2};
            }
            // Video is hosted by a standard track on both desktop platforms.
            if (importedVideo) track.role.id = "other";
        }
        const double savedDelta=scalar(node,"ISBUS",2);
        int delta=savedDelta>=-1000 && savedDelta<=1 ? (int)savedDelta : 2;
        if (delta > 1 || delta < -(int)folders.size()) {
            result.warnings.addIfNotAlreadyThere("REAPER: invalid folder structure was ignored."); delta=0;
        }
        if (delta > 0) {
            if (!specialName.empty()) {
                result.warnings.addIfNotAlreadyThere("REAPER: special-track folder membership was ignored."); delta=0;
            } else folders.push_back(track.id);
        }
        if (node.child("FXCHAIN"))
            result.warnings.addIfNotAlreadyThere(
                "REAPER plug-ins require review in the imported project.");
        for (auto &itemOwned : node.children) {
            try {
            auto &item = *itemOwned;
            if (item.header[0] != "ITEM")
                continue;
            double start = item.number("POSITION"), duration = item.number("LENGTH");
            require(duration > 0 && std::isfinite(start + duration),
                    "REAPER: invalid item bounds.");
            if (start < 0) {
                result.warnings.addIfNotAlreadyThere(
                    "Items before the project start were ignored.");
                continue;
            }
            std::vector<const RppChunk *> takes;
            for (auto &take : item.children)
                if (take->header[0] == "TAKE" || take->header[0] == "TAKE_INLINE")
                    takes.push_back(take.get());
            if (item.child("SOURCE") || takes.empty())
                takes.insert(takes.begin(), &item);
            auto *active = takes.front();
            for (auto *take : takes)
                if (take->header.contains("SEL") || take->value("SEL") == "1")
                    active = take;
            for (auto *take : takes) {
            try {
                jaras::AudioClip clip;
                clip.id = uuid();
                clip.name = utf8(take->value("NAME", 1, item.value("NAME", 1, "Item")));
                clip.startTime = start;
                clip.duration = duration;
                clip.sourceOffset = take->number("SOFFS");
                clip.playbackRate = take->number("PLAYRATE", 1, 1);
                clip.pitchSemitones = take->number("PLAYRATE", 3);
                double gain = take->line("TAKEVOLPAN").isEmpty()
                                  ? take->number("VOLPAN", 1, item.number("VOLPAN", 1, 1)) *
                                        take->number("VOLPAN", 3, 1)
                                  : item.number("VOLPAN", 1, 1) * take->number("TAKEVOLPAN", 2, 1);
                clip.gain = std::abs(gain);
                clip.phaseInverted = gain < 0;
                clip.pan = take->line("TAKEVOLPAN").isEmpty() ? take->number("VOLPAN", 2)
                                                              : take->number("TAKEVOLPAN");
                clip.fadeIn = item.number("FADEIN", 2);
                clip.fadeOut = item.number("FADEOUT", 2);
                clip.muted =
                    item.number("MUTE") != 0 || (item.number("ALLTAKES") == 0 && take != active);
                int mode = (int)take->number("CHANMODE");
                clip.channelMode = mode == 2 ? 3 : mode == 3 ? 1 : mode == 4 ? 2 : 0;
                auto *source = take->child("SOURCE");
                if (!specialName.empty()) {
                    // Special items do not inherit audio-only take controls.
                    // This is the same branch used by the current Mac importer.
                    clip.gain.reset(); clip.pan.reset(); clip.phaseInverted.reset();
                    clip.fadeIn.reset(); clip.fadeOut.reset(); clip.channelMode.reset();
                    clip.pitchSemitones.reset(); clip.sourceOffset=0; clip.playbackRate=1;
                    const bool muted=clip.muted; clip.muted=false;
                    if (track.role.id == "timecode") {
                        require(source && source->header[1] == "LTC", String::fromUTF8("O item da pista Timecode não contém as configurações do gerador SMPTE. Use o gerador LTC/MTC do REAPER para migrar esse item."));
                        const int send=(int)source->number("SEND",1,1);
                        require(send==1 || send==2, String::fromUTF8("O gerador Timecode deve usar LTC ou MTC individualmente para migrar."));
                        require(take->number("PLAYRATE",1,1)==1, String::fromUTF8("Timecode com velocidade alterada não pode ser recriado com a mesma configuração."));
                        const auto userData=source->line("USERDATA");
                        for(int i=1;i<userData.size();++i) require(userData[i].getDoubleValue()==0, String::fromUTF8("Timecode com user bits personalizados ainda não é suportado pelo CatLive."));
                        jaras::TimecodeSettings tc; tc.mode=send==2 ? "mtc" : "ltc";
                        tc.frameRate=source->number("FRAMERATE",1,30); tc.offset=source->number("STARTTIME")+take->number("SOFFS");
                        clip.timecode=tc; clip.name=tc.mode=="ltc" ? "LTC" : "MTC"; clip.muted=muted;
                        if(track.clips.empty()) track.timecode=tc;
                    } else if (source && source->value("FILE").isNotEmpty() && (importedVideo || jaras::isTeleprompterRole(track.role))) {
                        clip.audioFile=jaras::AudioFile{reference(source->value("FILE"),true),{}};
                        clip.sourceOffset=take->number("SOFFS"); clip.playbackRate=take->number("PLAYRATE",1,1);
                    } else if (jaras::isTeleprompterRole(track.role) || track.role.id=="chords") {
                        auto *notes=item.child("NOTES"); if(!notes)notes=take->child("NOTES");
                        const auto value=notes ? notes->notes.joinIntoString("\n") : take->value("NAME");
                        clip.text=utf8(value); clip.name=utf8(value.upToFirstOccurrenceOf("\n",false,false));
                    }
                    track.clips.push_back(clip); continue;
                }
                double sectionStart = 0, sectionLength = 0;
                if (source && source->header[1] == "SECTION") {
                    sectionStart = source->number("STARTPOS");
                    sectionLength = source->number("LENGTH");
                    source = source->child("SOURCE");
                }
                if (source && source->value("FILE").isNotEmpty() && source->header[1] != "MIDI") {
                    auto path =
                        reference(source->value("FILE"), importedVideo ||
                                                             jaras::isTeleprompterRole(track.role));
                    clip.audioFile = jaras::AudioFile{path, {}};
                    clip.sourceOffset += sectionStart;
                    if (item.number("LOOP") != 0) {
                        double length = sectionLength;
                        if (length <= 0 && result.media[path] != File()) {
                            std::unique_ptr<AudioFormatReader> reader(
                                formats.createReaderFor(result.media[path]));
                            if (reader)
                                length = reader->lengthInSamples / reader->sampleRate;
                        }
                        if (length > 0) {
                            clip.loopStart = sectionStart;
                            clip.loopLength = length;
                        }
                    }
                } else if (source && source->header[1] == "MIDI") {
                    clip.midi = rppMIDI(*source, *take, item, clip, tempo,
                                        file.getParentDirectory(), result.warnings);
                    clip.sourceOffset = 0;
                    clip.playbackRate = 1;
                    clip.fadeIn.reset();
                    clip.fadeOut.reset();
                    clip.channelMode.reset();
                } else if (source && source->header[1] == "LTC") {
                    jaras::TimecodeSettings tc;
                    tc.mode = source->number("SEND", 1, 1) == 2 ? "mtc" : "ltc";
                    tc.frameRate = source->number("FRAMERATE", 1, 30);
                    tc.offset = source->number("STARTTIME") + clip.sourceOffset;
                    clip.timecode = tc;
                    track.timecode = tc;
                    track.importedTimecodeItems = true;
                } else if (auto *notes = item.child("NOTES"))
                    clip.text = utf8(notes->notes.joinIntoString("\n"));
                track.clips.push_back(clip);

            } catch (const std::exception &error) { result.warnings.addIfNotAlreadyThere("REAPER take ignored: " + String::fromUTF8(error.what())); }
}

            } catch (const std::exception &error) { result.warnings.addIfNotAlreadyThere("REAPER item ignored: " + String::fromUTF8(error.what())); }
}
        song.tracks.push_back(track);
        if (delta < 0)
            folders.resize(folders.size() + delta);
    }
    std::map<String, jaras::Part> pending;
    for (auto &row : root->lines)
        if (row[0] == "MARKER") {
            try {
            require(row.size() >= 5, "REAPER: invalid marker.");
            double time = row[2].getDoubleValue();
            auto color = rppColor(row[5]);
            if (row[4].getIntValue() & 1) {
                auto it = pending.find(row[1]);
                if (it == pending.end()) {
                    jaras::Part part;
                    part.id = uuid();
                    part.name = utf8(row[3].isEmpty() ? "Region " + row[1] : row[3]);
                    part.startTime = std::max(0., time);
                    part.color = color;
                    pending[row[1]] = part;
                } else {
                    auto part = it->second;
                    pending.erase(it);
                    part.endTime = time;
                    if (time > 0) {
                        require(time > part.startTime, "REAPER: invalid region length.");
                        song.parts.push_back(part);
                        hook.regions[row[1]] = part.id;
                    }
                }
            } else if (time >= 0) {
                jaras::TimelineMarker marker;
                marker.id = uuid();
                marker.name = utf8(row[3].isEmpty() ? "Marker " + row[1] : row[3]);
                marker.position = time;
                marker.color = color.value_or(0xc7ab40);
                song.markers->push_back(marker);
                hook.markers.push_back({row[1], marker});
            }

            } catch (const std::exception &error) { result.warnings.addIfNotAlreadyThere("REAPER marker ignored: " + String::fromUTF8(error.what())); }
}
    if (!pending.empty()) {
        result.warnings.addIfNotAlreadyThere("Incomplete REAPER regions were retained as start markers.");
        for (const auto &entry : pending) {
            jaras::TimelineMarker marker; marker.id=uuid(); marker.name=entry.second.name;
            marker.position=entry.second.startTime; marker.color=entry.second.color.value_or(0xc7ab40);
            song.markers->push_back(marker);
        }
    }
    hook.convertSpecial(song, result.warnings);
    if (const auto *envelope = root->child("TEMPOENVEX")) {
        int beats = song.beatsPerBar, unit = song.beatUnit;
        std::optional<jaras::TimelineMarker> initial;
        for (const auto &row : envelope->lines) if (row[0] == "PT") {
            try {
            require(row.size() >= 3, "REAPER: invalid tempo point.");
            const double position = row[1].getDoubleValue(), bpm = row[2].getDoubleValue();
            if (bpm < 60 || bpm > 300 || !std::isfinite(bpm)) {
                result.warnings.addIfNotAlreadyThere("Tempo points outside the CatLive tempo range were omitted; item positions in seconds are unchanged."); continue;
            }
            const auto signature = row[4].getIntValue();
            if (signature) { beats = signature & 0xffff; unit = (unsigned)signature >> 16; }
            jaras::TimelineMarker marker; marker.id=uuid(); marker.name=utf8(String::formatted("%g", bpm));
            marker.position=std::max(0.,position);marker.color=0xaaaaaa;marker.tempoBPM=bpm;
            marker.tempoBeats=beats;marker.tempoUnit=unit;marker.tempoTimebase="global";marker.tempoReferenceBPM=bpm;
            if(position<0)initial=marker;else song.markers->push_back(marker);
            if(row.size()>3&&row[3]!="1")result.warnings.addIfNotAlreadyThere("REAPER tempo ramps were imported as discrete tempo points; item positions in seconds are unchanged.");

            } catch (const std::exception &error) { result.warnings.addIfNotAlreadyThere("REAPER tempo point ignored: " + String::fromUTF8(error.what())); }
}
        if(initial&&!std::any_of(song.markers->begin(),song.markers->end(),[](const auto &m){return m.tempoBPM&&m.position==0;}))song.markers->push_back(*initial);
    }
    // Supply the fallback region before applying VS Hook's song-level settings.
    if (song.parts.empty()) {
        double end = 1;
        for (const auto &t : song.tracks) for (const auto &c : t.clips) end = std::max(end, c.startTime+c.duration);
        for (const auto &m : *song.markers) end = std::max(end, m.position);
        jaras::Part p; p.id=uuid();p.name=song.name;p.endTime=end;song.parts.push_back(p);
    }
    hook.apply(project, result.warnings);
    migration::finish(result);
    return result;
}
} // namespace catlive
