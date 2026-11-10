#pragma once
#include "PortablePackage.h"

// Wire format shared with Application/Project/PartialProjectPackage.swift.
// Existing iPad objects are containers only: their mixer/FX state is never replaced.
namespace catlive::partialPackage {
using packageZIP::require;
using packageZIP::Record;
inline void erase(var value, const char *key) { if (auto *object = value.getDynamicObject()) object->removeProperty(key); }
inline var identified(const Array<var> &items, const String &id) {
    for (auto item : items) if (str(item, "id") == id) return item;
    return {};
}
inline Array<var> ids(const Array<var> &items) {
    Array<var> result; for (auto item : items) result.add(get(item, "id")); return result;
}
inline Array<var> newObjects(const Array<var> &items, const Array<var> &old) {
    Array<var> result;
    for (auto item : items) if (!identified(old, str(item, "id")).isObject()) result.add(item);
    return result;
}
inline Array<var> newValues(const Array<var> &items, const Array<var> &old) {
    Array<var> result; for (auto item : items) if (!old.contains(item)) result.add(item); return result;
}
inline var newFX(const var &source, const var &baseline) {
    if (!source.isObject()) return {};
    const auto known = list(get(baseline, "inserted")), order = list(get(source, "inserted"));
    const auto instances = list(get(source, "instances"));
    std::set<String> aliases;
    for (auto old : known) {
        const auto kind = old.toString();
        if (kind.startsWith("Native:") || order.contains(old)) continue;
        String promoted;
        for (int i = 0; i < instances.size(); ++i) {
            const auto instance = instances[i]; const auto key = "Native:" + str(instance, "id");
            if (str(instance, "kind") == kind && order.contains(var(key)) && !known.contains(var(key))) {
                if (promoted.isEmpty()) promoted = key;
                if (str(instance, "legacyOrigin") == kind) { promoted = key; break; }
            }
        }
        if (promoted.isNotEmpty()) aliases.insert(promoted);
    }
    for (auto value : order) if (!value.toString().startsWith("Native:") && !known.contains(value)) {
        for (auto instance : list(get(baseline, "instances"))) {
            const auto key = "Native:" + str(instance, "id");
            if (str(instance, "kind") == value.toString() && known.contains(var(key)) && !order.contains(var(key))) aliases.insert(value.toString());
        }
    }
    Array<var> added, selected;
    for (auto key : order) if (!known.contains(key) && !key.toString().startsWith("External:") && !aliases.count(key.toString())) added.add(key);
    if (added.isEmpty()) return {};
    auto result = source.clone();
    for (auto instance : instances) if (added.contains(var("Native:" + str(instance, "id")))) selected.add(instance);
    put(result, "inserted", added); put(result, "instances", selected); erase(result, "externalPlugins");
    return result;
}
inline var delta(const var &saved, const var &snapshot) {
    auto baseline = ProjectCodec::canonicalIDs(get(snapshot, "project"));
    StringArray removed; std::set<String> capabilities;
    auto project = portablePackage::portableCopy(ProjectCodec::canonicalIDs(saved), removed, capabilities);
    require(str(project, "id") == str(baseline, "id"), "O .jlpartial pertence a outro projeto.");
    ProjectCodec::decode(project); ProjectCodec::decode(baseline);
    auto result = object();
    put(result, "format", "catlive-partial-additions"); put(result, "version", 1);
    put(result, "id", Uuid().toDashedString().toUpperCase());
    put(result, "createdAt", Time::getCurrentTime().toISO8601(true)); put(result, "baselineID", get(snapshot, "id"));
    Array<var> existingSongs, existingTracks, existingClips, songs;
    put(project, "masterFX", newFX(get(project, "masterFX"), get(baseline, "masterFX")));
    erase(project, "masterAutomation"); erase(project, "reductionDraft");
    for (auto song : list(get(project, "songs"))) {
        auto old = identified(list(get(baseline, "songs")), str(song, "id"));
        if (!old.isObject()) { songs.add(song); continue; }
        put(song, "parts", newObjects(list(get(song, "parts")), list(get(old, "parts"))));
        put(song, "markers", newObjects(list(get(song, "markers")), list(get(old, "markers"))));
        Array<var> tracks;
        for (auto track : list(get(song, "tracks"))) {
            auto previous = identified(list(get(old, "tracks")), str(track, "id"));
            if (!previous.isObject()) { tracks.add(track); continue; }
            put(track, "fx", newFX(get(track, "fx"), get(previous, "fx")));
            Array<var> clips;
            for (auto clip : list(get(track, "clips"))) {
                auto oldClip = identified(list(get(previous, "clips")), str(clip, "id"));
                if (oldClip.isObject()) {
                    put(clip, "fx", newFX(get(clip, "fx"), get(oldClip, "fx")));
                    if (!get(clip, "fx").isObject()) continue;
                    erase(clip, "audioFile"); existingClips.add(get(clip, "id"));
                } else if (!get(clip, "audioFile").isObject() && get(track, "audioFile").isObject()) put(clip, "audioFile", get(track, "audioFile").clone());
                clips.add(clip);
            }
            put(track, "clips", clips);
            put(track, "programChanges", newObjects(list(get(track, "programChanges")), list(get(previous, "programChanges"))));
            erase(track, "audioFile"); erase(track, "clickSound"); erase(track, "automation");
            if (clips.isEmpty() && list(get(track, "programChanges")).isEmpty() && !get(track, "fx").isObject()) continue;
            tracks.add(track); existingTracks.add(get(track, "id"));
        }
        put(song, "tracks", tracks);
        if (tracks.isEmpty() && list(get(song, "parts")).isEmpty() && list(get(song, "markers")).isEmpty()) continue;
        songs.add(song); existingSongs.add(get(song, "id"));
    }
    put(project, "songs", songs);
    Array<var> setlists;
    for (auto entry : list(get(project, "setlists"))) {
        auto old = identified(list(get(baseline, "setlists")), str(entry, "id"));
        if (old.isObject()) { put(entry, "songIds", newValues(list(get(entry, "songIds")), list(get(old, "songIds")))); if (list(get(entry, "songIds")).isEmpty()) continue; }
        setlists.add(entry);
    }
    put(project, "setlists", setlists);
    auto state = get(project, "regionSetlist"), oldState = get(baseline, "regionSetlist");
    if (state.isObject()) {
        Array<var> playlists;
        for (auto entry : list(get(state, "playlists"))) {
            auto old = identified(list(get(oldState, "playlists")), str(entry, "id"));
            if (old.isObject()) {
                put(entry, "regionIds", newValues(list(get(entry, "regionIds")), list(get(old, "regionIds"))));
                put(entry, "duplicates", newObjects(list(get(entry, "duplicates")), list(get(old, "duplicates"))));
                if (list(get(entry, "regionIds")).isEmpty()) continue;
            }
            playlists.add(entry);
        }
        put(state, "playlists", playlists);
        put(state, "blocks", newObjects(list(get(state, "blocks")), list(get(oldState, "blocks"))));
    }
    put(result, "existingSongs", existingSongs); put(result, "existingTracks", existingTracks); put(result, "existingClips", existingClips);
    put(result, "existingSetlists", ids(list(get(baseline, "setlists"))));
    put(result, "existingRegionPlaylists", ids(list(get(oldState, "playlists"))));
    put(result, "project", project); return result;
}
inline void eachFX(const var &project, const std::function<void(var)> &visit) {
    visit(get(project, "masterFX"));
    for (auto song : list(get(project, "songs"))) for (auto track : list(get(song, "tracks"))) {
        visit(get(track, "fx")); for (auto clip : list(get(track, "clips"))) visit(get(clip, "fx"));
    }
}
inline void eachFile(const var &project, const std::function<void(var)> &visit) {
    for (auto song : list(get(project, "songs"))) for (auto track : list(get(song, "tracks"))) {
        visit(get(track, "audioFile")); visit(get(track, "clickSound"));
        for (auto clip : list(get(track, "clips"))) visit(get(clip, "audioFile"));
    }
}
inline std::set<String> mediaPaths(const var &project) {
    std::set<String> paths;
    eachFile(project, [&](var file) { if (file.isObject()) paths.insert(str(file, "path")); });
    std::set<std::string> samples; eachFX(project, [&](var fx) { dynamicsAssets::collect(fx, samples); });
    for (auto &path : samples) paths.insert(text(path)); return paths;
}
inline void instrumentIDs(const var &fx, std::set<String> &result, int depth = 0) {
    require(depth < 16);
    for (auto settings : instrumentAssets::settings(fx, true)) result.insert(str(settings, "instrumentID"));
    for (auto instance : list(get(fx, "instances"))) instrumentIDs(get(instance, "settings"), result, depth + 1);
}
inline std::set<String> instruments(const var &project) {
    std::set<String> result; eachFX(project, [&](var fx) { instrumentIDs(fx, result); }); return result;
}
inline std::map<String, Record> inventory(const var &snapshot) {
    std::map<String, Record> result; std::set<String> names; uint64 total = 0;
    const auto values = list(get(snapshot, "files")); require(values.size() <= 100000);
    for (auto value : values) {
        const auto path = str(value, "path"), sha = str(value, "sha256").toLowerCase();
        const auto bytes = get(value, "bytes");
        packageZIP::validatePath(path);
        require((bytes.isInt() || bytes.isInt64()) && (int64)bytes >= 0 && (uint64)(int64)bytes <= 1099511627776ULL - total &&
                names.insert(unicodeCase(path, false)).second && sha.length() == 64 && sha.containsOnly("0123456789abcdef"), "Inventário parcial inválido.");
        total += (uint64)(int64)bytes; result[path] = {path, sha, (uint64)(int64)bytes};
    }
    const auto project = get(snapshot, "project"), banks = get(snapshot, "instruments");
    auto allowed = mediaPaths(project); auto ids = instruments(project);
    require(banks.isObject() && (size_t)banks.getDynamicObject()->getProperties().size() == ids.size());
    for (auto id : ids) {
        require(instrumentAssets::validID(id) && str(banks, utf8(id).c_str()) == "Instruments/" + id + ".sf2");
        allowed.insert("Instruments/" + id + ".sf2");
    }
    require(result.size() == allowed.size()); for (auto path : allowed) require(result.count(path));
    return result;
}
inline var readSnapshot(const File &file) {
    portablePackage::plainFile(file);
    require(file.hasFileExtension("jlpartial") && file.getSize() <= 134217728, "Escolha o .jlpartial exportado no iPad.");
    auto value = JSON::parse(file.loadFileAsString());
    require(str(value, "format") == "catlive-jlpartial" && num(value, "version") == 1 && !Uuid(str(value, "id")).isNull(), "Inventário parcial não suportado.");
    ProjectCodec::decode(get(value, "project")); inventory(value); return value;
}
inline String filename(const File &document) {
    return File::createLegalFileName(document.getFileNameWithoutExtension()).substring(0, 100) + "-" + Time::getCurrentTime().formatted("%d-%m-%Y") + ".ziplivepartial";
}
inline void exportPackage(const var &saved, const File &directory, const File &baselineFile, const File &archive, const std::function<void(double)> &progress) {
    require(archive.hasFileExtension("ziplivepartial")); portablePackage::plainFile(archive, false);
    const auto baseline = readSnapshot(baselineFile); const auto known = inventory(baseline);
    auto payload = delta(saved, baseline), project = get(payload, "project"), banks = object();
    std::map<String, Record> records, reused; std::map<String, File> sources; std::map<String, String> mapping;
    const auto oldBanks = get(baseline, "instruments");
    std::set<String> oldBankPaths;
    for (auto id : instruments(get(baseline, "project"))) oldBankPaths.insert(str(oldBanks, utf8(id).c_str()));
    uint64 total = 0;
    auto add = [&](Record record, File source) { require(record.bytes <= 1099511627776ULL - total); total += record.bytes; sources[record.path] = source; records[record.path] = record; };
    const auto media = mediaPaths(project); int index = 0;
    for (auto path : media) {
        packageZIP::validatePath(path); auto file = ProjectCodec::resolveMedia(directory, utf8(path)); portablePackage::plainFile(file);
        auto record = packageZIP::fingerprint(path, file); bool found = false;
        for (auto &[key, old] : known) {
            if (!oldBankPaths.count(key) && old.sha256 == record.sha256 && old.bytes == record.bytes) { mapping[path] = key; reused[key] = old; found = true; break; }
        }
        ++index;
        if (!found) {
            record.path = "Stems/Partial-" + str(payload, "id") + "/" + String(index) + "-" + file.getFileName(); packageZIP::validatePath(record.path);
            mapping[path] = record.path; add(record, file);
        }
        if (progress) progress(.2 * index / std::max<size_t>(1, media.size()));
    }
    for (auto id : instruments(project)) {
        require(instrumentAssets::validID(id)); auto source = instrumentAssets::resolve(id, directory); portablePackage::plainFile(source);
        require(instrumentAssets::validBank(source), "Instrumento nativo não encontrado.");
        auto path = "Instruments/" + id + ".sf2"; auto record = packageZIP::fingerprint(path, source);
        put(banks, utf8(id).c_str(), path);
        const auto oldPath = str(oldBanks, utf8(id).c_str());
        if (oldPath.isNotEmpty()) {
            const auto old = known.at(oldPath); require(old.sha256 == record.sha256 && old.bytes == record.bytes, "O instrumento foi alterado. Use outro identificador para o banco novo."); reused[oldPath] = old;
        } else add(record, source);
    }
    eachFile(project, [&](var file) { if (file.isObject()) put(file, "path", mapping.at(str(file, "path"))); });
    eachFX(project, [&](var fx) { dynamicsAssets::rewrite(fx, mapping); });
    auto document = portablePackage::jsonBytes(payload); require(document.getSize() <= 134217728);
    records["Partial.json"] = packageZIP::fingerprint("Partial.json", document);
    auto manifest = object(); put(manifest, "format", "catlive-ziplivepartial"); put(manifest, "version", 1);
    put(manifest, "projectID", get(project, "id")); put(manifest, "deltaID", get(payload, "id")); put(manifest, "document", "Partial.json"); put(manifest, "instruments", banks);
    Array<var> files, references; for (auto &[path, record] : records) files.add(portablePackage::recordJSON(record));
    for (auto &[path, record] : reused) references.add(portablePackage::recordJSON(record));
    put(manifest, "files", files); put(manifest, "reused", references);
    auto metadata = portablePackage::jsonBytes(manifest);
    require(metadata.getSize() <= 16777216 && records.size() + reused.size() <= 100000 && total + document.getSize() + metadata.getSize() <= 1099511627776ULL);
    const auto parent = archive.getParentDirectory(); require(parent.isDirectory() && parent.getBytesFreeOnVolume() > (int64)(total + document.getSize() + metadata.getSize() + 1048576), "Espaço insuficiente para exportar.");
    portablePackage::Temporary temporary{parent.getChildFile(".catlive-partial-" + Uuid().toString())};
    {
        packageZIP::Writer writer(temporary.path); writer.add("Partial.json", document); uint64 copied = 0;
        for (auto &[path, file] : sources) {
            FileInputStream input(file); require(!input.failedToOpen());
            writer.add(records.at(path), input, [&](uint64 bytes) { if (progress) progress(.2 + .79 * (double)(copied + bytes) / std::max<uint64>(1, total)); }); copied += records.at(path).bytes;
        }
        writer.add("manifest.json", metadata); writer.finish();
    }
    if (progress) progress(.999);
    require(MoveFileExW(temporary.path.getFullPathName().toWideCharPointer(), archive.getFullPathName().toWideCharPointer(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0, "Não foi possível finalizar a exportação.");
    if (progress) progress(1);
}
} // namespace catlive::partialPackage
