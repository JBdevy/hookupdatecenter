#pragma once
#include "ProjectCodec.h"
namespace catlive::dynamicsAssets {
inline void collect(const var &settings, std::set<std::string> &paths, int depth = 0) {
    if (depth > 8) return;
    const auto path = str(get(settings, "trigger"), "samplePath");
    if (list(get(settings, "inserted")).contains(var("CatLive Trigger")) && path.isNotEmpty()) paths.insert(utf8(path));
    for (const auto &instance : list(get(settings, "instances"))) {
        const auto keys = list(get(settings, "inserted"));
        if (keys.contains(var("Native:" + str(instance, "id"))) || keys.contains(var("Instance:" + str(instance, "id"))))
            collect(get(instance, "settings"), paths, depth + 1);
    }
}
inline void collect(const jaras::Project &project, std::set<std::string> &paths) {
    const auto append = [&](const std::optional<std::string> &json) { if (json) collect(JSON::parse(text(*json)), paths); };
    append(project.masterFXJSON);
    for (const auto &song : project.songs) for (const auto &track : song.tracks) {
        append(track.fxJSON); for (const auto &clip : track.clips) append(clip.fxJSON);
    }
}
inline void rewrite(var settings, const std::map<String, String> &mapping, int depth = 0) {
    if (depth > 8) return;
    auto trigger = get(settings, "trigger");
    auto found = mapping.find(str(trigger, "samplePath"));
    if (found != mapping.end()) put(trigger, "samplePath", found->second);
    for (auto instance : list(get(settings, "instances"))) rewrite(get(instance, "settings"), mapping, depth + 1);
}
inline void rewrite(jaras::Project &project, const std::map<String, String> &mapping) {
    const auto replace = [&](std::optional<std::string> &json) {
        if (!json) return;
        auto settings = JSON::parse(text(*json)); rewrite(settings, mapping); json = utf8(JSON::toString(settings));
    };
    replace(project.masterFXJSON);
    for (auto &song : project.songs) for (auto &track : song.tracks) {
        replace(track.fxJSON); for (auto &clip : track.clips) replace(clip.fxJSON);
    }
}
inline std::unique_ptr<AudioFormatReader> reader(const File &file, AudioFormatManager &formats) {
    if (!file.hasFileExtension("wav;mp3")) throw std::runtime_error("Choose a WAV or MP3 sample.");
    auto result = std::unique_ptr<AudioFormatReader>(formats.createReaderFor(file));
    if (!result || !std::isfinite(result->sampleRate) || result->sampleRate <= 0 || result->sampleRate > 384000 || result->numChannels < 1 || result->numChannels > 2 ||
        result->lengthInSamples <= 0 || result->lengthInSamples > result->sampleRate * 60)
        throw std::runtime_error("Choose a mono or stereo sample up to 60 seconds.");
    return result;
}
inline String importSample(const File &file, const File &directory) {
    AudioFormatManager formats; registerAudioFormats(formats); auto decoded = reader(file, formats);
    AudioBuffer<float> validation((int)decoded->numChannels, (int)decoded->lengthInSamples);
    if (!decoded->read(&validation, 0, validation.getNumSamples(), 0, true, true))
        throw std::runtime_error("Could not read the trigger sample.");
    const auto stems = directory.getChildFile("Stems");
    if (stems.createDirectory().failed()) throw std::runtime_error("Could not create the sample folder.");
    if (file.getParentDirectory() == stems) return "Stems/" + file.getFileName();
    const auto destination = stems.getNonexistentChildFile(File::createLegalFileName(file.getFileNameWithoutExtension()), file.getFileExtension());
    TemporaryFile temporary(destination);
    if (!file.copyFileTo(temporary.getFile()) || !temporary.overwriteTargetFileWithTemporary())
        throw std::runtime_error("Could not copy the sample to the project.");
    return "Stems/" + destination.getFileName();
}
} // namespace catlive::dynamicsAssets
