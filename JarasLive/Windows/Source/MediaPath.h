#pragma once
#include "Common.h"
namespace catlive {
inline String canonicalMediaName(const String& value) {
    const int size = NormalizeString(NormalizationC, value.toWideCharPointer(), -1, nullptr, 0);
    if (size <= 0) return value;
    std::vector<wchar_t> normalized((size_t)size);
    if (NormalizeString(NormalizationC, value.toWideCharPointer(), -1, normalized.data(), size) <= 0)
        return value;
    return String(normalized.data());
}
// APFS accepts composed/decomposed accents as the same name; NTFS does not.
// Preserve exact matches and only resolve an unambiguous canonical equivalent.
inline File existingMediaPath(const File& requested, int depth = 0) {
    if (requested.exists() || depth >= 64) return requested;
    const auto parent = requested.getParentDirectory();
    if (parent == requested) return requested;
    const auto folder = existingMediaPath(parent, depth + 1);
    if (!folder.isDirectory()) return requested;
    auto exact = folder.getChildFile(requested.getFileName());
    if (exact.exists()) return exact;
    const auto wanted = canonicalMediaName(requested.getFileName());
    File match;
    for (const auto& entry : folder.findChildFiles(File::findFilesAndDirectories, false)) {
        if (!canonicalMediaName(entry.getFileName()).equalsIgnoreCase(wanted)) continue;
        if (match != File()) return requested;
        match = entry;
    }
    return match == File() ? requested : match;
}
}
