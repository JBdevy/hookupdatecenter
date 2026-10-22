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
inline bool mediaPath(const String &path) {
    if ((!path.startsWithIgnoreCase("Stems/") && !path.startsWithIgnoreCase("Videos/")) ||
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
    if (raw.isString() && mediaPath(raw.toString()))
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
inline bool replacePaths(var &raw, const std::map<String, String> &replacements) {
    bool changed = false;
    if (raw.isString()) {
        auto it = replacements.find(unicodeCase(raw.toString(), false));
        if (it != replacements.end()) {
            raw = it->second;
            changed = true;
        }
    } else if (auto *array = raw.getArray())
        for (auto &value : *array)
            changed = replacePaths(value, replacements) || changed;
    else if (auto *obj = raw.getDynamicObject()) {
        auto &fields = obj->getProperties();
        for (int i = 0; i < fields.size(); ++i) {
            auto name = fields.getName(i);
            auto value = fields.getValueAt(i);
            if (replacePaths(value, replacements)) {
                obj->setProperty(name, value);
                changed = true;
            }
        }
    }
    return changed;
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
    struct Backup {
        File file;
        var raw;
        Time modified;
    };
    std::vector<Backup> backups;
    std::set<String> backupPaths;
    const auto backupRoot = root.getChildFile("backups");
    if (backupRoot.exists()) {
        if (!plainPath(root, backupRoot))
            throw std::runtime_error("A pasta de backups contém um vínculo externo.");
        for (const auto &file : backupRoot.findChildFiles(File::findFiles, false, "*.bkjl")) {
            if (!plainPath(root, file))
                throw std::runtime_error("Backup fora da pasta do projeto.");
            const auto data = ProjectCodec::read(file);
            ProjectCodec::decode(data);
            collectRaw(data, backupPaths);
            backups.push_back({file, data, file.getLastModificationTime()});
        }
    }
    report(.2);
    std::map<String, String> replacements;
    std::vector<File> candidates;
    std::set<String> seen;
    for (const auto &path : owned) {
        const auto normalized = key(path);
        if (!mediaPath(text(path)) || protectedPaths.count(normalized) ||
            !seen.insert(normalized).second)
            continue;
        auto source = root.getChildFile(text(path));
        if (activeFiles.count(unicodeCase(source.getFullPathName(), false))) continue;
        if (!source.existsAsFile() || !plainPath(root, source))
            continue;
        if (backupPaths.count(normalized)) {
            const auto relative = "backups/Media/" + text(uuid()) + "/" + source.getFileName();
            const auto archived = root.getChildFile(relative);
            if (!plainPath(root, archived, true) ||
                archived.getParentDirectory().createDirectory().failed() ||
                !plainPath(root, archived.getParentDirectory()))
                throw std::runtime_error("Não foi possível preservar as mídias dos backups.");
            if (!CreateHardLinkW(archived.getFullPathName().toWideCharPointer(),
                                 source.getFullPathName().toWideCharPointer(), nullptr) &&
                !source.copyFileTo(archived))
                throw std::runtime_error("Não foi possível copiar uma mídia de recuperação.");
            FileInputStream before(source), after(archived);
            if (before.failedToOpen() || after.failedToOpen() || SHA256(before) != SHA256(after))
                throw std::runtime_error(
                    "A cópia da mídia de recuperação não passou na verificação.");
            replacements.emplace(normalized, relative);
        }
        candidates.push_back(source);
    }
    report(.55);
    // Every recovery document must commit before the first source is removed.
    for (auto &backup : backups)
        if (replacePaths(backup.raw, replacements)) {
            ProjectCodec::decode(backup.raw);
            ProjectCodec::write(backup.file, backup.raw);
            backup.file.setLastModificationTime(backup.modified);
        }
    report(.75);
    int removed = 0;
    for (const auto &source : candidates) {
        if (!plainPath(root, source) || !source.deleteFile())
            throw std::runtime_error(
                "Não foi possível excluir uma mídia. Os backups foram preservados.");
        ++removed;
        report(.75 + .24 * removed / candidates.size());
    }
    report(1);
    return removed;
}
} // namespace catlive::mediaCleanup
