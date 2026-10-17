#pragma once
#include "ProjectCodec.h"
#include "InstrumentAssets.h"
#include "MediaCleanup.h"
#include "StoredProjectZIP.h"
namespace catlive::portablePackage {
using packageZIP::require;
inline void plainFile(const File &file, bool mustExist = true) {
    if (mustExist)
        require(file.existsAsFile(), "A package source is missing.");
    for (auto part = file;; part = part.getParentDirectory()) {
        const auto attributes = GetFileAttributesW(part.getFullPathName().toWideCharPointer());
        require(attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_REPARSE_POINT),
                "Choose files without symbolic links.");
        if (part == part.getParentDirectory())
            break;
    }
}
inline void cleanFX(var &fx, StringArray &removed, const String &location,
                    std::set<String> &capabilities) {
    if (!fx.isObject())
        return;
    for (auto plugin : list(get(fx, "externalPlugins")))
        removed.add(location + String::fromUTF8(" · ") + str(plugin, "name"));
    Array<var> inserted;
    for (auto key : list(get(fx, "inserted")))
        if (!key.toString().startsWith("External:")) {
            inserted.add(key);
            if (key.toString() == "CatStemSeparation 5")
                capabilities.insert("catstem-realtime");
        }
    put(fx, "inserted", inserted);
    fx.getDynamicObject()->removeProperty("externalPlugins");
    auto instances = list(get(fx, "instances"));
    for (auto &instance : instances) {
        auto settings = get(instance, "settings");
        cleanFX(settings, removed, location, capabilities);
        put(instance, "settings", settings);
    }
    if (get(fx, "instances").isArray())
        put(fx, "instances", instances);
}
inline var portableCopy(const var &raw, StringArray &removed, std::set<String> &capabilities) {
    auto result = raw.clone();
    auto clean = [&](var &owner, const char *fxKey, const char *automationKey, const String &location) {
        auto fx = get(owner, fxKey);
        cleanFX(fx, removed, location, capabilities);
        if (fx.isObject())
            put(owner, fxKey, fx);
        auto automation = get(owner, automationKey);
        if (automation.isObject()) {
            Array<var> envelopes;
            for (auto envelope : list(get(automation, "envelopes")))
                if (str(get(envelope, "target"), "kind") != "externalFX")
                    envelopes.add(envelope);
            put(automation, "envelopes", envelopes);
            put(owner, automationKey, automation);
        }
    };
    clean(result, "masterFX", "masterAutomation", "Master");
    auto songs = list(get(result, "songs"));
    for (auto &song : songs) {
        auto tracks = list(get(song, "tracks"));
        for (auto &track : tracks) {
            clean(track, "fx", "automation", str(track, "name"));
            auto clips = list(get(track, "clips"));
            for (auto &clip : clips)
                clean(clip, "fx", "automation", str(track, "name") + " / " + str(clip, "name"));
            put(track, "clips", clips);
        }
        put(song, "tracks", tracks);
    }
    put(result, "songs", songs);
    return result;
}
inline var recordJSON(const packageZIP::Record &record) {
    auto v = object();
    put(v, "path", record.path);
    put(v, "bytes", (int64)record.bytes);
    put(v, "sha256", record.sha256);
    return v;
}
inline MemoryBlock jsonBytes(const var &value) {
    auto s = JSON::toString(value);
    return MemoryBlock(s.toRawUTF8(), s.getNumBytesAsUTF8());
}
inline var json(const MemoryBlock &bytes) {
    var result;
    require(JSON::parse(String::fromUTF8((const char *)bytes.getData(), (int)bytes.getSize()), result)
                .wasOk());
    return result;
}
struct Temporary {
    File path;
    ~Temporary() { path.deleteRecursively(); }
};
inline void exportPackage(const var &saved, const File &directory, const File &archive,
                          const std::function<void(double)> &progress = {}, bool forceZIP64 = false) {
    require(archive.hasFileExtension("ziplive"), "Choose a .ziplive destination.");
    plainFile(archive, false);
    const auto original = ProjectCodec::decode(saved);
    StringArray removed;
    std::set<String> capabilities;
    auto raw = portableCopy(saved, removed, capabilities);
    auto project = ProjectCodec::decode(raw);
    std::map<String, File> sources;
    std::map<String, packageZIP::Record> records;
    std::set<String> names;
    std::map<String, String> mapping;
    uint64 total = 0;
    auto report = [&](double value) {
        if (progress)
            progress(value);
    };
    report(0);
    auto add = [&](const File &source, const String &proposed) {
        plainFile(source);
        require(source != archive, "The package cannot replace one of its source files.");
        auto record = packageZIP::fingerprint(proposed, source);
        auto path = proposed;
        int suffix = 1;
        while (names.count(unicodeCase(path, false))) {
            auto found = records.find(path);
            if (found != records.end() && found->second.sha256 == record.sha256 &&
                found->second.bytes == record.bytes)
                return path;
            auto name = proposed.fromLastOccurrenceOf("/", false, false);
            auto ext =
                name.containsChar('.') ? "." + name.fromLastOccurrenceOf(".", false, false) : String{};
            auto stem = ext.isEmpty() ? name : name.dropLastCharacters(ext.length());
            path = proposed.upToLastOccurrenceOf("/", true, false) + stem + "-" +
                   String(suffix++).paddedLeft('0', 3) + ext;
        }
        packageZIP::validatePath(path);
        require(record.bytes <= 1099511627776ULL - total, "The project exceeds the package size limit.");
        record.path = path;
        total += record.bytes;
        names.insert(unicodeCase(path, false));
        sources[path] = source;
        records[path] = record;
        return path;
    };
    auto media = mediaCleanup::references(original);
    auto ids = instrumentAssets::identities(project);
    require(media.size() + ids.size() + 2 <= 100000, "Too many files in this project.");
    size_t indexed = 0;
    for (const auto &path : media) {
        packageZIP::validatePath(text(path));
        auto source = ProjectCodec::resolveMedia(directory, path);
        mapping[text(path)] = add(source, (text(path).startsWith("Videos/") ? "Videos/" : "Stems/") +
                                              source.getFileName());
        report(.25 * ++indexed / std::max<size_t>(1, media.size() + ids.size()));
    }
    auto instruments = object();
    for (const auto &id : ids) {
        require(instrumentAssets::validID(id));
        auto source = instrumentAssets::resolve(id, directory);
        require(instrumentAssets::validBank(source), "Download the native instrument before exporting.");
        put(instruments, utf8(id).c_str(), add(source, "Instruments/" + id + ".sf2"));
        report(.25 * ++indexed / std::max<size_t>(1, media.size() + ids.size()));
    }
    auto rewrite = [&](std::optional<jaras::AudioFile> &file) {
        if (file)
            file->path = utf8(mapping.at(text(file->path)));
    };
    for (auto &song : project.songs)
        for (auto &track : song.tracks) {
            rewrite(track.audioFile);
            rewrite(track.clickSound);
            for (auto &clip : track.clips)
                rewrite(clip.audioFile);
        }
    auto document = ProjectCodec::seal(JSON::toString(ProjectCodec::encode(project, raw), true, 17));
    require(document.getSize() <= 134217728, "The project document is too large.");
    records["Project.jl"] = packageZIP::fingerprint("Project.jl", document);
    auto manifest = object();
    put(manifest, "format", "catlive-ziplive");
    put(manifest, "version", 1);
    put(manifest, "document", "Project.jl");
    put(manifest, "projectID", text(project.id));
    put(manifest, "instruments", instruments);
    Array<var> inventory, excluded, required;
    for (auto &[path, record] : records)
        inventory.add(recordJSON(record));
    for (auto &name : removed)
        excluded.add(name);
    for (auto &name : capabilities)
        required.add(name);
    put(manifest, "files", inventory);
    put(manifest, "removedPlugins", excluded);
    put(manifest, "requiredCapabilities", required);
    auto metadata = jsonBytes(manifest);
    require(metadata.getSize() <= 16777216 &&
            total + document.getSize() + metadata.getSize() <= 1099511627776ULL);
    auto parent = archive.getParentDirectory();
    require(parent.isDirectory() &&
                parent.getBytesFreeOnVolume() >
                    (int64)(total + document.getSize() + metadata.getSize() + 1048576),
            "There is not enough disk space to export the project.");
    Temporary temporary{parent.getChildFile(".catlive-export-" + Uuid().toString())};
    {
        packageZIP::Writer writer(temporary.path, forceZIP64);
        writer.add("Project.jl", document);
        uint64 copied = 0;
        for (auto &[path, source] : sources) {
            FileInputStream input(source);
            require(!input.failedToOpen());
            writer.add(records.at(path), input, [&](uint64 bytes) {
                report(.25 + .74 * (double)(copied + bytes) / std::max<uint64>(1, total));
            });
            copied += records.at(path).bytes;
        }
        writer.add("manifest.json", metadata);
        writer.finish();
    }
    require(MoveFileExW(temporary.path.getFullPathName().toWideCharPointer(),
                        archive.getFullPathName().toWideCharPointer(),
                        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0,
            "Cannot finish project export.");
    report(1);
}
inline File importPackage(const File &archive, const File &parent,
                          const std::function<void(double)> &progress = {}) {
    plainFile(archive);
    plainFile(parent, false);
    require(parent.isDirectory());
    packageZIP::Reader zip(archive);
    auto manifest = json(zip.data("manifest.json", 16777216));
    auto inventory = list(get(manifest, "files"));
    require(str(manifest, "format") == "catlive-ziplive" && num(manifest, "version") == 1 &&
                str(manifest, "document") == "Project.jl" &&
                inventory.size() + 1 == (int)zip.entries.size(),
            "Unsupported CatLive package.");
    std::map<String, packageZIP::Record> records;
    for (auto &record : inventory) {
        auto path = str(record, "path"), sha = str(record, "sha256");
        auto bytes = get(record, "bytes");
        packageZIP::validatePath(path);
        auto entry = zip.entries.find(path);
        require(path != "manifest.json" && !records.count(path) && entry != zip.entries.end() &&
                    (bytes.isInt() || bytes.isInt64()) && (int64)bytes >= 0 &&
                    entry->second.size == (uint64)(int64)bytes && sha.length() == 64 &&
                    sha.containsOnly("0123456789abcdefABCDEF"),
                "Invalid package inventory.");
        records[path] = {path, sha.toLowerCase(), (uint64)(int64)bytes};
    }
    require(records.count("Project.jl"));
    auto document = zip.data("Project.jl", 134217728);
    require(SHA256(document).toHexString() == records.at("Project.jl").sha256,
            "The project document failed its integrity check.");
    auto raw = JSON::parse(ProjectCodec::unseal(document));
    auto project = ProjectCodec::decode(raw);
    require(text(project.id).equalsIgnoreCase(str(manifest, "projectID")),
            "Package project identity mismatch.");
    StringArray removed;
    std::set<String> capabilities;
    auto clean = portableCopy(raw, removed, capabilities);
    require(removed.isEmpty() && JSON::toString(ProjectCodec::encode(ProjectCodec::decode(clean))) ==
                                     JSON::toString(ProjectCodec::encode(project)),
            "The package contains unsupported project data.");
    std::set<String> required;
    for (auto value : list(get(manifest, "requiredCapabilities")))
        required.insert(value.toString());
    require(required == capabilities);
    std::set<String> allowed{"Project.jl"};
    for (auto &path : mediaCleanup::references(project)) {
        require(text(path).startsWith("Stems/") || text(path).startsWith("Videos/"));
        allowed.insert(text(path));
    }
    auto instruments = get(manifest, "instruments");
    require(instruments.isObject());
    auto ids = instrumentAssets::identities(project);
    require(instruments.getDynamicObject()->getProperties().size() == (int)ids.size(),
            "Native instrument inventory is incomplete.");
    for (auto &id : ids) {
        require(instrumentAssets::validID(id) &&
                str(instruments, utf8(id).c_str()) == "Instruments/" + id + ".sf2");
        allowed.insert("Instruments/" + id + ".sf2");
    }
    require(allowed.size() == records.size());
    for (auto &path : allowed)
        require(records.count(path), "The package contains unreferenced or missing files.");
    require(parent.getBytesFreeOnVolume() >= (int64)zip.totalBytes,
            "There is not enough disk space to import the project.");
    Temporary temporary{parent.getChildFile(".catlive-import-" + Uuid().toString())};
    require(temporary.path.createDirectory().wasOk());
    uint64 copied = 0;
    for (auto &[path, record] : records) {
        auto target = ProjectCodec::resolveMedia(temporary.path, utf8(path), false);
        require(target.getParentDirectory().createDirectory().wasOk());
        zip.extract(record, target, [&](uint64 bytes) {
            if (progress)
                progress((double)(copied + bytes) / std::max<uint64>(1, zip.totalBytes));
        });
        copied += record.bytes;
    }
    for (auto &id : ids)
        require(instrumentAssets::validBank(temporary.path.getChildFile("Instruments/" + id + ".sf2")),
                "Invalid native instrument sound bank.");
    require(temporary.path.getChildFile("Stems/WF").createDirectory().wasOk() &&
            temporary.path.getChildFile("backups").createDirectory().wasOk());
    auto name = File::createLegalFileName(text(project.name)).substring(0, 80);
    if (name.isEmpty())
        name = "CatLive";
    auto local = name + ".jl";
    if (local != "Project.jl")
        require(
            temporary.path.getChildFile("Project.jl").moveFileTo(temporary.path.getChildFile(local)));
    auto destination = parent.getNonexistentChildFile(name, "", true);
    require(temporary.path.moveFileTo(destination), "Cannot finish project import.");
    if (progress)
        progress(1);
    return destination.getChildFile(local);
}
} // namespace catlive::portablePackage
namespace catlive {
inline File importPortablePackage(const File &archive, const File &parent) {
    return portablePackage::importPackage(archive, parent);
}
} // namespace catlive
