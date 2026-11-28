#pragma once
#include "ProjectCodec.h"
#include "CatDynamicsAssets.h"
namespace catlive::mediaCleanup {
using Paths = std::set<std::string>;
inline Paths references(const jaras::Project &project) {
    Paths result;
    for (const auto &song : project.songs)
        for (const auto &track : song.tracks) {
            if (track.audioFile)
                result.insert(track.audioFile->path);
            if (track.clickSound)
                result.insert(track.clickSound->path);
            for (const auto &clip : track.clips) {
                if (clip.audioFile) result.insert(clip.audioFile->path);
                if (clip.adjustedVideo) result.insert(clip.adjustedVideo->path);
            }
        }
    dynamicsAssets::collect(project, result);
    return result;
}
inline bool mediaPath(const String &path, bool includeArchives = false) {
    if ((!path.startsWithIgnoreCase("Stems/") && !path.startsWithIgnoreCase("Videos/") &&
         !(includeArchives && path.startsWithIgnoreCase("backups/Media/"))) ||
        path.containsChar('\\') || path.containsChar(':'))
        return false;
    const auto parts = StringArray::fromTokens(path, "/", "");
    if (parts.size() < 2)
        return false;
    for (const auto &part : parts)
        if (part.isEmpty() || part == "." || part == ".." || part.endsWithChar('.') ||
            part.endsWithChar(' '))
            return false;
    return true;
}
inline String key(const std::string &path) { return unicodeCase(text(path), false); }
inline void collectRaw(const var &raw, std::set<String> &paths) {
    if (raw.isString() && mediaPath(raw.toString(), true))
        paths.insert(unicodeCase(raw.toString(), false));
    else if (auto *array = raw.getArray())
        for (const auto &value : *array)
            collectRaw(value, paths);
    else if (auto *obj = raw.getDynamicObject()) {
        const auto &fields = obj->getProperties();
        for (int i = 0; i < fields.size(); ++i)
            collectRaw(fields.getValueAt(i), paths);
    }
}
inline File inventory(const ID &id, const File &document) {
    return document.getParentDirectory().getChildFile(".catlive-media-" + text(id) + ".json");
}
inline bool plainPath(const File &root, const File &file, bool allowMissing = false) {
    if (file != root && !file.isAChildOf(root))
        return false;
    auto part = file;
    for (;;) {
        const auto attributes = GetFileAttributesW(part.getFullPathName().toWideCharPointer());
        if (attributes == INVALID_FILE_ATTRIBUTES) {
            if (!allowMissing)
                return false;
        } else if (attributes & FILE_ATTRIBUTE_REPARSE_POINT)
            return false;
        if (part == root)
            return true;
        auto parent = part.getParentDirectory();
        if (parent == part)
            return false;
        part = parent;
    }
}
inline Paths remembered(const ID &id, const File &document) {
    auto file = inventory(id, document);
    if (!file.exists())
        return {};
    if (!plainPath(document.getParentDirectory(), file))
        throw std::runtime_error("Inventário de mídia fora da pasta do projeto.");
    var raw;
    if (JSON::parse(file.loadFileAsString(), raw).failed() || !raw.isArray())
        throw std::runtime_error(
            "O inventário de mídia está inválido. Nenhum arquivo foi excluído.");
    Paths result;
    for (const auto &entry : *raw.getArray()) {
        if (!entry.isString())
            throw std::runtime_error("Entrada inválida no inventário de mídia.");
        result.insert(utf8(entry.toString()));
    }
    return result;
}
inline void remember(const jaras::Project &project, const File &document, const Paths &known) {
    auto paths = remembered(project.id, document);
    paths.insert(known.begin(), known.end());
    const auto current = references(project);
    paths.insert(current.begin(), current.end());
    var data(Array<var>{});
    for (const auto &path : paths)
        data.append(text(path));
    const auto file = inventory(project.id, document);
    if (!plainPath(document.getParentDirectory(), file, true) ||
        !file.replaceWithText(JSON::toString(data)))
        throw std::runtime_error("Não foi possível salvar o inventário de mídia.");
}
struct CloseRemovalHandle {
    void operator()(void* handle) const noexcept { CloseHandle(handle); }
};
struct PendingRemoval {
    File file;
    std::unique_ptr<void, CloseRemovalHandle> handle;
    DWORD attributes;
};
inline std::runtime_error removalError(const File& root, const File& file, DWORD code) {
    auto message = String::fromUTF8("Não foi possível excluir ") + file.getRelativePathFrom(root) + ". ";
    if (code == ERROR_SHARING_VIOLATION || code == ERROR_LOCK_VIOLATION)
        message += String::fromUTF8("O arquivo está em uso. Feche a prévia ou o programa que o está usando e tente novamente.");
    else if (code == ERROR_ACCESS_DENIED || code == ERROR_WRITE_PROTECT)
        message += String::fromUTF8("O Windows negou a exclusão. Verifique a permissão de escrita e a proteção da unidade.");
    else
        message += String::fromUTF8("O Windows informou o erro ") + String(static_cast<int64>(code)) + ".";
    return std::runtime_error(utf8(message));
}
// Reserve deletion access before discarding snapshots. Keep each handle until
// commit so a short-lived reader cannot cause a partial cleanup midway through.
inline std::vector<PendingRemoval> prepareRemovals(const File& root, std::vector<File> files,
                                                    StringArray* inUse = nullptr) {
    std::vector<PendingRemoval> pending;
    pending.reserve(files.size());
    for (int attempt = 0; !files.empty(); ++attempt) {
        std::vector<File> retry;
        for (const auto& file : files) {
            if (!plainPath(root, file, true)) throw removalError(root, file, ERROR_ACCESS_DENIED);
            const HANDLE handle = CreateFileW(file.getFullPathName().toWideCharPointer(), DELETE | FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            if (handle == INVALID_HANDLE_VALUE) {
                const auto error = GetLastError();
                if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) continue;
                if (error == ERROR_SHARING_VIOLATION || error == ERROR_LOCK_VIOLATION) {
                    if (attempt < 4) { retry.push_back(file); continue; }
                    if (inUse) { inUse->add(file.getRelativePathFrom(root)); continue; }
                }
                throw removalError(root, file, error);
            }
            std::unique_ptr<void, CloseRemovalHandle> owner(handle);
            BY_HANDLE_FILE_INFORMATION info{};
            if (!GetFileInformationByHandle(handle, &info)) throw removalError(root, file, GetLastError());
            if (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))
                throw removalError(root, file, ERROR_ACCESS_DENIED);
            pending.push_back({file, std::move(owner), info.dwFileAttributes});
        }
        files = std::move(retry);
        if (!files.empty()) Thread::sleep(50 << attempt);
    }
    return pending;
}
inline void commitRemoval(const File& root, PendingRemoval& entry) {
    if (entry.attributes & FILE_ATTRIBUTE_READONLY) {
        // Imported files sometimes inherit this flag. Deleting the approved
        // link by handle leaves permissions on other hard links untouched.
        FILE_DISPOSITION_INFO_EX disposition{FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE};
        if (!SetFileInformationByHandle(entry.handle.get(), FileDispositionInfoEx, &disposition, sizeof(disposition)))
            throw removalError(root, entry.file, GetLastError());
    } else {
        FILE_DISPOSITION_INFO disposition{TRUE};
        if (!SetFileInformationByHandle(entry.handle.get(), FileDispositionInfo, &disposition, sizeof(disposition)))
            throw removalError(root, entry.file, GetLastError());
    }
    entry.handle.reset();
}
inline int removeDeleted(const jaras::Project &project, const var &raw, const File &document,
                         const Paths &known, const std::function<void(double)> &progress = {},
                         const std::set<String> &activeFiles = {}, StringArray* retained = nullptr,
                         bool* changedOnDisk = nullptr) {
    auto report = [&](double value) {
        if (progress)
            progress(value);
    };
    report(0);
    const auto root = document.getParentDirectory();
    if (!document.existsAsFile() || !plainPath(root, document))
        throw std::runtime_error("Salve o projeto em uma pasta local antes de limpar suas mídias.");
    Paths owned = remembered(project.id, document);
    owned.insert(known.begin(), known.end());
    std::set<String> protectedPaths;
    collectRaw(raw, protectedPaths);
    for (const auto &other : root.findChildFiles(File::findFiles, false, "*.jl"))
        if (other != document) {
            if (!plainPath(root, other))
                throw std::runtime_error("Não foi possível verificar outro projeto nesta pasta.");
            const auto data = ProjectCodec::read(other);
            ProjectCodec::decode(data);
            collectRaw(data, protectedPaths);
        }
    std::vector<File> backups;
    const auto backupRoot = root.getChildFile("backups");
    if (backupRoot.exists()) {
        if (!plainPath(root, backupRoot))
            throw std::runtime_error("A pasta de backups contém um vínculo externo.");
        for (const auto &file : backupRoot.findChildFiles(File::findFiles, false, "*.bkjl")) {
            if (!plainPath(root, file))
                throw std::runtime_error("Backup fora da pasta do projeto.");
            const auto data = ProjectCodec::read(file);
            const auto backup = ProjectCodec::decode(data);
            if (backup.id == project.id) {
                backups.push_back(file);
                const auto paths = references(backup);
                owned.insert(paths.begin(), paths.end());
            } else {
                collectRaw(data, protectedPaths);
            }
        }
    }
    report(.2);
    std::vector<File> candidates;
    std::set<String> seen;
    for (const auto &path : owned) {
        const auto normalized = key(path);
        if (!mediaPath(text(path), true) || protectedPaths.count(normalized) ||
            !seen.insert(normalized).second)
            continue;
        auto source = root.getChildFile(text(path));
        if (activeFiles.count(unicodeCase(source.getFullPathName(), false))) continue;
        if (!source.existsAsFile() || !plainPath(root, source))
            continue;
        candidates.push_back(source);
    }
    // Retain archive ownership if a later deletion fails and cleanup is retried.
    remember(project, document, owned);
    StringArray inUse;
    auto media = prepareRemovals(root, std::move(candidates), &inUse);
    if (retained) *retained = inUse;
    // When every obsolete source is in use leave its recovery snapshots available
    // too. The inventory also retains skipped paths for the user's next cleanup.
    if (media.empty() && !inUse.isEmpty()) { report(1); return 0; }
    auto snapshots = prepareRemovals(root, backups);
    for (size_t index = 0; index < snapshots.size(); ++index) {
        commitRemoval(root, snapshots[index]);
        if (changedOnDisk) *changedOnDisk = true;
        report(.2 + .3 * (index + 1) / snapshots.size());
    }
    report(.5);
    int removed = 0;
    for (auto& entry : media) {
        commitRemoval(root, entry);
        if (changedOnDisk) *changedOnDisk = true;
        ++removed;
        report(.5 + .49 * removed / media.size());
    }
    report(1);
    return removed;
}
} // namespace catlive::mediaCleanup
