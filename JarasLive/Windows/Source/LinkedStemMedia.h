#pragma once
#include "Common.h"

namespace catlive {
class LinkedStemMedia {
    CriticalSection lock;
    var grants;
    std::map<String, String> idsByFolder;
    std::set<String> sourceFiles;
    File settings = File::getSpecialLocation(File::userApplicationDataDirectory)
        .getChildFile("Hook Developer/CatLive/linked-stem-folders.json");

    LinkedStemMedia() {
        grants = JSON::parse(settings);
        if (!grants.isObject()) grants = object();
        for (const auto &property : grants.getDynamicObject()->getProperties())
            idsByFolder.emplace(property.value.toString().toLowerCase(), property.name.toString());
    }
public:
    static LinkedStemMedia &shared() { static LinkedStemMedia registry; return registry; }
    static bool isReference(const String &path) {
        return path.startsWith("Stems/LinkedMedia/") || path.startsWith("Videos/LinkedMedia/");
    }
    String reference(const File &source, bool video) {
        const ScopedLock guard(lock);
        const auto folder = source.getParentDirectory().getFullPathName();
        auto found = idsByFolder.find(folder.toLowerCase());
        if (found == idsByFolder.end()) {
            const auto id = text(uuid());
            auto updated = grants.clone();
            put(updated,id,folder);
            if (settings.getParentDirectory().createDirectory().failed() || !settings.replaceWithText(JSON::toString(updated)))
                throw std::runtime_error("Could not remember the source folder.");
            grants = std::move(updated);
            found = idsByFolder.emplace(folder.toLowerCase(), id).first;
        }
        sourceFiles.insert(source.getFullPathName().toLowerCase());
        return String(video ? "Videos/LinkedMedia/" : "Stems/LinkedMedia/") + found->second + "/" + source.getFileName();
    }
    File resolve(const String &path, const File &local) {
        if (local.existsAsFile()) return local;
        const auto parts = StringArray::fromTokens(path,"/",{});
        if (parts.size()!=4 || parts[3].isEmpty() || parts[3]=="." || parts[3]==".." ||
            parts[3].containsAnyOf(":\\")) return local;
        const ScopedLock guard(lock);
        const auto directory = grants.getProperty(Identifier(parts[2]),{}).toString();
        if (directory.isEmpty()) return local;
        const auto source = File(directory).getChildFile(parts[3]);
        sourceFiles.insert(source.getFullPathName().toLowerCase());
        return source;
    }
    File waveform(const File &source) {
        const ScopedLock guard(lock);
        if (!sourceFiles.count(source.getFullPathName().toLowerCase())) return {};
        return source.getSiblingFile("WF").getChildFile(source.getFileName()+".waveform");
    }
};
}
