#include "ProjectMigration.h"
#include "VSHookMigration.h"
namespace catlive {
namespace {
using migration::require;
struct Bytes {
    std::shared_ptr<MemoryBlock> storage;
    size_t begin = 0, count = 0;
    const uint8 *data() const { return static_cast<const uint8 *>(storage->getData()) + begin; }
    uint64 integer(size_t offset, size_t width = 4, bool big = false) const {
        require(width > 0 && width <= 8 && offset <= count && width <= count - offset,
                "Logic: truncated data.");
        uint64 value = 0;
        for (size_t i = 0; i < width; ++i)
            value |= (uint64)data()[offset + i] << (8 * (big ? width - i - 1 : i));
        return value;
    }
    Bytes slice(size_t offset, size_t length) const {
        require(offset <= count && length <= count - offset, "Logic: truncated data.");
        return {storage, begin + offset, length};
    }
    String string(size_t offset, bool utf16 = false) const {
        auto length = (size_t)integer(offset, 2);
        auto bytes = slice(offset + 2, length * (utf16 ? 2 : 1));
        if (!utf16)
            return String::fromUTF8((const char *)bytes.data(), (int)bytes.count)
                .trimCharactersAtEnd(String::charToString(0));
        String value;
        for (size_t i = 0; i < length; ++i)
            value += String::charToString((juce_wchar)bytes.integer(i * 2, 2));
        return value.trimCharactersAtEnd(String::charToString(0));
    }
    String key() const { return MemoryBlock(data(), count).toBase64Encoding(); }
};
Bytes readBytes(const File &file, size_t maximum) {
    require(file.existsAsFile() && file.getSize() >= 0 && (uint64)file.getSize() <= maximum,
            "Logic: invalid file size or missing file: " + file.getFileName());
    auto block = std::make_shared<MemoryBlock>();
    require(file.loadFileAsData(*block), "Logic: cannot read file.");
    return {block, 0, block->getSize()};
}
var xmlProperty(const XmlElement &element, int depth = 0) {
    require(depth < 64, "Logic: invalid plist nesting.");
    if (element.hasTagName("string") || element.hasTagName("key"))
        return element.getAllSubText();
    if (element.hasTagName("integer"))
        return (int64)element.getAllSubText().getLargeIntValue();
    if (element.hasTagName("real"))
        return element.getAllSubText().getDoubleValue();
    if (element.hasTagName("true"))
        return true;
    if (element.hasTagName("false"))
        return false;
    if (element.hasTagName("array")) {
        Array<var> values;
        for (auto *child : element.getChildIterator())
            values.add(xmlProperty(*child, depth + 1));
        return var(values);
    }
    if (element.hasTagName("dict")) {
        auto result = object();
        auto *key = element.getFirstChildElement();
        while (key) {
            require(key->hasTagName("key"), "Logic: invalid plist dictionary.");
            auto *value = key->getNextElement();
            require(value != nullptr, "Logic: missing plist value.");
            put(result, Identifier(key->getAllSubText()), xmlProperty(*value, depth + 1));
            key = value->getNextElement();
        }
        return result;
    }
    throw std::runtime_error("Logic: unsupported plist value.");
}
var readPlist(const File &file) {
    auto bytes = readBytes(file, 16 * 1024 * 1024);
    if (bytes.count >= 8 && std::memcmp(bytes.data(), "bplist00", 8) == 0) {
        require(bytes.count >= 40, "Logic: truncated plist.");
        auto trailer = bytes.slice(bytes.count - 32, 32);
        size_t offsetWidth = (size_t)trailer.integer(6, 1),
               refWidth = (size_t)trailer.integer(7, 1),
               objects = (size_t)trailer.integer(8, 8, true),
               root = (size_t)trailer.integer(16, 8, true),
               table = (size_t)trailer.integer(24, 8, true);
        require(objects > 0 && objects < 100000 && root < objects && offsetWidth >= 1 &&
                    offsetWidth <= 8 && refWidth >= 1 && refWidth <= 8,
                "Logic: invalid plist header.");
        bytes.slice(table, objects * offsetWidth);
        std::set<size_t> active;
        std::function<var(size_t, int)> decode = [&](size_t index, int depth) -> var {
            require(index < objects && depth < 64 && active.insert(index).second,
                    "Logic: cyclic plist.");
            struct Pop {
                std::set<size_t> &set;
                size_t index;
                ~Pop() { set.erase(index); }
            } pop{active, index};
            size_t at = (size_t)bytes.integer(table + index * offsetWidth, offsetWidth, true);
            int tag = (int)bytes.integer(at++, 1), kind = tag >> 4;
            size_t length = (size_t)(tag & 15);
            if (kind >= 4 && length == 15) {
                int sizeTag = (int)bytes.integer(at++, 1);
                require((sizeTag >> 4) == 1 && (sizeTag & 15) <= 3, "Logic: invalid plist length.");
                size_t width = (size_t)1 << (sizeTag & 15);
                length = (size_t)bytes.integer(at, width, true);
                at += width;
            }
            require(length < 16 * 1024 * 1024, "Logic: plist value exceeds size limit.");
            if (kind == 0) {
                if (tag == 8)
                    return false;
                if (tag == 9)
                    return true;
                return {};
            }
            if (kind == 1) {
                require(length <= 3, "Logic: integer too wide.");
                return (int64)bytes.integer(at, (size_t)1 << length, true);
            }
            if (kind == 2) {
                require(length == 2 || length == 3, "Logic: invalid real value.");
                if (length == 2) {
                    auto bits = (uint32)bytes.integer(at, 4, true);
                    float value;
                    std::memcpy(&value, &bits, 4);
                    return (double)value;
                }
                auto bits = bytes.integer(at, 8, true);
                double value;
                std::memcpy(&value, &bits, 8);
                require(std::isfinite(value), "Logic: invalid real.");
                return value;
            }
            if (kind == 5) {
                auto value = bytes.slice(at, length);
                return String::fromUTF8((const char *)value.data(), (int)value.count);
            }
            if (kind == 6) {
                bytes.slice(at, length * 2);
                String value;
                for (size_t i = 0; i < length; ++i)
                    value += String::charToString((juce_wchar)bytes.integer(at + i * 2, 2, true));
                return value;
            }
            if (kind == 10) {
                bytes.slice(at, length * refWidth);
                Array<var> result;
                for (size_t i = 0; i < length; ++i)
                    result.add(decode((size_t)bytes.integer(at + i * refWidth, refWidth, true),
                                      depth + 1));
                return var(result);
            }
            if (kind == 13) {
                bytes.slice(at, length * refWidth * 2);
                auto result = object();
                for (size_t i = 0; i < length; ++i) {
                    auto key =
                        decode((size_t)bytes.integer(at + i * refWidth, refWidth, true), depth + 1);
                    require(key.isString(), "Logic: invalid plist key.");
                    put(result, Identifier(key.toString()),
                        decode((size_t)bytes.integer(at + (length + i) * refWidth, refWidth, true),
                               depth + 1));
                }
                return result;
            }
            if (kind == 4) {
                auto value = bytes.slice(at, length);
                return var(MemoryBlock(value.data(), value.count));
            }
            throw std::runtime_error("Logic: unsupported plist type.");
        };
        auto result = decode(root, 0);
        require(result.isObject(), "Logic: metadata must be a dictionary.");
        return result;
    }
    auto xml = XmlDocument::parse(file);
    require(xml && xml->hasTagName("plist") && xml->getFirstChildElement(),
            "Logic: invalid plist metadata.");
    auto result = xmlProperty(*xml->getFirstChildElement());
    require(result.isObject(), "Logic: metadata must be a dictionary.");
    return result;
}
struct Record {
    String tag;
    int version = 0, kind = 0;
    uint64 owner = 0, index = 0;
    Bytes body;
};
std::vector<Record> records(const Bytes &bytes) {
    require(bytes.count >= 24 && bytes.integer(0) == 0xabc04723 &&
                bytes.integer(16) == bytes.count - 24,
            "Logic: unsupported project container.");
    std::vector<Record> result;
    size_t offset = 24;
    while (offset < bytes.count) {
        auto h = bytes.slice(offset, 36);
        if (h.integer(0) == 0xabc04723) {
            size_t n = (size_t)h.integer(16);
            bytes.slice(offset, 24 + n);
            offset += 24 + n;
            continue;
        }
        String tag = String::fromUTF8((const char *)h.data(), 4);
        size_t n = (size_t)h.integer(28);
        require(tag.length() == 4, "Logic: invalid project record.");
        result.push_back({tag, (int)h.integer(4, 2), (int)h.integer(6, 2), h.integer(8),
                          h.integer(tag == "karT" ? 18 : 14), bytes.slice(offset + 36, n)});
        offset += 36 + n;
        require(result.size() <= 1000000, "Logic: too many records.");
    }
    return result;
}
std::vector<Bytes> events(const Bytes &bytes) {
    require(bytes.count % 16 == 0, "Logic: unsupported event layout.");
    std::vector<Bytes> result;
    for (size_t offset = 0; offset < bytes.count;) {
        require((bytes.integer(offset + 7, 1) & 0x80) == 0, "Logic: invalid event boundary.");
        size_t end = offset + 16;
        while (end < bytes.count && (bytes.integer(end + 7, 1) & 0x80))
            end += 16;
        result.push_back(bytes.slice(offset, end - offset));
        offset = end;
    }
    return result;
}
String markerText(const Bytes &bytes) {
    // RTF marker labels use text and escaped Unicode; formatting is irrelevant here.
    auto input = String::fromUTF8((const char *)bytes.data(), (int)bytes.count);
    int begin = input.indexOf("{\\rtf");
    if (begin < 0)
        return {};
    input = input.substring(begin);
    String out;
    std::vector<bool> skipped;
    bool skip = false;
    for (int i = 0; i < input.length(); ++i) {
        auto ch = input[i];
        if (ch == '{') {
            skipped.push_back(skip);
            continue;
        }
        if (ch == '}') {
            if (!skipped.empty()) {
                skip = skipped.back();
                skipped.pop_back();
            }
            continue;
        }
        if (ch != '\\') {
            if (!skip && ch != '\r' && ch != '\n')
                out += String::charToString(ch);
            continue;
        }
        if (++i >= input.length())
            break;
        ch = input[i];
        if (ch == '\\' || ch == '{' || ch == '}') {
            if (!skip)
                out += String::charToString(ch);
            continue;
        }
        if (ch == '*') {
            skip = true;
            continue;
        }
        if (ch == '\'' && i + 2 < input.length()) {
            char byte = (char)input.substring(i + 1, i + 3).getHexValue32();
            wchar_t value = 0;
            MultiByteToWideChar(1252, 0, &byte, 1, &value, 1);
            if (!skip)
                out += String::charToString(value);
            i += 2;
            continue;
        }
        int start = i;
        while (i < input.length() && CharacterFunctions::isLetter(input[i]))
            ++i;
        auto word = input.substring(start, i);
        start = i;
        if (input[i] == '-')
            ++i;
        while (i < input.length() && CharacterFunctions::isDigit(input[i]))
            ++i;
        int value = input.substring(start, i).getIntValue();
        if (word == "fonttbl" || word == "colortbl" || word == "stylesheet" || word == "info")
            skip = true;
        if (!skip && (word == "par" || word == "line"))
            out += "\n";
        if (!skip && word == "u") {
            out += String::charToString((uint16)value);
            if (input[i] == '?')
                ++i;
        }
        if (input[i] != ' ')
            --i;
    }
    return out.trim();
}
jaras::Part part(std::string name, double start, double end) {
    jaras::Part value;
    value.id = uuid();
    value.name = std::move(name);
    value.startTime = start;
    value.endTime = end;
    value.color = 0xc7ab40;
    return value;
}
} // namespace
MigratedProject readLogicProject(const File &bundle) {
    require(bundle.isDirectory() && bundle.hasFileExtension("logicx"),
            "Select the .logicx project folder copied from the Mac.");
    auto available =
        bundle.getChildFile("Alternatives").findChildFiles(File::findDirectories, false);
    available.removeIf([](const File &f) { return !f.getChildFile("ProjectData").existsAsFile(); });
    require(!available.isEmpty(), "Logic: no project alternative was found.");
    auto infoFile = bundle.getChildFile("Resources/ProjectInformation.plist");
    auto info = infoFile.existsAsFile() ? readPlist(infoFile) : object();
    auto active = get(info, "ActiveVariant");
    File alternative;
    if (!active.isVoid()) {
        require(active.isString() || active.isInt() || active.isInt64() || active.isDouble(),
                "Logic: invalid active alternative.");
        if (active.isDouble())
            require(std::floor((double)active) == (double)active,
                    "Logic: invalid active alternative.");
        for (auto &candidate : available)
            if (candidate.getFileName() == active.toString())
                alternative = candidate;
        if (alternative == File()) {
            auto value = active.toString();
            require(value.isNotEmpty() && value.containsOnly("0123456789"),
                    "Logic: active alternative was not found.");
            int matches = 0;
            for (auto &candidate : available)
                if (candidate.getFileName().containsOnly("0123456789") &&
                    candidate.getFileName().getLargeIntValue() == value.getLargeIntValue()) {
                    alternative = candidate;
                    ++matches;
                }
            require(matches == 1, "Logic: active alternative was not found or is ambiguous.");
        }
    } else {
        require(available.size() == 1, "Logic: multiple alternatives without an active selection. "
                                       "Save the desired alternative in Logic first.");
        alternative = available[0];
    }
    auto metadata = readPlist(alternative.getChildFile("MetaData.plist"));
    auto all = records(readBytes(alternative.getChildFile("ProjectData"), 512 * 1024 * 1024));
    MigratedProject result;
    result.project = migration::emptyProject(bundle.getFileNameWithoutExtension());
    auto &song = result.project.songs.front();
    double rate = num(metadata, "SampleRate", 44100),
           defaultBPM = num(metadata, "BeatsPerMinute", 120);
    require(rate >= 8000 && rate <= 768000 && defaultBPM >= 1 && defaultBPM <= 1000,
            "Logic: invalid sample rate or tempo.");
    song.bpm = defaultBPM;
    song.beatsPerBar = (int)num(metadata, "SongSignatureNumerator", 4);
    song.beatUnit = (int)num(metadata, "SongSignatureDenominator", 4);
    struct Tempo {
        double tick, bpm;
    };
    std::vector<Tempo> tempos;
    std::map<uint64, String> markerNames;
    for (auto &record : all) {
        if (record.tag == "qSxT")
            markerNames[record.owner >> 16] = markerText(record.body);
        if (record.tag == "qSvE" && record.kind == 3)
            for (auto &event : events(record.body))
                if (event.integer(0, 1) == 0x60) {
                    double bpm = event.integer(16) / 10000.;
                    require(bpm >= 1 && bpm <= 1000, "Logic: invalid tempo event.");
                    tempos.push_back({(double)event.integer(4) - 38400, bpm});
                }
    }
    std::stable_sort(tempos.begin(), tempos.end(),
                     [](auto &a, auto &b) { return a.tick < b.tick; });
    if (tempos.empty() || tempos.front().tick > 0)
        tempos.insert(tempos.begin(), {0, defaultBPM});
    auto seconds = [&](double tick) {
        if (tick < 0)
            return tick / 960 * 60 / tempos.front().bpm;
        double time = 0, previous = 0, bpm = defaultBPM;
        for (auto &t : tempos) {
            if (t.tick <= 0)
                bpm = t.bpm;
            else if (t.tick < tick) {
                time += (t.tick - previous) / 960 * 60 / bpm;
                previous = t.tick;
                bpm = t.bpm;
            }
        }
        return time + (tick - previous) / 960 * 60 / bpm;
    };
    for (auto &t : tempos) {
        if (t.tick <= 0)
            song.bpm = t.bpm;
        if (t.tick >= 0) {
            jaras::TimelineMarker m;
            m.id = uuid();
            m.name = utf8(String(t.bpm));
            m.position = seconds(t.tick);
            m.color = 0xaaaaaa;
            m.tempoBPM = t.bpm;
            m.tempoBeats = song.beatsPerBar;
            m.tempoUnit = song.beatUnit;
            m.tempoTimebase = "global";
            m.tempoReferenceBPM = t.bpm;
            song.markers->push_back(m);
        }
    }
    struct Reference {
        String name;
        double rate;
        File source;
    };
    struct Mixer {
        double volume, pan;
        bool mute;
    };
    std::map<uint64, Reference> files;
    std::map<std::pair<uint64, uint64>, Bytes> regions;
    std::map<uint64, String> names, identifiers;
    std::map<String, Mixer> mixers;
    std::map<uint64, const Record *> sequences;
    for (auto &r : all) {
        auto &b = r.body;
        if (r.tag == "lFuA") {
            auto name = b.string(8, true);
            require(name.isNotEmpty() && name != "." && name != ".." && !name.containsAnyOf("/\\:"),
                    "Logic: invalid audio filename.");
            double fileRate = rate;
            for (size_t i = 0; i + 24 <= b.count; ++i)
                if (std::memcmp(b.data() + i, "EVAW", 4) == 0) {
                    double stored = (double)b.integer(i + 20);
                    if (stored >= 8000 && stored <= 768000)
                        fileRate = stored;
                    break;
                }
            File source;
            for (auto folder :
                 {bundle.getChildFile("Media/Audio Files"), bundle.getChildFile("Audio Files"),
                  bundle.getParentDirectory().getChildFile("Audio Files")})
                if (folder.getChildFile(name).existsAsFile()) {
                    source = folder.getChildFile(name);
                    break;
                }
            files[r.owner >> 16] = {name, fileRate, source};
        } else if (r.tag == "gRuA")
            regions[{r.owner >> 16, r.index}] = b;
        else if (r.tag == "ivnE" && b.count >= 160) {
            names[r.owner] = b.string(158);
            if (r.version == 12 && b.count == 463 + ((b.integer(158, 2) + 1) & ~uint64(1)))
                identifiers[r.owner] = b.slice(b.count - 16, 16).key();
        } else if (r.tag == "OCuA" && r.version == 7 && b.count >= 169) {
            auto identifier = b.slice(153 + 4 * (size_t)b.integer(26, 2), 16);
            if (std::all_of(identifier.data(), identifier.data()+identifier.count, [](uint8 byte){return byte==0;})) continue;
            auto key = identifier.key();
            double position = b.integer(116) / 16777216.;
            int pan = (int)b.integer(89, 1), mute = (int)b.integer(90, 1);
            require(position <= 127 && pan <= 127 && mute <= 1, "Logic: invalid mixer controls.");
            require(!mixers.count(key), "Logic: duplicate mixer channel identifier.");
            mixers[key] = {std::pow(position / 90, 2), (pan - 64.) / (pan < 64 ? 64 : 63),
                           mute == 1};
        } else if (r.tag == "qeSM" && r.kind == 23)
            sequences[r.owner] = &r;
    }
    std::set<uint64> roots;
    for (auto &r : all)
        if (r.tag == "karT" && r.kind == 23 && r.body.count >= 57 && sequences.count(r.owner)) {
            auto *s = sequences[r.owner];
            auto title = s->body.string(s->version >= 5 ? 16 : 52);
            if (title != "TRASH" && title != "Track Automation Root Folder" &&
                title != "Track Alternatives" && title != "Global Harmonies" &&
                !title.startsWith("*Automation"))
                roots.insert(r.owner);
        }
    require(!roots.empty(), "Logic: arrangement track list is not supported.");
    uint64 root = roots.count(0x40000) ? 0x40000 : *roots.begin();
    std::vector<const Record *> rows;
    for (auto &r : all)
        if (r.tag == "karT" && r.kind == 23 && r.owner == root)
            rows.push_back(&r);
    std::sort(rows.begin(), rows.end(), [](auto *a, auto *b) { return a->index < b->index; });
    std::map<uint64, size_t> tracks;
    std::optional<ID> group;
    for (auto *row : rows) {
        int kind = (int)row->body.integer(0, 1);
        if (kind == 3)
            continue;
        require(kind == 1, "Logic: unsupported track kind.");
        auto channel = row->body.integer(6);
        int depth = (int)row->body.integer(14, 2);
        jaras::Track track;
        track.id = uuid();
        track.color = 0x828282;
        track.name =
            utf8(names.count(channel) ? names[channel] : "Track " + String((int)row->index + 1));
        if (identifiers.count(channel) && mixers.count(identifiers[channel])) {
            auto m = mixers[identifiers[channel]];
            track.volume = m.volume;
            track.pan = m.pan;
            track.mute = m.mute;
        } else
            result.warnings.addIfNotAlreadyThere("Some Logic mixer channels use an unsupported "
                                                 "layout. Review volume, pan and mute.");
        if (depth > 0) {
            require(group.has_value(), "Logic: invalid track group.");
            track.parentTrackID = group;
        } else
            group = track.id;
        tracks[row->index + 1] = song.tracks.size();
        song.tracks.push_back(track);
    }
    require(!song.tracks.empty(), "Logic: no arrangement tracks.");
    std::vector<jaras::Part> music;
    for (auto &r : all)
        if (r.tag == "qSvE" && r.kind == 23 && r.owner == root)
            for (auto &event : events(r.body)) {
                int type = (int)event.integer(0, 1);
                if (type == 0xf1)
                    continue;
                require((type == 0x24 || type == 0x20) && event.count >= 80,
                        "Logic: unsupported or incomplete arrangement event.");
                auto row = event.integer(20) & 0xffffff;
                require(tracks.count(row), "Logic: item references an unknown track.");
                auto &track = song.tracks[tracks[row]];
                bool isMusic =
                    migration::VSHookMigration::uppercase(text(track.name).trim()).replace(String::fromUTF8("Ú"), "U") ==
                    "MUSICAS";
                double tick =
                    (double)event.integer(4) - 34560 + (event.integer(0) >> 8) / 16777216.;
                double start = seconds(tick);
                if (type == 0x20) {
                    auto owner = event.integer(32) << 16;
                    require(sequences.count(owner),
                            "Logic: MIDI region references an unknown sequence.");
                    auto &seq = *sequences[owner];
                    size_t offset = seq.version >= 5 ? 16 : 52;
                    auto title = seq.body.string(offset);
                    size_t padded = ((size_t)seq.body.integer(offset, 2) + 1) & ~size_t(1);
                    double length = (double)seq.body.integer(offset + 62 + padded);
                    double end = seconds(tick + length);
                    start = std::max(0., start);
                    require(length > 0 && end > start && end < 7 * 86400,
                            "Logic: invalid MIDI bounds.");
                    if (isMusic) {
                        music.push_back(part(utf8(title), start, end));
                        continue;
                    }
                    jaras::MIDIItem midi;
                    double sourceTick = (int32)(uint32)seq.body.integer(offset + 6 + padded);
                    bool found = false;
                    for (auto &content : all)
                        if (content.tag == "qSvE" && content.kind == 23 && content.owner == owner) {
                            found = true;
                            for (auto &note : events(content.body)) {
                                int status = (int)note.integer(0, 1);
                                if (status == 0xf1)
                                    continue;
                                if ((status & 0xf0) != 0x90) {
                                    result.warnings.addIfNotAlreadyThere(
                                        "Logic MIDI controller and expression events are not "
                                        "migrated.");
                                    continue;
                                }
                                require(note.count >= 32 && note.integer(23, 1) == 0x89,
                                        "Logic: incomplete MIDI note.");
                                int pitch = (int)note.integer(12, 1),
                                    velocity = (int)note.integer(11, 1);
                                double noteLength = (double)note.integer(28);
                                require(pitch <= 127 && velocity <= 127 && noteLength > 0,
                                        "Logic: invalid MIDI note.");
                                if (velocity == 0)
                                    continue;
                                double noteTick = tick + (double)note.integer(4) - 38400 +
                                                  (note.integer(0) >> 8) / 16777216. - sourceTick;
                                double a = std::max(start, seconds(noteTick)),
                                       b = std::min(end, seconds(noteTick + noteLength));
                                if (b > a)
                                    midi.notes.push_back({uuid(), (a - start) * 2, (b - a) * 2,
                                                          pitch, velocity, (status & 15) + 1});
                                require(midi.notes.size() <= 100000, "Logic: too many MIDI notes.");
                            }
                        }
                    require(found, "Logic: MIDI region has no event sequence.");
                    std::stable_sort(midi.notes.begin(), midi.notes.end(),
                                     [](auto &a, auto &b) { return a.start < b.start; });
                    jaras::AudioClip clip;
                    clip.id = uuid();
                    clip.name = utf8(title.isEmpty() ? "MIDI" : title);
                    clip.startTime = start;
                    clip.duration = end - start;
                    clip.midi = midi;
                    clip.muted = (event.integer(12) & 0x100) != 0;
                    track.clips.push_back(clip);
                    result.warnings.addIfNotAlreadyThere(
                        "MIDI notes were imported. Choose an instrument in CatLive; Logic plug-ins "
                        "are not migrated.");
                    continue;
                }
                auto fileID = event.integer(44), regionID = event.integer(40);
                require(files.count(fileID) && regions.count({fileID, regionID}),
                        "Logic: unsupported audio file or region reference.");
                auto &file = files[fileID];
                auto &region = regions[{fileID, regionID}];
                double duration = region.integer(22, 8) / file.rate,
                       source = region.integer(6, 8) / file.rate, end = start + duration;
                require(duration > 0 && duration < 7 * 86400 && source < 7 * 86400,
                        "Logic: invalid audio bounds.");
                if (end <= 0)
                    continue;
                auto path = utf8("Stems/Logic/" + String((int64)fileID) + "/" + file.name);
                result.media[path] = file.source;
                jaras::AudioClip clip;
                clip.id = uuid();
                clip.name = utf8(region.string(74));
                clip.startTime = std::max(0., start);
                clip.duration = end - clip.startTime;
                clip.sourceOffset = source + std::max(0., -start);
                clip.audioFile = jaras::AudioFile{path, {}};
                double pitch = (int8)event.integer(53, 1) + (int8)event.integer(50, 1) / 100.;
                if (std::abs(pitch) <= 12)
                    clip.pitchSemitones = pitch;
                clip.muted = (event.integer(12) & 0x100) != 0;
                if (isMusic)
                    music.push_back(
                        part(clip.name, clip.startTime, clip.startTime + clip.duration));
                track.clips.push_back(clip);
                if (file.source == File())
                    result.warnings.addIfNotAlreadyThere("Missing media: " + file.name);
                if (event.count > 80)
                    result.warnings.addIfNotAlreadyThere(
                        "Logic Flex processing and region automation are not applied. Audio "
                        "retains its source bounds.");
            }
    struct Marker {
        std::string name;
        double start, end;
    };
    std::vector<Marker> markers;
    for (auto &r : all)
        if (r.tag == "qSvE" && r.kind == 22)
            for (auto &event : events(r.body))
                if (event.integer(0, 1) == 0x12) {
                    require(event.count >= 48, "Logic: incomplete marker.");
                    double tick = (double)event.integer(4) - 38400,
                           length = (double)event.integer(28);
                    auto title = markerNames[event.integer(16)];
                    if (title.isEmpty())
                        title = "Marker " + String(markers.size() + 1);
                    markers.push_back({utf8(title), std::max(0., seconds(tick)),
                                       std::max(0., seconds(tick + length))});
                }
    std::stable_sort(markers.begin(), markers.end(),
                     [](auto &a, auto &b) { return a.start < b.start; });
    for (auto &t : song.tracks)
        for (auto &c : t.clips)
            song.duration = std::max(song.duration, c.startTime + c.duration);
    for (auto &m : markers)
        song.duration = std::max(song.duration, std::max(m.start, m.end));
    for (auto &p : music)
        song.duration = std::max(song.duration, p.endTime);
    for (size_t i = 0; i < markers.size(); ++i) {
        auto &m = markers[i];
        jaras::TimelineMarker flag;
        flag.id = uuid();
        flag.name = m.name;
        flag.position = m.start;
        flag.color = 0xc7ab40;
        song.markers->push_back(flag);
        double next = i + 1 < markers.size() ? markers[i + 1].start : song.duration,
               end = std::min(next, m.end > m.start ? m.end : next);
        if (end > m.start)
            song.parts.push_back(part(m.name, m.start, end));
    }
    std::sort(music.begin(), music.end(),
              [](auto &a, auto &b) { return a.startTime < b.startTime; });
    music.erase(
        std::unique(music.begin(), music.end(),
                    [](auto &a, auto &b) { return std::abs(a.startTime - b.startTime) < 1e-6; }),
        music.end());
    auto rootsCopy = song.parts;
    std::vector<jaras::TimelineMarker> linked;
    std::set<ID> assigned;
    for (size_t i = 0; i < rootsCopy.size(); ++i) {
        auto &rootPart = rootsCopy[i];
        double next = i + 1 < rootsCopy.size() ? rootsCopy[i + 1].startTime : song.duration;
        std::vector<jaras::Part> children;
        for (auto p : music)
            if (p.startTime >= rootPart.startTime - 1e-6 && p.startTime < rootPart.endTime - 1e-6 &&
                p.endTime <= next + 1e-6) {
                assigned.insert(p.id);
                children.push_back(p);
            }
        if (children.empty())
            continue;
        song.parts[i].endTime = std::max(song.parts[i].endTime, children.back().endTime);
        if (children.size() > 1)
            for (auto p : children) {
                p.parentRegionID = rootPart.id;
                song.parts.push_back(p);
                jaras::TimelineMarker m;
                m.id = uuid();
                m.name = p.name;
                m.position = p.startTime;
                m.color = 0xc7ab40;
                m.unifiedRegionID = rootPart.id;
                m.sourceRegionID = p.id;
                linked.push_back(m);
            }
    }
    for (auto p : music)
        if (!assigned.count(p.id)) {
            song.parts.push_back(p);
            jaras::TimelineMarker marker; marker.id=uuid(); marker.name=utf8(text(p.name).substring(0,256));
            marker.position=p.startTime; marker.color=p.color.value_or(0xc7ab40); linked.push_back(marker);
        }
    if (!music.empty()) {
        std::vector<jaras::TimelineMarker> tempos;
        for (const auto &marker : *song.markers) {
            if (marker.tempoBPM) tempos.push_back(marker); else linked.push_back(marker);
        }
        auto flags = migration::VSHookMigration::uniqueFlags(std::move(linked));
        tempos.insert(tempos.end(), flags.begin(), flags.end()); song.markers=std::move(tempos);
        migration::VSHookMigration::sortParts(song);
    }
    migration::finish(result);
    return result;
}
} // namespace catlive
