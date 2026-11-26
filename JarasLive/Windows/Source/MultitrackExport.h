#pragma once
#include "AudioExport.h"
#include "AudioSeparation.h"
#include "TimelineRegionLabels.h"
#include "JLLyrics.h"
#include "RegionEditing.h"
#include "ClipTempo.h"
#include "MultitrackRegionData.h"
#include "../../Core/Transport/PlaybackScope.hpp"
#include <filesystem>

namespace catlive {
struct MultitrackExportProject {
    ID tab;
    jaras::Project project;
    jaras::Song song;
    File mediaDirectory;
    File destination;
    std::set<ID> selection;
    bool ignoreMutedTracks = false;
    bool ignoreMutedItems = false;
};

namespace multitrackExport {
inline bool rootRegion(const jaras::Part &part) { return !part.parentRegionID; }
inline String safeName(const String &raw) {
    auto label = File::createLegalFileName(raw).trim().trimCharactersAtEnd(". ").trimCharactersAtStart(".").substring(0, 165);
    const auto device = label.upToFirstOccurrenceOf(".", false, false).toUpperCase();
    const StringArray reserved{"CON","PRN","AUX","NUL","COM1","COM2","COM3","COM4","COM5","COM6","COM7","COM8","COM9",
        "LPT1","LPT2","LPT3","LPT4","LPT5","LPT6","LPT7","LPT8","LPT9"};
    if (reserved.contains(device)) label = device + "_" + label.substring(device.length());
    return label.isEmpty() ? String("Export") : label;
}
inline File createFolder(const File &root, const String &label) {
    const auto name = safeName(label);
    for (int ordinal = 1;; ++ordinal) {
        const auto candidate = root.getChildFile(ordinal == 1 ? name : name + " - " + String(ordinal));
        std::error_code error;
        if (std::filesystem::create_directory(std::filesystem::path(candidate.getFullPathName().toWideCharPointer()), error))
            return candidate;
        if (!candidate.exists())
            throw std::runtime_error("Could not create export folder: " + utf8(candidate.getFullPathName()));
    }
}
inline void run(const std::vector<MultitrackExportProject> &projects, std::atomic<bool> &cancel,
                const std::function<void(double,String)> &progress) {
    int count = 0, completed = 0;
    for (const auto &config : projects)
        for (const auto &part : config.song.parts)
            if (rootRegion(part) && config.selection.count(part.id))
                count += std::max<int>(1, (int)std::count_if(config.song.parts.begin(), config.song.parts.end(),
                    [&](const auto &child) { return child.parentRegionID == part.id; }));
    Array<File> owned;
    auto check = [&] { if (cancel.load()) throw std::runtime_error("Export canceled."); };
    try {
        for (const auto &config : projects) {
            if (config.selection.empty()) continue;
            check();
            if (!config.destination.isDirectory()) throw std::runtime_error("The export destination is unavailable.");
            auto project = config.project;
            project.masterMute = false; project.masterSolo = false;
            auto song = config.song;
            for (auto &track : song.tracks) {
                track.solo = false;
                if (!config.ignoreMutedTracks) track.mute = false;
                if (!config.ignoreMutedItems) for (auto &clip : track.clips) clip.muted = false;
            }
            std::vector<const jaras::Part *> regions;
            for (const auto &part : song.parts)
                if (rootRegion(part) && config.selection.count(part.id)) regions.push_back(&part);
            std::stable_sort(regions.begin(), regions.end(), [](auto *a, auto *b) { return a->startTime < b->startTime; });
            for (const auto *root : regions) {
                check();
                const auto parentFolder = createFolder(config.destination, timelineRegionLabels::displayName(*root));
                owned.add(parentFolder);
                std::vector<const jaras::Part *> children;
                for (const auto &part : song.parts)
                    if (part.parentRegionID == root->id) children.push_back(&part);
                std::stable_sort(children.begin(), children.end(), [&](auto *a, auto *b) {
                    return jaras::playbackRegionStart(song, *a) < jaras::playbackRegionStart(song, *b);
                });
                const bool fullItems = !children.empty();
                if (!fullItems) children.push_back(root);
                Array<var> entries;
                std::map<ID, ID> owners;
                if (fullItems) for (const auto &track : song.tracks) for (const auto &clip : track.clips)
                    if (const auto owner = jaras::dominantUnifiedOwner(song, *root, clip.startTime, clip.startTime + clip.duration, clip.regionOwnerID))
                        owners.emplace(clip.id, *owner);
                for (const auto *part : children) {
                    check();
                    const auto folder = fullItems ? createFolder(parentFolder, timelineRegionLabels::displayName(*part)) : parentFolder;
                    const auto status = String(completed + 1) + "/" + String(count) + " | " + text(project.name) + " | " + timelineRegionLabels::displayName(*part);
                    progress(double(completed) / std::max(1, count), status);
                    std::map<String, ExportRequest> requests;
                    std::map<String, std::set<ID>> sourceItems;
                    std::set<ID> mixedTracks;
                    auto jobsFor = [&](const String &format) -> std::vector<ExportJob> & {
                        auto &request = requests[format];
                        request.directory = folder;
                        request.encodings[0].format = format.toUpperCase();
                        request.encodings[0].bitrate = 320;
                        return request.jobs;
                    };
                    StringArray names;
                    auto allocate = [&](String base, const String &extension) {
                        base = safeName(base);
                        auto name = base + extension;
                        for (int suffix = 2; names.contains(name, true); ++suffix) name = base + " - " + String(suffix) + extension;
                        names.add(name);
                        return name;
                    };
                    std::map<ID, jaras::Track> storedTracks;
                    std::map<File, String> copiedAssets;
                    std::vector<multitrackData::RenderedStem> renderedStems;
                    StringArray lyricFiles;
                    bool printedRateChange = false;
                    jaras::TempoEditMap::PlaybackRates playbackRates(song);
                    for (size_t row = 0; row < song.tracks.size(); ++row) {
                        const auto &track = song.tracks[row];
                        if (track.mute) continue;
                        auto stored = config.song.tracks[row];
                        stored.clips.clear();
                        std::vector<jaras::AudioClip> lyrics;
                        const int prompter = track.role.id == "teleprompt" ? 1 : track.role.id == "teleprompt2" ? 2 : 0;
                        std::vector<const jaras::AudioClip *> audioItems;
                        for (size_t index = 0; index < track.clips.size(); ++index) {
                            const auto &clip = track.clips[index];
                            const double end = clip.startTime + clip.duration;
                            const auto owner = owners.find(clip.id);
                            if (clip.muted || (fullItems
                                ? owner == owners.end() || owner->second != part->id
                                : clip.startTime >= part->endTime || end <= part->startTime)) continue;
                            auto item = config.song.tracks[row].clips[index];
                            if (prompter && item.text && !item.audioFile) {
                                lyrics.push_back(item);
                                stored.clips.push_back(std::move(item));
                            } else if (multitrackData::isMedia(clip)) {
                                check();
                                const auto source = ProjectCodec::resolveMedia(config.mediaDirectory, clip.audioFile->path);
                                auto copied = copiedAssets.find(source);
                                if (copied == copiedAssets.end()) {
                                    const auto filename = allocate(source.getFileNameWithoutExtension(), source.getFileExtension());
                                    if (!source.copyFileTo(folder.getChildFile(filename)))
                                        throw std::runtime_error("Could not copy media: " + utf8(source.getFileName()));
                                    copied = copiedAssets.emplace(source, filename).first;
                                }
                                item.audioFile = jaras::AudioFile{utf8("Videos/" + copied->second), {}};
                                item.waveform.clear(); item.waveformChannels.clear();
                                stored.clips.push_back(std::move(item));
                            } else if (audioSeparation::eligible(track, clip)) {
                                audioItems.push_back(&clip);
                            }
                        }
                        const bool render = !audioItems.empty() && jaras::fixedTrackName(track.role).empty();
                        if (render) {
                            std::sort(audioItems.begin(), audioItems.end(), [](const auto *a, const auto *b) {
                                return a->startTime == b->startTime ? a->id < b->id : a->startTime < b->startTime;
                            });
                            auto formatFor = [&](const jaras::AudioClip &clip) -> String {
                                const auto &source = clip.audioFile ? clip.audioFile : track.audioFile;
                                const auto ext = text(source->path).fromLastOccurrenceOf(".", false, false).toLowerCase();
                                if (ext == "wav" || ext == "wave") return "wav";
                                if (ext == "aif" || ext == "aiff" || ext == "aifc") return "aiff";
                                return "mp3";
                            };
                            auto stemItem = [&](const jaras::AudioClip &clip) -> multitrackData::RenderedStem::Item {
                                const auto rate = playbackRates.playbackRate(clip, clip.startTime);
                                const auto &points = playbackRates.points(clip);
                                if (std::abs(clip.playbackRate - 1.) > 1e-7 || std::abs(rate - 1.) > 1e-7 ||
                                    std::any_of(points.begin(), points.end(), [&](const auto &point) {
                                        return point.time > clip.startTime && point.time < clip.startTime + clip.duration &&
                                            std::abs(playbackRates.playbackRate(clip, point.time) - 1.) > 1e-7;
                                    })) printedRateChange = true;
                                return {clip.startTime - part->startTime, clip.duration, rate, {}};
                            };
                            const auto label = safeName(text(track.name) + String::fromUTF8(" – ") + timelineRegionLabels::displayName(*part));
                            if (fullItems) {
                                for (size_t i = 0; i < audioItems.size(); ++i) {
                                    const auto *clip = audioItems[i];
                                    const auto format = formatFor(*clip);
                                    const auto filename = allocate(label.substring(0, 150) + String::formatted(" %03d", int(i + 1)), "." + format);
                                    jobsFor(format).push_back({filename, clip->startTime, clip->startTime + clip->duration, track.id, clip->id});
                                    renderedStems.push_back({filename, track.id, {stemItem(*clip)}});
                                }
                            } else {
                                std::map<String, std::vector<const jaras::AudioClip *>> formats;
                                for (const auto *clip : audioItems) formats[formatFor(*clip)].push_back(clip);
                                if (formats.size() > 1) mixedTracks.insert(track.id);
                                for (const auto &[format, matching] : formats) {
                                    auto &ids = sourceItems[format];
                                    std::vector<multitrackData::RenderedStem::Item> items;
                                    for (const auto *clip : matching) { ids.insert(clip->id); items.push_back(stemItem(*clip)); }
                                    const auto filename = allocate(label, "." + format);
                                    jobsFor(format).push_back({filename, part->startTime, part->endTime, track.id, {}});
                                    renderedStems.push_back({filename, track.id, std::move(items)});
                                }
                            }
                        }
                        if (!lyrics.empty()) {
                            const auto filename = allocate(timelineRegionLabels::displayName(*part), ".jllyrics");
                            jlLyrics::write(folder.getChildFile(filename), prompter, lyrics, part->startTime);
                            if (folder.getChildFile(filename).existsAsFile()) lyricFiles.add(filename);
                        }
                        const bool hasProgramChanges = std::any_of(track.programChanges.begin(), track.programChanges.end(),
                            [&](const auto &marker) { return marker.position >= part->startTime && marker.position < part->endTime; });
                        if (render || !stored.clips.empty() || hasProgramChanges) storedTracks.emplace(track.id, std::move(stored));
                    }
                    std::vector<jaras::Track> ordered;
                    for (const auto &track : config.song.tracks) if (const auto found = storedTracks.find(track.id); found != storedTracks.end())
                        ordered.push_back(std::move(found->second));
                    const auto data = multitrackData::encode(config.song, *part, std::move(ordered), renderedStems, lyricFiles, fullItems, printedRateChange);
                    if (fullItems) {
                        auto entry = object();
                        put(entry, "folder", folder.getFileName()); put(entry, "offset", part->startTime - root->startTime);
                        put(entry, "cue", jaras::playbackRegionStart(song, *part) - root->startTime); put(entry, "data", data);
                        if (song.markers) for (const auto &flag : *song.markers)
                            if (flag.sourceRegionID == part->id && flag.unifiedRegionID == root->id) {
                                put(entry, "cueID", text(flag.id)); put(entry, "cueName", text(flag.name)); put(entry, "cueColor", (int)flag.color);
                                break;
                            }
                        entries.add(entry);
                    } else {
                        multitrackData::write(folder.getChildFile(multitrackData::prefix + safeName(text(part->name))), data);
                    }
                    size_t finishedJobs = 0, jobCount = 0;
                    for (const auto &[format, request] : requests) jobCount += request.jobs.size();
                    for (const auto &[format, request] : requests) {
                        auto audio = song;
                        const auto &regionItems = sourceItems[format];
                        std::set<ID> splitTracks;
                        for (const auto &job : request.jobs)
                            if (mixedTracks.count(job.track)) splitTracks.insert(job.track);
                        for (auto &region : audio.parts) region.pitchSemitones.reset();
                        for (auto &track : audio.tracks) {
                            const bool split = splitTracks.count(track.id) > 0;
                            track.clips.erase(std::remove_if(track.clips.begin(), track.clips.end(),
                                [&](const auto &clip) {
                                    return !audioSeparation::eligible(track, clip) || (split && !regionItems.count(clip.id));
                                }), track.clips.end());
                            if (track.clips.empty()) track.audioFile.reset();
                        }
                        const auto batchSize = request.jobs.size();
                        audioExport::render(project, audio, config.mediaDirectory, request, cancel,
                            [&](double fraction) {
                                const double rendered = (finishedJobs + fraction * batchSize) / jobCount;
                                progress((completed + rendered) / std::max(1, count), status);
                            });
                        finishedJobs += batchSize;
                    }
                    ++completed;
                }
                if (fullItems) {
                    auto drawer = object();
                    put(drawer, "version", 2); put(drawer, "name", text(root->name)); put(drawer, "duration", root->endTime - root->startTime);
                    if (root->color) put(drawer, "color", (int)*root->color);
                    if (root->uppercaseName) put(drawer, "uppercaseName", *root->uppercaseName);
                    if (root->pitchSemitones) put(drawer, "pitchSemitones", *root->pitchSemitones);
                    put(drawer, "entries", entries);
                    multitrackData::write(parentFolder.getChildFile(multitrackData::prefix + safeName(text(root->name))), drawer);
                }
            }
        }
        check();
    } catch (...) {
        for (int i = owned.size(); --i >= 0;) owned[i].deleteRecursively();
        throw;
    }
}
} // namespace multitrackExport
} // namespace catlive
