#pragma once
#include "MediaCleanup.h"
namespace catlive {
// Delete a dedicated project folder completely. Documents in shared/user
// folders retain a separately described, narrower file-inventory action.
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
        deletesDirectory = dedicatedDirectory();
        approved = inventory();
    }
    int remaining() const {
        return std::max(0, (int)std::ceil((readyAt - Time::getMillisecondCounterHiRes()) / 1000));
    }
    void validate() const {
        if (remaining() > 0)
            throw std::runtime_error("Aguarde 3 segundos antes de excluir o projeto.");
        if (!mediaCleanup::plainPath(root, document) || identity(document) != documentIdentity ||
            identity(root, false) != rootIdentity || (deletesDirectory && !dedicatedDirectory()))
            throw std::runtime_error("O projeto mudou. Abra a confirmação novamente.");
    }
    void remove() const {
        validate();
        if (deletesDirectory) {
            removeTree(root, document);
            if (root.exists()) throw std::runtime_error("Não foi possível excluir a pasta do projeto.");
            return;
        }
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
    bool deletesDirectory = false;
    const File &target() const { return deletesDirectory ? root : document; }

  private:
    File root;
    double readyAt;
    String documentIdentity, rootIdentity;
    std::map<String, String> approved;
    bool dedicatedDirectory() const {
        if (root == root.getParentDirectory()) return false;
        for (auto location : {File::userHomeDirectory, File::userDocumentsDirectory, File::userDesktopDirectory,
                             File::userMusicDirectory, File::userMoviesDirectory, File::userPicturesDirectory,
                             File::userApplicationDataDirectory, File::commonApplicationDataDirectory,
                             File::globalApplicationsDirectory, File::tempDirectory})
            if (root == File::getSpecialLocation(location)) return false;
        const auto home = File::getSpecialLocation(File::userHomeDirectory);
        if (root == home.getChildFile("Downloads") || root == home.getParentDirectory()) return false;
        // An ancestor junction must not turn an apparently local folder into
        // another location while the confirmation is open.
        for (auto parent = root; parent != parent.getParentDirectory(); parent = parent.getParentDirectory()) {
            const auto attributes = GetFileAttributesW(parent.getFullPathName().toWideCharPointer());
            if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
        }
        for (const auto &file : root.findChildFiles(File::findFiles, false, "*.jl"))
            if (file != document) return false;
        return true;
    }
    static void removeTree(const File &file, const File &document) {
        const auto attributes = GetFileAttributesW(file.getFullPathName().toWideCharPointer());
        if (attributes == INVALID_FILE_ATTRIBUTES) throw std::runtime_error("Não foi possível conferir a pasta do projeto.");
        const bool directory = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        // Directory junctions and symlinks are removed as links, never followed.
        if (directory && !(attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            const auto children = file.findChildFiles(File::findFilesAndDirectories, false);
            for (const auto &child : children) if (child != document) removeTree(child, document);
            // Keep the .jl available for a retry if Windows reports a locked
            // media/cache file. Never report successful deletion in that case.
            for (const auto &child : children) if (child == document) removeTree(child, document);
        }
        const bool removed = directory ? RemoveDirectoryW(file.getFullPathName().toWideCharPointer()) != 0
                                       : DeleteFileW(file.getFullPathName().toWideCharPointer()) != 0;
        if (!removed) throw std::runtime_error("Não foi possível excluir a pasta inteira. Feche os arquivos em uso e tente novamente.");
    }
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
