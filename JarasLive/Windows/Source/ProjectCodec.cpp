#include "ProjectCodec.h"
#include "MediaPath.h"
#include "FXSchema.h"
#include "MarkerEditing.h"
#include <bcrypt.h>
#include <stdexcept>
#include <windows.h>

namespace catlive {
namespace {
const unsigned char header[]{0x4a, 0x41, 0x52, 0x41, 0x53, 0x4a, 0x4c, 0x00, 0x01};
// Identical application document key to ProjectDocumentCodec.swift.
const unsigned char keyBytes[]{0xce, 0x9a, 0x3a, 0xb3, 0xab, 0x54, 0x63, 0x22, 0x5a, 0x93, 0xd8,
                               0x65, 0xdd, 0xe0, 0x49, 0xce, 0x38, 0x56, 0xde, 0x29, 0x9a, 0x12,
                               0x29, 0x44, 0x07, 0x41, 0xf7, 0x37, 0x0f, 0x49, 0x69, 0xfd};
// Swift represents these default-valued fields as optionals. Keep an omitted
// default omitted on round trips, while always persisting an actual edit.
template <typename T> void putDefault(var &owner, const char *key, T value, T fallback) {
    if (value != fallback || !get(owner, key).isVoid()) put(owner, key, value);
}
void check(NTSTATUS s) {
    if (s < 0)
        throw std::runtime_error("Project authentication/encryption failed.");
}
struct AES {
    BCRYPT_ALG_HANDLE alg{};
    BCRYPT_KEY_HANDLE key{};
    AES() {
        check(BCryptOpenAlgorithmProvider(&alg, BCRYPT_AES_ALGORITHM, nullptr, 0));
        try {
            check(BCryptSetProperty(alg, BCRYPT_CHAINING_MODE, (PUCHAR)BCRYPT_CHAIN_MODE_GCM,
                                    sizeof(BCRYPT_CHAIN_MODE_GCM), 0));
            check(BCryptGenerateSymmetricKey(alg, &key, nullptr, 0, (PUCHAR)keyBytes,
                                             sizeof(keyBytes), 0));
        } catch (...) {
            BCryptCloseAlgorithmProvider(alg, 0);
            throw;
        }
    }
    ~AES() {
        if (key)
            BCryptDestroyKey(key);
        if (alg)
            BCryptCloseAlgorithmProvider(alg, 0);
    }
};
std::string s(const var &v, const char *k) { return utf8(str(v, k)); }
var merged(const var &original) { return original.isObject() ? original.clone() : object(); }
var byId(const var &array, const ID &id) {
    if (auto *values = array.getArray())
        for (const auto &value : *values)
            if (s(value, "id") == id)
                return value;
    return {};
}
jaras::OutputPatch patch(const var &v) {
    return {(int)num(v, "firstChannel"), (int)num(v, "channelCount", 2)};
}
var patchJSON(const jaras::OutputPatch &p) {
    auto v = object();
    put(v, "firstChannel", p.firstChannel);
    put(v, "channelCount", p.channelCount);
    return v;
}
jaras::AudioFile audioFile(const var &v) {
    jaras::AudioFile f;
    f.path = s(v, "path");
    if (get(v, "sha256").isString())
        f.sha256 = s(v, "sha256");
    return f;
}
var audioJSON(const jaras::AudioFile &f) {
    auto v = object();
    put(v, "path", text(f.path));
    if (f.sha256)
        put(v, "sha256", text(*f.sha256));
    return v;
}
template <class T> void optionalNum(const var &v, const char *key, std::optional<T> &out) {
    if (!get(v, key).isVoid() && !get(v, key).isUndefined())
        out = (T)num(v, key);
}
template <class T> void optionalText(const var &v, const char *key, std::optional<T> &out) {
    if (get(v, key).isString())
        out = s(v, key);
}
void optionalJSON(const var &value, const char *key, std::optional<std::string> &out) {
    if (get(value, key).isObject())
        out = utf8(JSON::toString(get(value, key), true, 17));
}
void remove(var &value, const char *key) { value.getDynamicObject()->removeProperty(key); }
template <class T> void emit(var &value, const char *key, const std::optional<T> &data) {
    if (data)
        put(value, key, *data);
    else
        remove(value, key);
}
void emit(var &value, const char *key, const std::optional<unsigned> &data) {
    if (data)
        put(value, key, (int64)*data);
    else
        remove(value, key);
}
void emit(var &value, const char *key, const std::optional<std::string> &data) {
    if (data)
        put(value, key, text(*data));
    else
        remove(value, key);
}
void emitJSON(var &value, const char *key, const std::optional<std::string> &data) {
    if (data)
        put(value, key, JSON::parse(text(*data)));
    else
        remove(value, key);
}
void emit(var &value, const char *key, const std::optional<jaras::OutputPatch> &data) {
    if (data)
        put(value, key, patchJSON(*data));
    else
        remove(value, key);
}
void emit(var &value, const char *key, const std::optional<jaras::AudioFile> &data) {
    if (data)
        put(value, key, audioJSON(*data));
    else
        remove(value, key);
}
var idsJSON(const std::vector<ID> &ids) {
    Array<var> result;
    for (const auto &id : ids)
        result.add(text(id));
    return result;
}
void optionalIDs(const var &value, const char *key, std::optional<std::vector<ID>> &out) {
    if (get(value, key).isArray()) {
        out.emplace();
        for (auto id : list(get(value, key)))
            out->push_back(utf8(id.toString()));
    }
}
jaras::TimecodeSettings timecode(const var &value) {
    jaras::TimecodeSettings t;
    t.mode = s(value, "mode");
    t.frameRate = num(value, "frameRate", 30);
    t.offset = num(value, "offset");
    t.regionRelative = flag(value, "regionRelative", true);
    t.midiDestination = (int)num(value, "midiDestination");
    return t;
}
var timecodeJSON(const jaras::TimecodeSettings &t) {
    auto value = object();
    put(value, "mode", text(t.mode));
    put(value, "frameRate", t.frameRate);
    put(value, "offset", t.offset);
    put(value, "regionRelative", t.regionRelative);
    put(value, "midiDestination", t.midiDestination);
    return value;
}
jaras::MIDIItem midi(const var &value) {
    jaras::MIDIItem item;
    item.sourceBPM = num(value, "sourceBPM", 120);
    auto grid = get(value, "grid");
    item.division = (int)num(grid, "division", 16);
    item.mode = utf8(str(grid, "mode", "straight"));
    item.swing = num(grid, "swing", .5);
    for (auto raw : list(get(value, "notes"))) {
        jaras::MIDINote note;
        note.id = s(raw, "id");
        note.start = num(raw, "start");
        note.length = num(raw, "length", 1);
        note.pitch = (int)num(raw, "pitch", 60);
        note.velocity = (int)num(raw, "velocity", 100);
        note.channel = (int)num(raw, "channel", 1);
        item.notes.push_back(note);
    }
    return item;
}
var midiJSON(const jaras::MIDIItem &item, const var &original) {
    auto result = merged(original);
    put(result, "sourceBPM", item.sourceBPM);
    auto grid = merged(get(original, "grid"));
    put(grid, "division", item.division);
    put(grid, "mode", text(item.mode));
    put(grid, "swing", item.swing);
    put(result, "grid", grid);
    Array<var> notes;
    for (const auto &note : item.notes) {
        auto raw = merged(byId(get(original, "notes"), note.id));
        put(raw, "id", text(note.id));
        put(raw, "start", note.start);
        put(raw, "length", note.length);
        put(raw, "pitch", note.pitch);
        put(raw, "velocity", note.velocity);
        put(raw, "channel", note.channel);
        notes.add(raw);
    }
    put(result, "notes", notes);
    return result;
}
jaras::MultiLoop multiLoop(const var &raw) {
    jaras::MultiLoop loop;
    loop.id = s(raw, "id");
    loop.name = s(raw, "name");
    loop.marker1 = s(raw, "marker1");
    loop.marker2 = s(raw, "marker2");
    loop.fadeSeconds = num(raw, "fadeSeconds", 3);
    optionalNum(raw, "enabled", loop.enabled);
    optionalNum(raw, "mixerEnabled", loop.mixerEnabled);
    for (auto t : list(get(raw, "tracks"))) {
        jaras::MultiLoopTrack track;
        track.id = s(t, "id");
        track.gain = num(t, "gain", 1);
        track.autoFader = flag(t, "autoFader");
        track.mute = flag(t, "mute");
        track.solo = flag(t, "solo");
        loop.tracks.push_back(track);
    }
    return loop;
}
var multiLoopJSON(const jaras::MultiLoop &loop, const var &original) {
    auto raw = merged(original);
    put(raw, "id", text(loop.id));
    put(raw, "name", text(loop.name));
    put(raw, "marker1", text(loop.marker1));
    put(raw, "marker2", text(loop.marker2));
    put(raw, "fadeSeconds", loop.fadeSeconds);
    emit(raw, "enabled", loop.enabled);
    emit(raw, "mixerEnabled", loop.mixerEnabled);
    Array<var> tracks;
    for (const auto &t : loop.tracks) {
        auto value = merged(byId(get(original, "tracks"), t.id));
        put(value, "id", text(t.id));
        put(value, "gain", t.gain);
        put(value, "autoFader", t.autoFader);
        put(value, "mute", t.mute);
        put(value, "solo", t.solo);
        tracks.add(value);
    }
    put(raw, "tracks", tracks);
    return raw;
}
void require(bool ok, const char *message) {
    if (!ok)
        throw std::runtime_error(message);
}
} // namespace
MemoryBlock ProjectCodec::seal(const String &plaintext) {
    AES aes;
    const auto bytes = (ULONG)plaintext.getNumBytesAsUTF8();
    MemoryBlock output(sizeof(header) + 12 + bytes + 16, true);
    auto *p = (PUCHAR)output.getData();
    memcpy(p, header, sizeof(header));
    check(BCryptGenRandom(nullptr, p + sizeof(header), 12, BCRYPT_USE_SYSTEM_PREFERRED_RNG));
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = p + sizeof(header);
    info.cbNonce = 12;
    info.pbAuthData = (PUCHAR)header;
    info.cbAuthData = sizeof(header);
    info.pbTag = p + sizeof(header) + 12 + bytes;
    info.cbTag = 16;
    ULONG written = 0;
    check(BCryptEncrypt(aes.key, (PUCHAR)plaintext.toRawUTF8(), bytes, &info, nullptr, 0,
                        p + sizeof(header) + 12, bytes, &written, 0));
    require(written == bytes, "Invalid encrypted document size.");
    return output;
}
String ProjectCodec::unseal(const MemoryBlock &input) {
    auto *p = (PUCHAR)input.getData();
    if (input.getSize() >= sizeof(header) && memcmp(p, header, sizeof(header)) == 0) {
        require(input.getSize() >= sizeof(header) + 28, "Truncated CatLive document.");
        AES aes;
        const auto size = (ULONG)(input.getSize() - sizeof(header) - 28);
        MemoryBlock plain(size + 1, true);
        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
        BCRYPT_INIT_AUTH_MODE_INFO(info);
        info.pbNonce = p + sizeof(header);
        info.cbNonce = 12;
        info.pbAuthData = (PUCHAR)header;
        info.cbAuthData = sizeof(header);
        info.pbTag = p + input.getSize() - 16;
        info.cbTag = 16;
        ULONG written = 0;
        check(BCryptDecrypt(aes.key, p + sizeof(header) + 12, size, &info, nullptr, 0,
                            (PUCHAR)plain.getData(), size, &written, 0));
        return String::fromUTF8((const char *)plain.getData(), (int)written);
    }
    auto plain = input.toString();
    require(plain.trimStart().startsWithChar('{'), "Invalid or unsupported .jl project.");
    return plain;
}
namespace {
// Migrate only identities declared by the project schema. Vendor/plugin states
// and future extension fields own their strings, keys and embedded identities.
String canonicalID(const String &value) {
    const auto compact = [](const String &id) {
        return id.length() == 32 && id.containsOnly("0123456789abcdefABCDEF");
    };
    if (compact(value)) return Uuid(value).toDashedString().toUpperCase();
    if (value.length() == 41 && value.endsWith("-timecode") && compact(value.substring(0, 32))) {
        auto id = Uuid(value.substring(0, 32)).toDashedString().toUpperCase();
        const auto first = String("0123456789ABCDEF").indexOfChar(id[0]) ^ 8;
        return String::charToString(String("0123456789ABCDEF")[first]) + id.substring(1);
    }
    return value;
}
void canonicalIDValue(var &value) {
    if (value.isString()) value = canonicalID(value.toString());
}
template <typename F> void identityField(var &owner, const char *key, F &&work) {
    auto *node = owner.getDynamicObject();
    if (!node || !node->hasProperty(key)) return;
    auto value = node->getProperty(key);
    work(value);
    node->setProperty(key, std::move(value));
}
template <typename F> void identityElements(var &owner, const char *key, F &&work) {
    identityField(owner, key, [&](var &values) {
        if (auto *array = values.getArray()) for (auto &value : *array) work(value);
    });
}
void canonicalIDFields(var &owner, std::initializer_list<const char *> keys) {
    for (const auto *key : keys) identityField(owner, key, canonicalIDValue);
}
void canonicalIDArray(var &owner, const char *key) {
    identityElements(owner, key, canonicalIDValue);
}
void canonicalNativeKey(var &value) {
    if (!value.isString()) return;
    const auto text = value.toString();
    if (text.startsWith("Native:")) value = "Native:" + canonicalID(text.substring(7));
}
void canonicalFX(var &fx) {
    identityElements(fx, "bands", [](var &band) { canonicalIDFields(band, {"id"}); });
    identityElements(fx, "instances", [](var &instance) {
        canonicalIDFields(instance, {"id"});
        identityField(instance, "settings", canonicalFX);
    });
    identityElements(fx, "inserted", canonicalNativeKey);
    // External instance/class IDs, component/controller state and vendor data
    // are opaque. In particular, never recurse through externalPlugins.
}
void canonicalAutomation(var &automation) {
    identityElements(automation, "envelopes", [](var &envelope) {
        canonicalIDFields(envelope, {"id"});
        identityElements(envelope, "points", [](var &point) { canonicalIDFields(point, {"id"}); });
        identityField(envelope, "target", [](var &target) {
            identityField(target, "native", [](var &native) {
                canonicalIDFields(native, {"band"});
                identityField(native, "effect", canonicalNativeKey);
            });
        });
    });
}
void canonicalRouting(var &routing) {
    canonicalIDArray(routing, "receives");
    canonicalIDArray(routing, "transmitters");
}
void canonicalMapKeys(var &map, bool prefixed) {
    const auto *node = map.getDynamicObject();
    if (!node) return;
    auto result = object();
    for (const auto &property : node->getProperties()) {
        auto key = property.name.toString();
        if (!prefixed) key = canonicalID(key);
        else if (key.startsWith("region:") || key.startsWith("marker:"))
            key = key.substring(0, 7) + canonicalID(key.substring(7));
        require(!result.getDynamicObject()->hasProperty(Identifier(key)),
                "Conflicting legacy IDs in integration map.");
        put(result, Identifier(key), property.value);
    }
    map = std::move(result);
}
} // namespace
var ProjectCodec::canonicalIDs(const var &input) {
    auto root = input.clone();
    canonicalIDFields(root, {"id", "projectSyncID"});
    identityField(root, "savedCursor", [](var &cursor) { canonicalIDFields(cursor, {"songID"}); });
    identityField(root, "masterFX", canonicalFX);
    identityField(root, "masterAutomation", canonicalAutomation);
    identityElements(root, "setlists", [](var &setlist) {
        canonicalIDFields(setlist, {"id"}); canonicalIDArray(setlist, "songIds");
    });
    identityField(root, "regionSetlist", [](var &setlist) {
        canonicalIDFields(setlist, {"selectedId"});
        canonicalIDArray(setlist, "playedLiveRegionIDs");
        identityElements(setlist, "playlists", [](var &playlist) {
            canonicalIDFields(playlist, {"id", "songId"}); canonicalIDArray(playlist, "regionIds");
        });
        identityElements(setlist, "blocks", [](var &block) {
            canonicalIDFields(block, {"id", "songId", "playlistId", "beforeRegionId"});
        });
    });
    identityElements(root, "songs", [](var &song) {
        canonicalIDFields(song, {"id"});
        identityElements(song, "tracks", [](var &track) {
            canonicalIDFields(track, {"id", "parentTrackID"});
            identityField(track, "routing", canonicalRouting);
            identityField(track, "stereoLink", [](var &link) {
                canonicalIDFields(link, {"partner"});
                identityField(link, "original", [](var &original) { identityField(original, "routing", canonicalRouting); });
            });
            identityField(track, "fx", canonicalFX); identityField(track, "automation", canonicalAutomation);
            identityElements(track, "clips", [](var &clip) {
                canonicalIDFields(clip, {"id", "regionOwnerID"});
                canonicalIDArray(clip, "separatedStemTracks");
                identityField(clip, "fx", canonicalFX); identityField(clip, "automation", canonicalAutomation);
                identityField(clip, "midi", [](var &midi) {
                    identityElements(midi, "notes", [](var &note) { canonicalIDFields(note, {"id"}); });
                });
            });
        });
        identityElements(song, "parts", [](var &part) {
            canonicalIDFields(part, {"id", "parentRegionID"});
            canonicalIDArray(part, "pitchTrackIDs"); canonicalIDArray(part, "pitchGroupIDs");
            identityElements(part, "multiLoops", [](var &loop) {
                canonicalIDFields(loop, {"id", "marker1", "marker2"});
                identityElements(loop, "tracks", [](var &track) { canonicalIDFields(track, {"id"}); });
            });
        });
        identityElements(song, "markers", [](var &marker) {
            canonicalIDFields(marker, {"id", "unifiedRegionID", "sourceRegionID", "regionOwnerID"});
        });
    });
    identityField(root, "resolume", [](var &resolume) {
        for (const auto *key : {"withMarkers", "regionsOnly"})
            identityField(resolume, key, [](var &map) { canonicalMapKeys(map, true); });
    });
    identityField(root, "windowsLighting", [](var &lighting) {
        identityField(lighting, "assignments", [](var &map) { canonicalMapKeys(map, true); });
        identityField(lighting, "starts", [](var &map) { canonicalMapKeys(map, false); });
    });
    return root;
}
var ProjectCodec::read(const File &file) {
    require(file.existsAsFile(), "Project file not found. It may have been moved or deleted.");
    const auto size = file.getSize();
    require(size > 0, "The project file is empty.");
    require(size <= 128 * 1024 * 1024, "The project document exceeds 128 MB.");
    MemoryBlock bytes;
    require(file.loadFileAsData(bytes), "Could not read project.");
    var value;
    auto result = JSON::parse(unseal(bytes), value);
    require(result.wasOk() && value.isObject(), "Invalid project JSON.");
    value = canonicalIDs(value);
    decode(value);
    return value;
}
void ProjectCodec::write(const File &file, const var &input) {
    const auto value = canonicalIDs(input);
    decode(value);
    auto folder = file.getParentDirectory();
    require(folder.createDirectory().wasOk(), "Could not create project folder.");
    for (auto &other : folder.findChildFiles(File::findFiles, false, "*.jl"))
        require(other == file, "Choose a separate folder for each CatLive project.");
    auto bytes = seal(JSON::toString(value, true, 17));
    TemporaryFile tmp(file);
    {
        FileOutputStream out(tmp.getFile());
        require(out.openedOk() && out.write(bytes.getData(), bytes.getSize()),
                "Could not write project.");
        out.flush();
        require(out.getStatus().wasOk(), "Could not flush project.");
    }
    require(tmp.overwriteTargetFileWithTemporary(),
            "Could not replace project; the previous file was preserved.");
}
File ProjectCodec::resolveMedia(const File &directory, const std::string &relative, bool resolveExisting) {
    auto path = text(relative).replaceCharacter('\\', '/');
    require(path.isNotEmpty() && !File::isAbsolutePath(path) && !path.containsChar(':') &&
                !path.startsWithChar('/'),
            "Audio paths must be relative to the project.");
    for (auto part : StringArray::fromTokens(path, "/", {}))
        require(part != "..", "Unsafe media path.");
    auto file = directory.getChildFile(path);
    require(file.isAChildOf(directory), "Audio path escapes project folder.");
    return resolveExisting ? existingMediaPath(file) : file;
}
jaras::Project ProjectCodec::decode(const var &input) {
    const auto root = canonicalIDs(input);
    require(root.isObject(), "Expected project object.");
    jaras::Project p;
    p.id = s(root, "id");
    p.name = s(root, "name");
    if (get(root, "projectSyncID").isString()) p.projectSyncID = s(root, "projectSyncID");
    if (get(root, "timelineMovementLocked").isBool())
        p.timelineMovementLocked = flag(root, "timelineMovementLocked");
    p.projectFormatVersion = (int)num(root, "projectFormatVersion", 1);
    require(p.projectFormatVersion == 1, "This project version requires a newer CatLive.");
    p.minimumJarasVersion = s(root, "minimumJarasVersion");
    p.createdAt = s(root, "createdAt");
    p.updatedAt = s(root, "updatedAt");
    p.masterVolume = num(root, "masterVolume", 1);
    p.masterPan = num(root, "masterPan");
    p.masterMute = flag(root, "masterMute");
    p.masterSolo = flag(root, "masterSolo");
    optionalJSON(root, "masterAutomation", p.masterAutomationJSON);
    if (get(root, "masterFX").isObject())
        p.masterFXJSON = utf8(JSON::toString(get(root, "masterFX"), true, 17));
    p.masterMono = flag(root, "masterMono");
    optionalNum(root, "masterColor", p.masterColor);
    optionalNum(root, "masterPhaseInverted", p.masterPhaseInverted);
    if (get(root, "masterPatch").isObject())
        p.masterPatch = patch(get(root, "masterPatch"));
    if (get(root, "masterSecondaryPatch").isObject())
        p.masterSecondaryPatch = patch(get(root, "masterSecondaryPatch"));
    if (get(root, "masterOutputs").isArray()) {
        p.masterOutputs.emplace();
        for (auto value : list(get(root, "masterOutputs")))
            p.masterOutputs->push_back(patch(value));
    }
    if (get(root, "savedCursor").isObject()) {
        auto cursor = get(root, "savedCursor");
        p.savedCursor = jaras::SavedProjectCursor{s(cursor, "songID"), num(cursor, "position")};
    }
    require(list(get(root, "songs")).size() <= 2048, "Too many songs.");
    size_t clipCount = 0;
    for (const auto &raw : list(get(root, "songs"))) {
        jaras::Song song;
        song.id = s(raw, "id");
        song.name = s(raw, "name");
        song.duration = num(raw, "duration");
        song.bpm = num(raw, "bpm", 120);
        song.beatsPerBar = (int)num(raw, "beatsPerBar", 4);
        song.beatUnit = (int)num(raw, "beatUnit", 4);
        song.regionOwnershipInitialized = flag(raw, "regionOwnershipInitialized");
        song.regionOwnershipVersion = (int)num(raw, "regionOwnershipVersion");
        if (get(raw, "timeSettings").isObject()) {
            auto value = get(raw, "timeSettings");
            jaras::ProjectTimeSettings time;
            time.divisions = (int)num(value, "divisions", 4);
            time.timebase = str(value, "timebase", "free") == "relative"
                                ? jaras::ProjectTimebase::relative
                                : jaras::ProjectTimebase::free;
            time.affectsMIDIItems = flag(value, "affectsMIDIItems");
            time.affectsAutomationLength = flag(value, "affectsAutomationLength", true);
            song.timeSettings = time;
        }
        for (const auto &rt : list(get(raw, "tracks"))) {
            jaras::Track t;
            t.id = s(rt, "id");
            t.name = s(rt, "name");
            t.role.id = s(rt, "role");
            t.volume = num(rt, "volume", 1);
            t.pan = num(rt, "pan");
            t.mute = flag(rt, "mute");
            t.solo = flag(rt, "solo");
            t.output = (int)num(rt, "output", 1);
            optionalNum(rt, "color", t.color);
            optionalNum(rt, "phaseInverted", t.phaseInverted);
            optionalNum(rt, "heightScale", t.heightScale);
            optionalText(rt, "parentTrackID", t.parentTrackID);
            optionalJSON(rt, "automation", t.automationJSON);
            optionalNum(rt, "midiInput", t.midiInput);
            optionalNum(rt, "midiChannel", t.midiChannel);
            optionalNum(rt, "inputMonitoring", t.inputMonitoring);
            optionalNum(rt, "recordingChannels", t.recordingChannels);
            optionalText(rt, "recordingFormat", t.recordingFormat);
            optionalNum(rt, "recordingPostFader", t.recordingPostFader);
            optionalNum(rt, "recordingPostFX", t.recordingPostFX);
            t.importedTimecodeItems = flag(rt, "importedTimecodeItems");
            if (get(rt, "inputPatch").isObject())
                t.inputPatch = patch(get(rt, "inputPatch"));
            if (get(rt, "timecode").isObject())
                t.timecode = timecode(get(rt, "timecode"));
            if (get(rt, "stereoLink").isObject()) {
                auto link = get(rt, "stereoLink");
                t.stereoLinkJSON = utf8(JSON::toString(link, true, 17));
                t.stereoLinkPartner = s(link, "partner");
                t.stereoLinkLeft = flag(link, "left");
            }
            if (get(rt, "routing").isObject()) {
                jaras::TrackRouting routing;
                routing.receives.clear();
                routing.transmitters.clear();
                auto rawRouting = get(rt, "routing");
                for (auto id : list(get(rawRouting, "receives")))
                    routing.receives.push_back(
                        id.isString() ? std::optional<ID>(utf8(id.toString())) : std::nullopt);
                for (auto id : list(get(rawRouting, "transmitters")))
                    routing.transmitters.push_back(
                        id.isString() ? std::optional<ID>(utf8(id.toString())) : std::nullopt);
                t.routing = routing;
            }
            if (get(rt, "patch").isObject())
                t.patch = patch(get(rt, "patch"));
            if (get(rt, "secondaryPatch").isObject())
                t.secondaryPatch = patch(get(rt, "secondaryPatch"));
            if (get(rt, "outputs").isArray()) {
                t.outputs.emplace();
                for (auto v : list(get(rt, "outputs")))
                    t.outputs->push_back(patch(v));
            }
            if (get(rt, "audioFile").isObject())
                t.audioFile = audioFile(get(rt, "audioFile"));
            if (get(rt, "clickSound").isObject())
                t.clickSound = audioFile(get(rt, "clickSound"));
            for (const auto &rc : list(get(rt, "clips"))) {
                require(++clipCount <= 200000, "Too many clips.");
                jaras::AudioClip c;
                c.id = s(rc, "id");
                c.name = s(rc, "name");
                c.startTime = num(rc, "startTime");
                c.duration = num(rc, "duration");
                c.sourceOffset = num(rc, "sourceOffset");
                c.playbackRate = num(rc, "playbackRate", 1);
                c.muted = flag(rc, "muted");
                optionalNum(rc, "gain", c.gain);
                optionalNum(rc, "pan", c.pan);
                optionalNum(rc, "phaseInverted", c.phaseInverted);
                optionalNum(rc, "normalizationGain", c.normalizationGain);
                optionalNum(rc, "fadeIn", c.fadeIn);
                optionalNum(rc, "fadeOut", c.fadeOut);
                optionalNum(rc, "fadeOutSCurve", c.fadeOutSCurve);
                optionalNum(rc, "fadeOutCurve", c.fadeOutCurve);
                optionalNum(rc, "fadeInSCurve", c.fadeInSCurve);
                optionalNum(rc, "fadeInCurve", c.fadeInCurve);
                optionalNum(rc, "channelMode", c.channelMode);
                optionalNum(rc, "loopStart", c.loopStart);
                optionalNum(rc, "loopLength", c.loopLength);
                optionalNum(rc, "recordingLane", c.recordingLane);
                optionalNum(rc, "timecodeStartOffset", c.timecodeStartOffset);
                optionalNum(rc, "timecodeEndOffset", c.timecodeEndOffset);
                optionalNum(rc, "fxBypassed", c.fxBypassed);
                optionalNum(rc, "frozenMIDI", c.frozenMIDI);
                optionalNum(rc, "renderedTiming", c.renderedTiming);
                optionalNum(rc, "pitchSemitones", c.pitchSemitones);
                optionalNum(rc, "tempoBasePlaybackRate", c.tempoBasePlaybackRate);
                optionalNum(rc, "renderedTempo", c.renderedTempo);
                optionalJSON(rc, "automation", c.automationJSON);
                if (get(rc, "timecode").isObject())
                    c.timecode = timecode(get(rc, "timecode"));
                if (get(rc, "midi").isObject())
                    c.midi = midi(get(rc, "midi"));
                for (auto id : list(get(rc, "separatedStemTracks")))
                    c.separatedStemTracks.push_back(utf8(id.toString()));
                for (auto channel : list(get(rc, "waveformChannels"))) {
                    std::vector<double> values;
                    for (auto sample : list(channel))
                        values.push_back((double)sample);
                    c.waveformChannels.push_back(values);
                }
                optionalText(rc, "regionOwnerID", c.regionOwnerID);
                optionalText(rc, "text", c.text);
                if (get(rc, "audioFile").isObject())
                    c.audioFile = audioFile(get(rc, "audioFile"));
                for (auto sample : list(get(rc, "waveform")))
                    c.waveform.push_back((double)sample);
                if (get(rc, "fx").isObject())
                    c.fxJSON = utf8(JSON::toString(get(rc, "fx"), true, 17));
                t.clips.push_back(std::move(c));
            }
            if (get(rt, "fx").isObject())
                t.fxJSON = utf8(JSON::toString(get(rt, "fx"), true, 17));
            song.tracks.push_back(std::move(t));
        }
        for (const auto &rp : list(get(raw, "parts"))) {
            jaras::Part part;
            part.id = s(rp, "id");
            part.name = s(rp, "name");
            part.startTime = num(rp, "startTime");
            part.endTime = num(rp, "endTime");
            optionalNum(rp, "color", part.color);
            optionalText(rp, "parentRegionID", part.parentRegionID);
            optionalNum(rp, "uppercaseName", part.uppercaseName);
            optionalNum(rp, "subplayInitSeconds", part.subplayInitSeconds);
            optionalNum(rp, "subplayInitBars", part.subplayInitBars);
            optionalNum(rp, "pitchSemitones", part.pitchSemitones);
            optionalNum(rp, "totalLoop", part.totalLoop);
            optionalIDs(rp, "pitchTrackIDs", part.pitchTrackIDs);
            optionalIDs(rp, "pitchGroupIDs", part.pitchGroupIDs);
            for (auto loop : list(get(rp, "multiLoops")))
                part.multiLoops.push_back(multiLoop(loop));
            song.parts.push_back(std::move(part));
        }
        if (get(raw, "markers").isArray()) {
            song.markers.emplace();
            for (const auto &rm : list(get(raw, "markers"))) {
                jaras::TimelineMarker m;
                m.id = s(rm, "id");
                m.name = s(rm, "name");
                m.position = num(rm, "position");
                m.color = (unsigned)num(rm, "color");
                optionalNum(rm, "tempoBPM", m.tempoBPM);
                optionalNum(rm, "tempoBeats", m.tempoBeats);
                optionalNum(rm, "tempoUnit", m.tempoUnit);
                optionalNum(rm, "tempoReferenceBPM", m.tempoReferenceBPM);
                optionalText(rm, "tempoTimebase", m.tempoTimebase);
                optionalNum(rm, "section", m.section);
                optionalNum(rm, "loopSection", m.loopSection);
                optionalText(rm, "unifiedRegionID", m.unifiedRegionID);
                optionalText(rm, "sourceRegionID", m.sourceRegionID);
                optionalText(rm, "regionOwnerID", m.regionOwnerID);
                // Earlier Windows editors saved typed $/* cues as plain names.
                // Repair only those non-linked markers inside a song; native
                // typed markers already store their clean name and flags.
                if (!m.tempoBPM && !m.section.value_or(false) && !m.unifiedRegionID && !m.sourceRegionID &&
                    markerEditing::canCreateSection(song, m.position, true)) {
                    auto typed = m;
                    markerEditing::applyPrefix(typed);
                    if (markerEditing::isSection(typed) && text(typed.name).trim().isNotEmpty()) {
                        typed.name = utf8(unicodeCase(text(typed.name)).substring(0, 256));
                        m = std::move(typed);
                    }
                }
                song.markers->push_back(std::move(m));
            }
        }
        p.songs.push_back(std::move(song));
    }
    for (auto raw : list(get(root, "setlists"))) {
        jaras::Setlist sl;
        sl.id = s(raw, "id");
        sl.name = s(raw, "name");
        for (auto v : list(get(raw, "songIds")))
            sl.songIds.push_back(utf8(v.toString()));
        p.setlists.push_back(std::move(sl));
    }
    const auto rs = get(root, "regionSetlist");
    if (rs.isObject()) {
        jaras::RegionSetlist state;
        state.autoAdvance = flag(rs, "autoAdvance");
        state.autoUntilBlockEnd = flag(rs, "autoUntilBlockEnd");
        optionalText(rs, "selectedId", state.selectedId);
        optionalNum(rs, "stopAtRegionEnd", state.stopAtRegionEnd);
        optionalNum(rs, "automaticSubplay", state.automaticSubplay);
        optionalNum(rs, "automaticSubplaySeconds", state.automaticSubplaySeconds);
        optionalNum(rs, "automaticSubplayBars", state.automaticSubplayBars);
        optionalNum(rs, "automaticSubplayNext", state.automaticSubplayNext);
        optionalNum(rs, "prepareWithoutPlayback", state.prepareWithoutPlayback);
        optionalNum(rs, "liveEnabled", state.liveEnabled);
        optionalIDs(rs, "playedLiveRegionIDs", state.playedLiveRegionIDs);
        for (auto raw : list(get(rs, "playlists"))) {
            jaras::RegionPlaylist pl;
            pl.id = s(raw, "id");
            pl.name = s(raw, "name");
            pl.songId = s(raw, "songId");
            for (auto v : list(get(raw, "regionIds")))
                pl.regionIds.push_back(utf8(v.toString()));
            state.playlists.push_back(std::move(pl));
        }
        if (get(rs, "blocks").isArray()) {
            state.blocks.emplace();
            for (auto rb : list(get(rs, "blocks"))) {
                jaras::SetlistBlock b;
                b.id = s(rb, "id");
                b.songId = s(rb, "songId");
                b.name = s(rb, "name");
                b.color = (unsigned)num(rb, "color");
                optionalText(rb, "playlistId", b.playlistId);
                optionalText(rb, "beforeRegionId", b.beforeRegionId);
                optionalNum(rb, "symbol", b.symbol);
                state.blocks->push_back(b);
            }
        }
        p.regionSetlist = state;
    }
    jaras::validate(p);
    return p;
}
var ProjectCodec::encode(const jaras::Project &p, const var &input) {
    const auto original = canonicalIDs(input);
    jaras::validate(p);
    auto root = merged(original);
    put(root, "id", text(p.id));
    put(root, "name", text(p.name));
    emit(root, "timelineMovementLocked", p.timelineMovementLocked);
    if (p.projectSyncID) put(root, "projectSyncID", text(*p.projectSyncID));
    else root.getDynamicObject()->removeProperty("projectSyncID");
    put(root, "projectFormatVersion", p.projectFormatVersion);
    put(root, "minimumJarasVersion", "1.0.0");
    put(root, "createdAt", text(p.createdAt));
    put(root, "updatedAt", text(p.updatedAt));
    putDefault(root, "masterVolume", p.masterVolume, 1.0);
    putDefault(root, "masterPan", p.masterPan, 0.0);
    putDefault(root, "masterMute", p.masterMute, false);
    putDefault(root, "masterSolo", p.masterSolo, false);
    putDefault(root, "masterMono", p.masterMono, false);
    emitJSON(root, "masterAutomation", p.masterAutomationJSON);
    emit(root, "masterPatch", p.masterPatch);
    emit(root, "masterSecondaryPatch", p.masterSecondaryPatch);
    if (p.masterPhaseInverted)
        put(root, "masterPhaseInverted", *p.masterPhaseInverted);
    if (p.masterColor)
        put(root, "masterColor", (int64)*p.masterColor);
    if (p.masterSecondaryPatch)
        put(root, "masterSecondaryPatch", patchJSON(*p.masterSecondaryPatch));
    if (p.masterOutputs) {
        Array<var> patches;
        for (const auto &value : *p.masterOutputs)
            patches.add(patchJSON(value));
        put(root, "masterOutputs", patches);
    }
    if (p.savedCursor) {
        auto cursor = object();
        put(cursor, "songID", text(p.savedCursor->songID));
        put(cursor, "position", p.savedCursor->position);
        put(root, "savedCursor", cursor);
    }
    if (p.masterFXJSON)
        put(root, "masterFX", fxschema::complete(JSON::parse(text(*p.masterFXJSON))));
    else remove(root, "masterFX");
    if (p.masterPatch)
        put(root, "masterPatch", patchJSON(*p.masterPatch));
    Array<var> songs;
    for (const auto &song : p.songs) {
        auto raw = merged(byId(get(original, "songs"), song.id));
        put(raw, "id", text(song.id));
        put(raw, "name", text(song.name));
        put(raw, "duration", song.duration);
        put(raw, "bpm", song.bpm);
        putDefault(raw, "beatsPerBar", song.beatsPerBar, 4);
        putDefault(raw, "beatUnit", song.beatUnit, 4);
        if (song.timeSettings) {
            auto value = merged(get(raw, "timeSettings"));
            put(value, "divisions", song.timeSettings->divisions);
            put(value, "timebase",
                song.timeSettings->timebase == jaras::ProjectTimebase::relative ? "relative"
                                                                                : "free");
            put(value, "affectsMIDIItems", song.timeSettings->affectsMIDIItems);
            put(value, "affectsAutomationLength", song.timeSettings->affectsAutomationLength);
            put(raw, "timeSettings", value);
        }
        if (song.regionOwnershipInitialized || !get(raw, "regionOwnershipInitialized").isVoid())
            put(raw, "regionOwnershipInitialized", song.regionOwnershipInitialized);
        if (song.regionOwnershipVersion || !get(raw, "regionOwnershipVersion").isVoid())
            put(raw, "regionOwnershipVersion", song.regionOwnershipVersion);
        Array<var> tracks;
        for (const auto &t : song.tracks) {
            auto rt = merged(byId(get(raw, "tracks"), t.id));
            put(rt, "id", text(t.id));
            put(rt, "name", text(t.name));
            put(rt, "role", text(t.role.id));
            put(rt, "volume", t.volume);
            put(rt, "pan", t.pan);
            put(rt, "mute", t.mute);
            put(rt, "solo", t.solo);
            put(rt, "output", t.output);
            emitJSON(rt, "automation", t.automationJSON);
            emitJSON(rt, "stereoLink", t.stereoLinkJSON);
            emit(rt, "midiInput", t.midiInput);
            emit(rt, "midiChannel", t.midiChannel);
            emit(rt, "inputMonitoring", t.inputMonitoring);
            emit(rt, "recordingChannels", t.recordingChannels);
            emit(rt, "recordingFormat", t.recordingFormat);
            emit(rt, "recordingPostFader", t.recordingPostFader);
            emit(rt, "recordingPostFX", t.recordingPostFX);
            emit(rt, "inputPatch", t.inputPatch);
            emit(rt, "patch", t.patch);
            emit(rt, "secondaryPatch", t.secondaryPatch);
            emit(rt, "parentTrackID", t.parentTrackID);
            emit(rt, "audioFile", t.audioFile);
            emit(rt, "clickSound", t.clickSound);
            if (!t.outputs)
                remove(rt, "outputs");
            if (t.timecode)
                put(rt, "timecode", timecodeJSON(*t.timecode));
            else
                remove(rt, "timecode");
            if (t.importedTimecodeItems || !get(rt, "importedTimecodeItems").isVoid())
                put(rt, "importedTimecodeItems", t.importedTimecodeItems);
            if (t.routing) {
                auto value = merged(get(rt, "routing"));
                Array<var> receives, transmitters;
                for (const auto &id : t.routing->receives)
                    receives.add(id ? var(text(*id)) : var());
                for (const auto &id : t.routing->transmitters)
                    transmitters.add(id ? var(text(*id)) : var());
                put(value, "receives", receives);
                put(value, "transmitters", transmitters);
                put(rt, "routing", value);
            } else
                remove(rt, "routing");
            if (t.fxJSON)
                put(rt, "fx", fxschema::complete(JSON::parse(text(*t.fxJSON))));
            else remove(rt, "fx");
            if (t.color)
                put(rt, "color", (int64)*t.color);
            if (t.patch)
                put(rt, "patch", patchJSON(*t.patch));
            if (t.secondaryPatch)
                put(rt, "secondaryPatch", patchJSON(*t.secondaryPatch));
            if (t.outputs) {
                Array<var> patches;
                for (const auto &value : *t.outputs)
                    patches.add(patchJSON(value));
                put(rt, "outputs", patches);
            }
            if (t.parentTrackID)
                put(rt, "parentTrackID", text(*t.parentTrackID));
            if (t.heightScale)
                put(rt, "heightScale", *t.heightScale);
            if (t.phaseInverted)
                put(rt, "phaseInverted", *t.phaseInverted);
            if (t.audioFile)
                put(rt, "audioFile", audioJSON(*t.audioFile));
            if (t.clickSound)
                put(rt, "clickSound", audioJSON(*t.clickSound));
            Array<var> clips;
            for (const auto &c : t.clips) {
                auto rc = merged(byId(get(rt, "clips"), c.id));
                put(rc, "id", text(c.id));
                put(rc, "name", text(c.name));
                put(rc, "startTime", c.startTime);
                put(rc, "duration", c.duration);
                put(rc, "sourceOffset", c.sourceOffset);
                putDefault(rc, "playbackRate", c.playbackRate, 1.0);
                putDefault(rc, "muted", c.muted, false);
                emitJSON(rc, "automation", c.automationJSON);
                emit(rc, "audioFile", c.audioFile);
                emit(rc, "normalizationGain", c.normalizationGain);
                emit(rc, "recordingLane", c.recordingLane);
                emit(rc, "channelMode", c.channelMode);
                emit(rc, "loopStart", c.loopStart);
                emit(rc, "loopLength", c.loopLength);
                emit(rc, "timecodeStartOffset", c.timecodeStartOffset);
                emit(rc, "timecodeEndOffset", c.timecodeEndOffset);
                emit(rc, "fxBypassed", c.fxBypassed);
                emit(rc, "frozenMIDI", c.frozenMIDI);
                emit(rc, "renderedTiming", c.renderedTiming);
                emit(rc, "pitchSemitones", c.pitchSemitones);
                emit(rc, "tempoBasePlaybackRate", c.tempoBasePlaybackRate);
                emit(rc, "renderedTempo", c.renderedTempo);
                if (c.midi)
                    put(rc, "midi", midiJSON(*c.midi, get(rc, "midi")));
                else
                    remove(rc, "midi");
                if (c.timecode)
                    put(rc, "timecode", timecodeJSON(*c.timecode));
                else
                    remove(rc, "timecode");
                if (!c.separatedStemTracks.empty() || get(rc, "separatedStemTracks").isArray())
                    put(rc, "separatedStemTracks", idsJSON(c.separatedStemTracks));
                if (!c.waveformChannels.empty() || get(rc, "waveformChannels").isArray()) {
                    Array<var> channels;
                    for (const auto &samples : c.waveformChannels) {
                        Array<var> channel;
                        for (auto sample : samples)
                            channel.add(sample);
                        channels.add(channel);
                    }
                    put(rc, "waveformChannels", channels);
                }
                if (c.fxJSON)
                    put(rc, "fx", fxschema::complete(JSON::parse(text(*c.fxJSON))));
                else remove(rc, "fx");
                if (c.audioFile)
                    put(rc, "audioFile", audioJSON(*c.audioFile));
                if (c.gain)
                    put(rc, "gain", *c.gain);
                if (c.pan)
                    put(rc, "pan", *c.pan);
                if (c.phaseInverted)
                    put(rc, "phaseInverted", *c.phaseInverted);
                if (c.fadeIn)
                    put(rc, "fadeIn", *c.fadeIn);
                if (c.fadeOut)
                    put(rc, "fadeOut", *c.fadeOut);
                if (c.fadeOutSCurve) put(rc, "fadeOutSCurve", *c.fadeOutSCurve); else rc.getDynamicObject()->removeProperty("fadeOutSCurve");
                if (c.fadeOutCurve) put(rc, "fadeOutCurve", *c.fadeOutCurve); else rc.getDynamicObject()->removeProperty("fadeOutCurve");
                if (c.fadeInSCurve) put(rc, "fadeInSCurve", *c.fadeInSCurve); else rc.getDynamicObject()->removeProperty("fadeInSCurve");
                if (c.fadeInCurve) put(rc, "fadeInCurve", *c.fadeInCurve); else rc.getDynamicObject()->removeProperty("fadeInCurve");
                if (c.regionOwnerID)
                    put(rc, "regionOwnerID", text(*c.regionOwnerID));
                if (c.text)
                    put(rc, "text", text(*c.text));
                Array<var> peaks;
                for (auto sample : c.waveform)
                    peaks.add(sample);
                put(rc, "waveform", peaks);
                clips.add(rc);
            }
            put(rt, "clips", clips);
            tracks.add(rt);
        }
        put(raw, "tracks", tracks);
        Array<var> parts;
        for (const auto &part : song.parts) {
            auto rp = merged(byId(get(raw, "parts"), part.id));
            put(rp, "id", text(part.id));
            put(rp, "name", text(part.name));
            put(rp, "startTime", part.startTime);
            put(rp, "endTime", part.endTime);
            // The original carries unknown importer metadata. Optional fields
            // owned by this model must also be removed after an explicit edit,
            // especially parentRegionID when a saved family is disunified.
            emit(rp, "color", part.color);
            emit(rp, "parentRegionID", part.parentRegionID);
            emit(rp, "uppercaseName", part.uppercaseName);
            emit(rp, "subplayInitSeconds", part.subplayInitSeconds);
            emit(rp, "subplayInitBars", part.subplayInitBars);
            emit(rp, "pitchSemitones", part.pitchSemitones);
            emit(rp, "totalLoop", part.totalLoop);
            if (part.pitchTrackIDs)
                put(rp, "pitchTrackIDs", idsJSON(*part.pitchTrackIDs));
            else
                remove(rp, "pitchTrackIDs");
            if (part.pitchGroupIDs)
                put(rp, "pitchGroupIDs", idsJSON(*part.pitchGroupIDs));
            else
                remove(rp, "pitchGroupIDs");
            if (!part.multiLoops.empty() || get(rp, "multiLoops").isArray()) {
                Array<var> loops;
                for (const auto &loop : part.multiLoops)
                    loops.add(multiLoopJSON(loop, byId(get(rp, "multiLoops"), loop.id)));
                put(rp, "multiLoops", loops);
            }
            parts.add(rp);
        }
        put(raw, "parts", parts);
        if (song.markers) {
            Array<var> markers;
            for (const auto &m : *song.markers) {
                auto rm = merged(byId(get(raw, "markers"), m.id));
                put(rm, "id", text(m.id));
                put(rm, "name", text(m.name));
                put(rm, "position", m.position);
                put(rm, "color", (int64)m.color);
                emit(rm, "tempoBeats", m.tempoBeats);
                emit(rm, "tempoUnit", m.tempoUnit);
                emit(rm, "tempoReferenceBPM", m.tempoReferenceBPM);
                emit(rm, "tempoTimebase", m.tempoTimebase);
                emit(rm, "unifiedRegionID", m.unifiedRegionID);
                emit(rm, "sourceRegionID", m.sourceRegionID);
                emit(rm, "regionOwnerID", m.regionOwnerID);
                emit(rm, "tempoBPM", m.tempoBPM);
                emit(rm, "section", m.section);
                emit(rm, "loopSection", m.loopSection);
                markers.add(rm);
            }
            put(raw, "markers", markers);
        } else remove(raw, "markers");
        songs.add(raw);
    }
    put(root, "songs", songs);
    Array<var> setlists;
    for (const auto &sl : p.setlists) {
        auto raw = merged(byId(get(original, "setlists"), sl.id));
        put(raw, "id", text(sl.id));
        put(raw, "name", text(sl.name));
        Array<var> ids;
        for (auto &id : sl.songIds)
            ids.add(text(id));
        put(raw, "songIds", ids);
        setlists.add(raw);
    }
    put(root, "setlists", setlists);
    if (p.regionSetlist) {
        const auto &state = *p.regionSetlist;
        auto rs = merged(get(original, "regionSetlist"));
        put(rs, "autoAdvance", state.autoAdvance);
        putDefault(rs, "autoUntilBlockEnd", state.autoUntilBlockEnd, false);
        emit(rs, "selectedId", state.selectedId);
        emit(rs, "stopAtRegionEnd", state.stopAtRegionEnd);
        emit(rs, "prepareWithoutPlayback", state.prepareWithoutPlayback);
        emit(rs, "automaticSubplay", state.automaticSubplay);
        emit(rs, "automaticSubplaySeconds", state.automaticSubplaySeconds);
        emit(rs, "automaticSubplayBars", state.automaticSubplayBars);
        emit(rs, "automaticSubplayNext", state.automaticSubplayNext);
        emit(rs, "liveEnabled", state.liveEnabled);
        if (state.playedLiveRegionIDs)
            put(rs, "playedLiveRegionIDs", idsJSON(*state.playedLiveRegionIDs));
        else
            remove(rs, "playedLiveRegionIDs");
        Array<var> playlists;
        for (const auto &playlist : state.playlists) {
            auto value = merged(byId(get(rs, "playlists"), playlist.id));
            put(value, "id", text(playlist.id));
            put(value, "name", text(playlist.name));
            put(value, "songId", text(playlist.songId));
            put(value, "regionIds", idsJSON(playlist.regionIds));
            playlists.add(value);
        }
        put(rs, "playlists", playlists);
        if (state.blocks) {
            Array<var> blocks;
            for (const auto &block : *state.blocks) {
                auto value = merged(byId(get(rs, "blocks"), block.id));
                put(value, "id", text(block.id));
                put(value, "songId", text(block.songId));
                put(value, "name", text(block.name));
                put(value, "color", (int64)block.color);
                emit(value, "playlistId", block.playlistId);
                emit(value, "beforeRegionId", block.beforeRegionId);
                emit(value, "symbol", block.symbol);
                blocks.add(value);
            }
            put(rs, "blocks", blocks);
        } else
            remove(rs, "blocks");
        put(root, "regionSetlist", rs);
    } else
        remove(root, "regionSetlist");
    return canonicalIDs(root);
}
} // namespace catlive
