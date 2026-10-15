#include "ProjectMigration.h"
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
std::unique_ptr<RppChunk> parseRpp(const File &file) {
    require(file.getSize() > 0 && file.getSize() <= 256 * 1024 * 1024,
            "REAPER: invalid project size.");
    auto lines = StringArray::fromLines(file.loadFileAsString());
    require(lines.size() <= 2000000, "REAPER: project is too large.");
    std::unique_ptr<RppChunk> root;
    std::vector<RppChunk *> stack;
    for (auto raw : lines) {
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
    }
    require(root && stack.empty(), "REAPER: incomplete project.");
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
    explicit TempoMap(const RppChunk &root) {
        points.push_back({0, root.number("TEMPO", 1, 120), 0, false});
        if (auto *tempo = root.child("TEMPOENVEX"))
            for (auto &row : tempo->lines)
                if (row[0] == "PT" && row.size() > 2)
                    points.push_back(
                        {row[1].getDoubleValue(), row[2].getDoubleValue(), 0, row[3] == "0"});
        std::stable_sort(points.begin(), points.end(),
                         [](auto &a, auto &b) { return a.time < b.time; });
        std::vector<Point> unique;
        for (auto point : points) {
            require(point.bpm > 0 && std::isfinite(point.bpm), "REAPER: invalid tempo.");
            if (!unique.empty() && unique.back().time == point.time)
                unique.pop_back();
            unique.push_back(point);
        }
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
    auto root = parseRpp(file);
    MigratedProject result;
    result.project = migration::emptyProject(file.getFileNameWithoutExtension());
    auto &project = result.project;
    auto &song = project.songs.front();
    song.bpm = root->number("TEMPO", 1, 120);
    song.beatsPerBar = (int)root->number("TEMPO", 2, 4);
    song.beatUnit = (int)root->number("TEMPO", 3, 4);
    project.masterVolume = std::clamp(root->number("MASTER_VOLUME", 1, 1), 0., std::pow(10., .6));
    project.masterPan = root->number("MASTER_VOLUME", 2);
    project.masterMute = ((int)root->number("MASTERMUTESOLO") & 1) != 0;
    TempoMap tempo(*root);
    AudioFormatManager formats;
    formats.registerBasicFormats();
    std::map<String, std::string> references;
    std::vector<ID> folders;
    auto reference = [&](String path, bool video) {
        path = path.replaceCharacter('\\', '/');
        auto found = references.find(path);
        if (found != references.end())
            return found->second;
        auto candidate =
            File::isAbsolutePath(path) ? File(path) : file.getParentDirectory().getChildFile(path);
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
        track.name = utf8(node.value("NAME", 1, "Track " + String(song.tracks.size() + 1)));
        track.volume = std::clamp(node.number("VOLPAN", 1, 1), 0., std::pow(10., .6));
        track.pan = node.number("VOLPAN", 2);
        track.mute = node.number("MUTESOLO") != 0;
        track.solo = node.number("MUTESOLO", 2) != 0;
        track.phaseInverted = node.number("IPHASE") != 0;
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
        int delta = (int)node.number("ISBUS", 2);
        require(delta <= 1 && delta >= -(int)folders.size(), "REAPER: invalid folder structure.");
        if (delta > 0)
            folders.push_back(track.id);
        if (node.child("FXCHAIN"))
            result.warnings.addIfNotAlreadyThere(
                "REAPER plug-ins require review in the imported project.");
        for (auto &itemOwned : node.children) {
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
                double sectionStart = 0, sectionLength = 0;
                if (source && source->header[1] == "SECTION") {
                    sectionStart = source->number("STARTPOS");
                    sectionLength = source->number("LENGTH");
                    source = source->child("SOURCE");
                }
                if (source && source->value("FILE").isNotEmpty() && source->header[1] != "MIDI") {
                    auto path =
                        reference(source->value("FILE"), track.role.id == "video" ||
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
            }
        }
        song.tracks.push_back(track);
        if (delta < 0)
            folders.resize(folders.size() + delta);
    }
    std::map<String, jaras::Part> pending;
    for (auto &row : root->lines)
        if (row[0] == "MARKER") {
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
                    }
                }
            } else if (time >= 0) {
                jaras::TimelineMarker marker;
                marker.id = uuid();
                marker.name = utf8(row[3].isEmpty() ? "Marker " + row[1] : row[3]);
                marker.position = time;
                marker.color = color.value_or(0xc7ab40);
                song.markers->push_back(marker);
            }
        }
    require(pending.empty(), "REAPER: incomplete region.");
    for (auto &point : tempo.points)
        if (point.time >= 0) {
            jaras::TimelineMarker marker;
            marker.id = uuid();
            marker.name = utf8(String(point.bpm));
            marker.position = point.time;
            marker.color = 0xaaaaaa;
            marker.tempoBPM = point.bpm;
            marker.tempoBeats = song.beatsPerBar;
            marker.tempoUnit = song.beatUnit;
            song.markers->push_back(marker);
        }
    std::stable_sort(song.parts.begin(), song.parts.end(), [](auto &a, auto &b) {
        return a.startTime == b.startTime ? a.endTime > b.endTime : a.startTime < b.startTime;
    });
    for (size_t i = 0; i < song.parts.size(); ++i)
        for (size_t j = 0; j < i; ++j)
            if (!song.parts[j].parentRegionID &&
                song.parts[j].startTime <= song.parts[i].startTime &&
                song.parts[j].endTime >= song.parts[i].endTime) {
                song.parts[i].parentRegionID = song.parts[j].id;
                break;
            }
    migration::finish(result);
    return result;
}
} // namespace catlive
