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
            for (const auto &clip : track.clips)
                if (clip.audioFile)
                    result.insert(clip.audioFile->path);
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
inline int removeDeleted(const jaras::Project &project, const var &raw, const File &document,
                         const Paths &known, const std::function<void(double)> &progress = {},
                         const std::set<String> &activeFiles = {}) {
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
    // All backups have been validated. Delete only this project's snapshots
    // before removing sources, so no surviving own backup points at deleted media.
    for (size_t index = 0; index < backups.size(); ++index) {
        if (!plainPath(root, backups[index]) || !backups[index].deleteFile())
            throw std::runtime_error("Não foi possível excluir um backup antigo. As mídias foram mantidas.");
        report(.2 + .3 * (index + 1) / backups.size());
    }
    report(.5);
    int removed = 0;
    for (const auto &source : candidates) {
        if (!plainPath(root, source) || !source.deleteFile())
            throw std::runtime_error(
                "Não foi possível excluir uma mídia. A limpeza não foi concluída.");
        ++removed;
        report(.5 + .49 * removed / candidates.size());
    }
    report(1);
    return removed;
}
} // namespace catlive::mediaCleanup
