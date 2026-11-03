#pragma once
#include "ProjectCodec.h"
#include "MediaCleanup.h"
#include "InstrumentAssets.h"
#include "Localization.h"
#include <regex>

namespace catlive::projectBackups {
inline void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(utf8(localization::translate(message)));
}
inline File mediaDirectory(const File &file) {
    const auto parent = file.getParentDirectory();
    return file.hasFileExtension("bkjl") && parent.getFileName().equalsIgnoreCase("backups")
        ? parent.getParentDirectory() : parent;
}
inline bool belongsTo(const File &backup, const File &document) {
    if (!backup.hasFileExtension("bkjl") || ProjectCodec::isMacMetadata(backup)) return false;
    const auto base = document.getFileNameWithoutExtension();
    const auto name = backup.getFileNameWithoutExtension();
    if (name.startsWith(base + "--")) {
        const auto suffix = name.substring(base.length() + 2);
        return suffix.length() == 20 && suffix.containsOnly("0123456789");
    }
    if (!name.startsWith(base + " - ")) return false;
    static const std::regex datedOrNumbered(R"((\d{2}-\d{2}-\d{4} - \d{2}-\d{2}( - \d+)?|\d{3,}))");
    return std::regex_match(utf8(name.substring(base.length() + 3)), datedOrNumbered);
}
inline Time date(const File &file) {
    const auto name = file.getFileNameWithoutExtension();
    if (name.length() >= 22 && name.dropLastCharacters(20).endsWith("--")) {
        const auto stamp = name.getLastCharacters(20);
        if (stamp.containsOnly("0123456789")) return Time(stamp.getLargeIntValue() / 1000);
    }
    const auto created = file.getCreationTime();
    return created.toMilliseconds() != 0 ? created : file.getLastModificationTime();
}
inline std::vector<File> files(const File &document) {
    std::vector<File> result;
    const auto root = document.getParentDirectory(), folder = root.getChildFile("backups");
    if (!folder.exists()) return result;
    require(folder.isDirectory() && mediaCleanup::plainPath(root, folder), "Could not access the project backup folder.");
    for (const auto &file : folder.findChildFiles(File::findFiles, false, "*.bkjl"))
        if (belongsTo(file, document)) {
            require(mediaCleanup::plainPath(root, file), "Could not access the project backup folder.");
            result.push_back(file);
        }
    std::sort(result.begin(), result.end(), [](const File &a, const File &b) {
        const auto first = date(a), second = date(b);
        return first == second ? a.getFileName().compareNatural(b.getFileName()) < 0 : first < second;
    });
    return result;
}
// Reserve the name exclusively: two saves in the same minute never overwrite
// a snapshot. Reuse the document's encrypted bytes, without encoding it twice.
inline File create(const File &document, const MemoryBlock &bytes) {
    const auto root = document.getParentDirectory(), folder = root.getChildFile("backups");
    require(folder.createDirectory().wasOk() && mediaCleanup::plainPath(root, folder),
            "Could not create the project backup folder.");
    const auto base = document.getFileNameWithoutExtension() + " - " + Time::getCurrentTime().formatted("%d-%m-%Y - %H-%M");
    int index = 1;
    for (const auto &existing : folder.findChildFiles(File::findFiles, false, "*.bkjl")) {
        const auto name = existing.getFileNameWithoutExtension();
        if (name == base) index = std::max(index, 2);
        else if (name.startsWith(base + " - ")) {
            const auto suffix = name.substring(base.length() + 3);
            if (suffix.isNotEmpty() && suffix.length() < 9 && suffix.containsOnly("0123456789"))
                index = std::max(index, suffix.getIntValue() + 1);
        }
    }
    for (; ; ++index) {
        const auto file = folder.getChildFile(base + (index == 1 ? String() : " - " + String(index)) + ".bkjl");
        HANDLE handle = CreateFileW(file.getFullPathName().toWideCharPointer(), GENERIC_WRITE, FILE_SHARE_READ,
                                    nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (handle == INVALID_HANDLE_VALUE) {
            const auto error = GetLastError();
            if (error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS) continue;
            require(false, "Could not create the project backup. The project was not saved.");
        }
        DWORD written = 0;
        const bool ok = bytes.getSize() <= MAXDWORD &&
            WriteFile(handle, bytes.getData(), static_cast<DWORD>(bytes.getSize()), &written, nullptr) &&
            written == bytes.getSize() && FlushFileBuffers(handle);
        CloseHandle(handle);
        if (!ok) {
            file.deleteFile();
            require(false, "Could not write the project backup. The project was not saved.");
        }
        return file;
    }
}
inline void prune(const std::vector<File> &previous) {
    const size_t removeCount = previous.size() > 9 ? previous.size() - 9 : 0;
    for (size_t index = 0; index < removeCount; ++index)
        require(previous[index].deleteFile(), "The project was saved, but an old backup could not be removed.");
}
// Opening a backup creates an independent recovered project. Subsequent Save
// must never overwrite the original document, its history or its media.
inline File restore(const File &backup, const jaras::Project &project) {
    const auto root = mediaDirectory(backup);
    const auto base = backup.getFileNameWithoutExtension() + "-Recovered";
    const auto folder = root.getParentDirectory().getNonexistentChildFile(base, "", false);
    require(CreateDirectoryW(folder.getFullPathName().toWideCharPointer(), nullptr) != 0,
            "Could not create the recovered project folder.");
    try {
        auto paths = mediaCleanup::references(project);
        for (const auto &id : instrumentAssets::identities(project)) paths.insert(utf8("Instruments/" + id + ".sf2"));
        for (const auto &path : paths) {
            const auto source = ProjectCodec::resolveMedia(root, path);
            const auto target = ProjectCodec::resolveMedia(folder, path, false);
            if (!source.existsAsFile()) continue;
            require(target.getParentDirectory().createDirectory().wasOk() && source.copyFileTo(target),
                    "Could not copy media for the recovered project.");
        }
        const auto target = folder.getChildFile(base + ".jl");
        require(backup.copyFileTo(target), "Could not restore the project backup.");
        return target;
    } catch (...) {
        folder.deleteRecursively();
        throw;
    }
}
} // namespace catlive::projectBackups
