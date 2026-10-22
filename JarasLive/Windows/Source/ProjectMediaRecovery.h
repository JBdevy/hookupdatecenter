#pragma once
#include "ProjectCodec.h"
#include "CatDynamicsAssets.h"
namespace catlive::projectMediaRecovery {
inline StringArray missingPaths(const jaras::Project &project, const File &directory) {
    std::set<std::string> references;
    for (const auto &song : project.songs) for (const auto &track : song.tracks) {
        if (track.audioFile) references.insert(track.audioFile->path);
        if (track.clickSound) references.insert(track.clickSound->path);
        for (const auto &clip : track.clips)
            if (clip.audioFile) references.insert(clip.audioFile->path);
    }
    dynamicsAssets::collect(project, references);
    StringArray missing;
    for (const auto &path : references)
        if (!ProjectCodec::resolveMedia(directory, path).existsAsFile()) missing.add(text(path));
    missing.sortNatural();
    return missing;
}
struct Result { StringArray recovered, remaining, errors; };
// Preserve the document and item identities. Copy recovered media into their
// original relative paths, so reopening the project asks only for unresolved files.
inline Result restore(const StringArray &missing, const File &directory, const File &folder,
                      const std::atomic<bool> &cancelled) {
    Result result;
    std::map<String, Array<File>> candidates;
    for (const auto &entry : RangedDirectoryIterator(folder, true, "*", File::findFiles,
                                                    File::FollowSymlinks::no)) {
        if (cancelled.load()) return result;
        const auto file = entry.getFile();
        candidates[file.getFileName().toLowerCase()].add(file);
    }
    for (const auto &path : missing) {
        if (cancelled.load()) return result;
        const auto target = ProjectCodec::resolveMedia(directory, utf8(path), false);
        if (target.existsAsFile()) { result.recovered.add(path); continue; }
        const auto normalized = path.replaceCharacter('\\', '/');
        const auto &matches = candidates[normalized.fromLastOccurrenceOf("/", false, false).toLowerCase()];
        Array<File> exact;
        for (const auto &candidate : matches)
            if (candidate.getFullPathName().replaceCharacter('\\', '/').endsWithIgnoreCase("/" + normalized))
                exact.add(candidate);
        const auto source = exact.size() == 1 ? exact[0] : matches.size() == 1 ? matches[0] : File();
        if (source == File()) { result.remaining.add(path); continue; }
        if (!target.isAChildOf(directory)) {
            result.errors.add(path + ": invalid project media path.");
            result.remaining.add(path); continue;
        }
        TemporaryFile temporary(target);
        if (target.getParentDirectory().createDirectory().failed() ||
            !source.copyFileTo(temporary.getFile()) ||
            !temporary.overwriteTargetFileWithTemporary()) {
            result.errors.add(path + ": " + String::fromUTF8("Não foi possível recuperar o arquivo."));
            result.remaining.add(path);
        } else result.recovered.add(path);
    }
    return result;
}
} // namespace catlive::projectMediaRecovery
