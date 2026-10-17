#pragma once
#include "MediaCleanup.h"
namespace catlive {
// Explicit file inventory, like ProjectFolderDeletion.swift. Never remove a
// project container or media shared by sibling documents/recovery snapshots.
class ProjectDeletion {
  public:
    explicit ProjectDeletion(File value)
        : document(value), root(value.getParentDirectory()),
          readyAt(Time::getMillisecondCounterHiRes() + 3000) {
        if (!document.hasFileExtension("jl") || !document.existsAsFile() ||
            !mediaCleanup::plainPath(root, document))
            throw std::runtime_error("Escolha um projeto CatLive local, sem links simbólicos.");
        documentIdentity = identity(document);
        rootIdentity = identity(root, false);
        approved = inventory();
    }
    int remaining() const {
        return std::max(0, (int)std::ceil((readyAt - Time::getMillisecondCounterHiRes()) / 1000));
    }
    void validate() const {
        if (remaining() > 0)
            throw std::runtime_error("Aguarde 3 segundos antes de excluir o projeto.");
        if (!mediaCleanup::plainPath(root, document) || identity(document) != documentIdentity ||
            identity(root, false) != rootIdentity)
            throw std::runtime_error("O projeto mudou. Abra a confirmação novamente.");
    }
    void remove() const {
        validate();
        const auto current = inventory();
        for (const auto &[path, stamp] : approved) {
            const auto found = current.find(path);
            File file(path);
            if (found != current.end() && found->second == stamp &&
                mediaCleanup::plainPath(root, file) && identity(file) == stamp && !file.deleteFile())
                throw std::runtime_error("Não foi possível excluir uma mídia do projeto.");
            if (!file.exists()) {
                auto parent = file.getParentDirectory();
                while (parent != root && parent.isAChildOf(root) &&
                       mediaCleanup::plainPath(root, parent)) {
                    if (!RemoveDirectoryW(parent.getFullPathName().toWideCharPointer()))
                        break;
                    parent = parent.getParentDirectory();
                }
            }
        }
        if (!document.deleteFile())
            throw std::runtime_error("Não foi possível excluir o projeto.");
    }
    File document;

  private:
    File root;
    double readyAt;
    String documentIdentity, rootIdentity;
    std::map<String, String> approved;
    // Recovery media belongs to the deleted project too. Timeline cleanup uses
    // a narrower inventory because it must retain those recovery files.
    static bool ownedPath(const String &path) {
        if (mediaCleanup::mediaPath(path))
            return true;
        return path.startsWithIgnoreCase("backups/Media/") &&
               mediaCleanup::mediaPath("Stems/" + path.substring(14));
    }
    static void collectReferences(const var &raw, std::set<String> &paths) {
        if (raw.isString() && ownedPath(raw.toString()))
            paths.insert(unicodeCase(raw.toString(), false));
        else if (auto *array = raw.getArray())
            for (const auto &value : *array)
                collectReferences(value, paths);
        else if (auto *obj = raw.getDynamicObject()) {
            const auto &fields = obj->getProperties();
            for (int i = 0; i < fields.size(); ++i)
                collectReferences(fields.getValueAt(i), paths);
        }
    }
    static String identity(const File &file, bool contents = true) {
        const auto handle = CreateFileW(file.getFullPathName().toWideCharPointer(), FILE_READ_ATTRIBUTES,
                                        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                                        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
        if (handle == INVALID_HANDLE_VALUE)
            throw std::runtime_error("Não foi possível conferir o arquivo do projeto.");
        BY_HANDLE_FILE_INFORMATION info{};
        const bool ok = GetFileInformationByHandle(handle, &info) != 0;
        CloseHandle(handle);
        if (!ok)
            throw std::runtime_error("Não foi possível conferir a identidade do arquivo.");
        auto result = String(info.dwVolumeSerialNumber) + ":" + String(info.nFileIndexHigh) + ":" +
                      String(info.nFileIndexLow);
        if (contents)
            result += ":" + String(info.nFileSizeHigh) + ":" + String(info.nFileSizeLow) + ":" +
                      String(info.ftLastWriteTime.dwHighDateTime) + ":" +
                      String(info.ftLastWriteTime.dwLowDateTime);
        return result;
    }
    std::map<String, String> inventory() const {
        const auto raw = ProjectCodec::read(document);
        const auto project = ProjectCodec::decode(raw);
        std::set<String> owned, protectedPaths;
        collectReferences(raw, owned);
        for (const auto &path : mediaCleanup::remembered(project.id, document))
            if (ownedPath(text(path)))
                owned.insert(mediaCleanup::key(path));
        bool uncertain = false, sharedIdentity = false;
        std::vector<File> candidates;
        const auto manifest = mediaCleanup::inventory(project.id, document);
        if (manifest.existsAsFile())
            candidates.push_back(manifest);
        for (const auto &sibling : root.findChildFiles(File::findFiles, false, "*.jl"))
            if (sibling != document) {
                try {
                    if (!mediaCleanup::plainPath(root, sibling))
                        throw std::runtime_error("link");
                    auto data = ProjectCodec::read(sibling);
                    const auto other = ProjectCodec::decode(data);
                    sharedIdentity |= other.id == project.id;
                    collectReferences(data, protectedPaths);
                    for (const auto &path : mediaCleanup::remembered(other.id, sibling))
                        if (ownedPath(text(path)))
                            protectedPaths.insert(mediaCleanup::key(path));
                } catch (...) {
                    uncertain = true;
                }
            }
        const auto backups = root.getChildFile("backups");
        if (backups.exists()) {
            if (!mediaCleanup::plainPath(root, backups))
                uncertain = true;
            else
                for (const auto &file : backups.findChildFiles(File::findFiles, false, "*.bkjl"))
                    try {
                        if (!mediaCleanup::plainPath(root, file))
                            throw std::runtime_error("link");
                        const auto data = ProjectCodec::read(file);
                        const auto saved = ProjectCodec::decode(data);
                        if (saved.id == project.id && !sharedIdentity) {
                            candidates.push_back(file);
                            collectReferences(data, owned);
                        } else
                            collectReferences(data, protectedPaths);
                    } catch (...) {
                        uncertain = true;
                    }
        }
        if (uncertain)
            candidates.clear();
        else
            for (const auto &path : owned)
                if (!protectedPaths.count(path)) {
                    candidates.push_back(root.getChildFile(path));
                    if (path.startsWithIgnoreCase("Stems/"))
                        candidates.push_back(
                            root.getChildFile("Stems/WF/" + path.substring(6) + ".waveform"));
                }
        std::map<String, String> result;
        for (const auto &file : candidates)
            if (!(sharedIdentity && file == manifest) && file.existsAsFile() &&
                mediaCleanup::plainPath(root, file))
                result.emplace(file.getFullPathName(), identity(file));
        return result;
    }
};
} // namespace catlive
