#pragma once
#include "MediaCleanup.h"
#include <filesystem>

namespace catlive {
inline String recentProjectStorageDescription(int64 bytes) {
    double value = (double)bytes;
    const char *units[] = {"B", "KB", "MB", "GB", "TB"};
    int unit = 0;
    while (value >= 1000 && unit < 4) { value /= 1000; ++unit; }
    return String(value, unit == 0 ? 0 : 2) + " " + units[unit];
}
inline int64 recentProjectStorageBytes(const File &document) {
    const auto project = ProjectCodec::decode(ProjectCodec::read(document));
    std::map<String, File> files;
    const auto add = [&](const File &file) {
        const auto canonical = std::filesystem::weakly_canonical(
            std::filesystem::path(file.getFullPathName().toWideCharPointer()));
        files.emplace(unicodeCase(String(canonical.wstring().c_str()), false), file);
    };
    add(document);
    for (const auto &path : mediaCleanup::references(project))
        add(ProjectCodec::resolveMedia(document.getParentDirectory(), path, false));
    int64 total = 0;
    for (const auto &[key, file] : files) {
        const auto path = std::filesystem::path(file.getFullPathName().toWideCharPointer());
        if (std::filesystem::is_regular_file(path)) total += (int64)std::filesystem::file_size(path);
    }
    return total;
}
}
