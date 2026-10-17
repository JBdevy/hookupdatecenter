#pragma once
#include "AudioEngine.h"
#include "MP3Writer.h"
namespace catlive {
struct ExportEncoding {
    String format = "WAV";
    int bits = 24, channels = 2, bitrate = 320;
    double rate = 48000;
};
struct ExportJob {
    String name;
    double start = 0, end = 0;
    ID track, clip;
    int output = 0;
    std::optional<double> minimumClipStart;
};
struct ExportRequest {
    File directory;
    std::vector<ExportJob> jobs;
    ExportEncoding encodings[2];
};
namespace audioExport {
// Mirrors Application/Export/AudioExportPlan.swift. IDs and timing remain in the shared model.
inline std::vector<ExportJob> plan(const jaras::Project &project, const jaras::Song &song,
                                   int source, int bounds, const String &pattern,
                                   const std::set<ID> &tracks, const std::set<ID> &clips,
                                   const std::set<ID> &regions,
                                   std::optional<std::pair<double, double>> area,
                                   const ExportEncoding &encoding) {
    std::vector<ExportJob> result;
    std::set<String> used;
    auto append = [&](const jaras::Track *track, const jaras::AudioClip *clip,
                      const jaras::Part *region, double start, double end) {
        if (!std::isfinite(start) || !std::isfinite(end) || end <= start)
            return;
        const std::map<String, String> tokens{
            {"%project", text(project.name)},
            {"%track", track ? text(track->name) : "Master"},
            {"%stem", clip    ? File(text(clip->name)).getFileNameWithoutExtension()
                      : track ? text(track->name)
                              : "Master"},
            {"%region", region ? text(region->name) : text(song.name)}};
        String raw;
        for (int i = 0; i < pattern.length();) {
            bool matched = false;
            for (const auto &token : tokens)
                if (pattern.substring(i).startsWith(token.first)) {
                    raw += token.second;
                    i += token.first.length();
                    matched = true;
                    break;
                }
            if (!matched)
                raw += pattern.substring(i, i + 1), ++i;
        }
        auto base = File::createLegalFileName(raw.replaceCharacters("/\\:\r\n", "_____ ").trim())
                        .substring(0, 100);
        if (base.isEmpty())
            base = "Export";
        for (auto extension : {".wav", ".aiff", ".aif", ".mp3"})
            if (base.endsWithIgnoreCase(extension))
                base = base.dropLastCharacters((int)std::strlen(extension));
        const auto upper = base.upToFirstOccurrenceOf(".", false, false).toUpperCase();
        if (StringArray{"CON",  "PRN",  "AUX",  "NUL",  "COM1", "COM2", "COM3", "COM4",
                        "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3",
                        "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"}
                .contains(upper))
            base = "_" + base;
        if (!track && source == 2 && base != "Master" && !base.endsWith(" Master"))
            base += " Master";
        auto name = base + "." + encoding.format.toLowerCase();
        int suffix = 2;
        while (!used.insert(name.toLowerCase()).second)
            name = base + " (" + String(suffix++) + ")." + encoding.format.toLowerCase();
        ExportJob job;
        job.name = name;
        job.start = start;
        job.end = end;
        if (track)
            job.track = track->id;
        if (clip)
            job.clip = clip->id;
        if (region && region->parentRegionID)
            job.minimumClipStart = region->startTime;
        result.push_back(std::move(job));
    };
    if (source == 3) {
        for (const auto &track : song.tracks)
            if (jaras::fixedTrackName(track.role).empty())
                for (const auto &clip : track.clips)
                    if (clips.count(clip.id)) {
                        const jaras::Part *region = nullptr;
                        for (const auto &part : song.parts)
                            if (clip.startTime >= part.startTime && clip.startTime < part.endTime) {
                                region = &part;
                                break;
                            }
                        append(&track, &clip, region, clip.startTime,
                               clip.startTime + clip.duration);
                    }
    } else {
        auto range = [&](const jaras::Part *region, double start, double end) {
            if (source != 1)
                append(nullptr, nullptr, region, start, end);
            if (source != 0)
                for (const auto &track : song.tracks)
                    if (tracks.count(track.id) && jaras::fixedTrackName(track.role).empty())
                        append(&track, nullptr, region, start, end);
        };
        if (bounds == 0) {
            double lastAudioEnd = 0;
            for (const auto &track : song.tracks)
                if (jaras::fixedTrackName(track.role).empty())
                    for (const auto &clip : track.clips)
                        if (clip.audioFile || track.audioFile)
                            lastAudioEnd = std::max(lastAudioEnd, clip.startTime + clip.duration);
            range(nullptr, 0, lastAudioEnd);
        } else if (bounds == 1 && area)
            range(nullptr, area->first, area->second);
        else
            for (const auto &region : song.parts)
                if (bounds == 2 ? regions.count(region.id) : !region.parentRegionID)
                    range(&region, region.startTime, region.endTime);
    }
    return result;
}
inline void appendSecondary(std::vector<ExportJob> &primary, std::vector<ExportJob> secondary) {
    std::set<String> names;
    for (const auto &job : primary)
        names.insert(job.name.toLowerCase());
    for (auto &job : secondary) {
        const auto file = File(job.name);
        const auto base = file.getFileNameWithoutExtension(), extension = file.getFileExtension();
        int suffix = 2;
        while (!names.insert(job.name.toLowerCase()).second)
            job.name = base + " (" + String(suffix++) + ")" + extension;
        job.output = 1;
        primary.push_back(std::move(job));
    }
}
inline void render(const jaras::Project &project, const jaras::Song &original, const File &media,
                   const ExportRequest &request, std::atomic<bool> &cancel,
                   const std::function<void(double)> &progress) {
    if (request.jobs.empty() || request.jobs.size() > 10000)
        throw std::runtime_error("Nenhum arquivo selecionado para exportar.");
    if (request.directory.createDirectory().failed())
        throw std::runtime_error("Não foi possível criar o diretório de saída.");
    for (const auto &job : request.jobs) {
        if (job.name != File(job.name).getFileName() || job.output < 0 || job.output > 1 ||
            !std::isfinite(job.start) || !std::isfinite(job.end) || job.start < 0 ||
            job.end <= job.start)
            throw std::runtime_error("Plano de exportação inválido.");
        if (request.directory.getChildFile(job.name).exists())
            throw std::runtime_error(
                "Já existe um arquivo com este nome. Escolha outro nome ou diretório.");
    }
    std::vector<File> published;
    try {
        for (size_t jobIndex = 0; jobIndex < request.jobs.size(); ++jobIndex) {
        if (cancel.load())
            throw std::runtime_error("Exportação cancelada.");
        const auto &job = request.jobs[jobIndex];
        const auto &encoding = request.encodings[job.output];
        if ((encoding.channels != 1 && encoding.channels != 2) ||
            (encoding.bits != 16 && encoding.bits != 24 && encoding.bits != 32) ||
            (encoding.rate != 44100 && encoding.rate != 48000) ||
            (encoding.bitrate != 128 && encoding.bitrate != 160 &&
             encoding.bitrate != 192 && encoding.bitrate != 224 &&
             encoding.bitrate != 256 && encoding.bitrate != 320))
            throw std::runtime_error("Formato de exportação inválido.");
        auto song = original;
        for (auto &track : song.tracks) {
            track.clips.erase(std::remove_if(track.clips.begin(), track.clips.end(),
                                             [&](const auto &clip) {
                                                 return (!job.clip.empty() &&
                                                         clip.id != job.clip) ||
                                                        (job.minimumClipStart &&
                                                         clip.startTime < *job.minimumClipStart);
                                             }),
                              track.clips.end());
            if (!job.clip.empty() && track.id != job.track)
                track.audioFile.reset();
        }
        AudioEngine engine;
        engine.prepareOffline(encoding.rate);
        engine.prepareSong(song, media,
                           project.masterFXJSON ? JSON::parse(text(*project.masterFXJSON)) : var(),
                           &project);
        engine.setOffline(true);
        engine.setMixer(project, song);
        engine.setExportCapture(job.track);
        if (!engine.missingFiles.isEmpty() || !engine.unsupported.isEmpty())
            throw std::runtime_error(
                "Corrija as mídias ausentes e os efeitos incompatíveis antes de exportar.");
        const auto destination = request.directory.getChildFile(job.name);
        TemporaryFile temporary(destination);
        std::unique_ptr<AudioFormatWriter> writer;
        std::unique_ptr<MP3Writer> mp3;
        if (encoding.format == "MP3")
            mp3 = std::make_unique<MP3Writer>(temporary.getFile(), (int)encoding.rate,
                                              encoding.channels, encoding.bitrate);
        else {
            auto stream = std::make_unique<FileOutputStream>(temporary.getFile());
            if (!stream->openedOk())
                throw std::runtime_error("Não foi possível abrir o arquivo de saída.");
            WavAudioFormat wav;
            RecordingAiffFormat aiff;
            AudioFormat *format = encoding.format == "WAV"    ? static_cast<AudioFormat *>(&wav)
                                  : encoding.format == "AIFF" ? static_cast<AudioFormat *>(&aiff)
                                                              : nullptr;
            if (!format)
                throw std::runtime_error("Formato de saída desconhecido.");
            writer.reset(format->createWriterFor(
                stream.get(), encoding.rate, (unsigned)encoding.channels, encoding.bits, {}, 0));
            if (!writer)
                throw std::runtime_error("Não foi possível iniciar a codificação.");
            stream.release();
        }
        AudioEngine::State state;
        state.playing = true;
        state.position = job.start;
        engine.transport(state);
        AudioBuffer<float> buffer(2, 1024);
        const int64 frames = (int64)std::llround((job.end - job.start) * encoding.rate);
        for (int64 at = 0; at < frames; at += 1024) {
            if (cancel.load())
                throw std::runtime_error("Exportação cancelada.");
            const int count = (int)std::min<int64>(1024, frames - at);
            engine.render(buffer.getArrayOfWritePointers(), 2, count);
            for (int n = 0; n < count; ++n) {
                if (!std::isfinite(buffer.getSample(0, n)) ||
                    !std::isfinite(buffer.getSample(1, n)))
                    throw std::runtime_error("A renderização produziu áudio inválido.");
                if (encoding.channels == 1)
                    buffer.setSample(0, n, (buffer.getSample(0, n) + buffer.getSample(1, n)) * .5f);
            }
            if (mp3)
                mp3->write(buffer, count);
            else if (!writer->writeFromAudioSampleBuffer(buffer, 0, count))
                throw std::runtime_error("Falha ao gravar o áudio.");
            if (progress && at % (int64)encoding.rate < 1024)
                progress((jobIndex + (double)at / frames) / request.jobs.size());
        }
        if (mp3)
            mp3->finish();
        writer.reset();
        mp3.reset();
        if (engine.getUnderruns())
            throw std::runtime_error("Falha na leitura das mídias durante a exportação.");
        if (destination.exists() || !temporary.overwriteTargetFileWithTemporary())
            throw std::runtime_error("Não foi possível concluir o arquivo de saída.");
        published.push_back(destination);
        }
    } catch (...) {
        for (const auto &file : published)
            file.deleteFile();
        throw;
    }
    if (progress)
        progress(1);
}
} // namespace audioExport
} // namespace catlive
