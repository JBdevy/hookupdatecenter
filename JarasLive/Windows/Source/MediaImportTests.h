#pragma once
#include "Session.h"
#include "MP3Writer.h"
#include "ItemLayout.h"

namespace catlive::mediaImportTests {
inline void require(bool condition, const String &message) {
    if (!condition) throw std::runtime_error(utf8(message));
}
inline void wait(Session &session, int timeoutMilliseconds = 15000) {
    const auto deadline = Time::getMillisecondCounterHiRes() + timeoutMilliseconds;
    while (session.busy && Time::getMillisecondCounterHiRes() < deadline) {
        MSG message;
        while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message); DispatchMessage(&message);
        }
        Thread::sleep(2);
    }
    require(!session.busy, "Media import did not finish");
}
inline File source(const File &folder, const String &name, int frames) {
    require(folder.createDirectory().wasOk(), "Cannot create media fixture directory");
    const auto file = folder.getChildFile(name);
    auto stream = file.createOutputStream();
    require(stream != nullptr, "Cannot open WAV fixture");
    WavAudioFormat format;
    std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(), 48000, 2, 24, {}, 0));
    require(writer != nullptr, "Cannot create WAV fixture"); stream.release();
    AudioBuffer<float> pcm(2, frames); pcm.clear();
    pcm.setSample(0, frames / 2, .5f); pcm.setSample(1, frames / 2, -.25f);
    require(writer->writeFromAudioSampleBuffer(pcm, 0, frames), "Cannot write WAV fixture");
    return file;
}
inline File floatingSource(const File &folder) {
    require(folder.createDirectory().wasOk(), "Cannot create floating WAV fixture directory");
    const auto file = folder.getChildFile("above-full-scale.wav");
    auto stream = file.createOutputStream();
    require(stream != nullptr, "Cannot open floating WAV fixture");
    // Explicit IEEE-float RIFF data: a PCM writer would clip the fixture before
    // the importer sees it and could falsely pass the regression.
    constexpr int frames = 480, channels = 2, bytes = frames * channels * 4;
    auto little = [&](uint32_t value, int count) {
        for (int i = 0; i < count; ++i)
            require(stream->writeByte((char)((value >> (8 * i)) & 255)), "Cannot write float WAV header/sample");
    };
    require(stream->write("RIFF", 4), "Cannot write float WAV RIFF"); little(bytes + 36, 4);
    require(stream->write("WAVEfmt ", 8), "Cannot write float WAV format"); little(16, 4);
    little(3, 2); little(channels, 2); little(48000, 4); little(48000 * channels * 4, 4);
    little(channels * 4, 2); little(32, 2);
    require(stream->write("data", 4), "Cannot write float WAV data header"); little(bytes, 4);
    for (int n = 0; n < frames; ++n) for (int ch = 0; ch < channels; ++ch) {
        const float sample = n < 160 ? .25f : n < 320 ? 1.2f : -1.4f;
        uint32_t bits = 0; std::memcpy(&bits, &sample, sizeof(bits)); little(bits, 4);
    }
    stream->flush(); require(stream->getStatus().wasOk(), "Cannot finish floating WAV fixture");
    return file;
}
inline std::unique_ptr<AudioFormatReader> readerFor(const File &file) {
    AudioFormatManager formats; registerAudioFormats(formats);
    std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
    require(reader != nullptr, "Cannot decode media fixture: " + file.getFileName());
    return reader;
}
inline void unchangedMedia(const File &source, const File &copy) {
    MemoryBlock before, after;
    require(source.loadFileAsData(before) && copy.loadFileAsData(after) && before == after,
            "Waveform analysis must not alter or re-encode the imported media");
}
inline void initialise(Session &session, const File &directory) {
    session.inspection = true;
    session.audio.prepareOffline(48000); session.audio.setOffline(true);
    session.mediaDirectory = directory;
    require(directory.createDirectory().wasOk(), "Cannot create media destination");
    require(session.song() && session.song()->tracks.empty(), "New project must provide an empty timeline");
}
template <typename Test>
void registerTests(const File &directory, Test &test) {
    test("External WAV drop creates the first track in an empty project with portable media and undo", [&] {
        const auto folder = directory.getChildFile("empty-media-drop-" + text(uuid()));
        const auto input = source(folder, String::fromUTF8("Áudio externo 01.wav"), 480);
        Session session; initialise(session, folder.getChildFile("project"));
        const auto before = JSON::toString(ProjectCodec::encode(session.project()));
        int completions = 0; String completionError = "pending";
        session.importMedia({input}, 3, {}, MediaDropLayout::separateTracks, 0, [&](String error) { ++completions; completionError = error; }); wait(session);
        require(completions == 1 && completionError.isEmpty(), "Successful import must complete once without an error");
        require(session.song()->tracks.size() == 1, "Empty timeline rejected the drop: " + session.message);
        const auto &track = session.song()->tracks.front();
        require(track.role.id == "other" && track.clips.size() == 1, "Drop must create a standard track and its item");
        const auto &clip = track.clips.front();
        require(clip.name == utf8(input.getFileNameWithoutExtension()) && clip.startTime == 3 && std::abs(clip.duration - .01) < 1e-9,
                "Imported item lost its Unicode name, drop position or source duration");
        require(!clip.waveform.empty() && *std::max_element(clip.waveform.begin(), clip.waveform.end()) > .49,
                "Imported audio must have a decoded waveform");
        require(clip.audioFile && clip.audioFile->path.rfind("Stems/", 0) == 0, "Media reference must be project relative");
        const auto copy = ProjectCodec::resolveMedia(session.mediaDirectory, clip.audioFile->path);
        require(copy.existsAsFile() && copy != input, "Imported media must be copied into the project");
        input.deleteFile();
        require(copy.existsAsFile(), "Removing the external source must not remove project media");
        session.undo();
        require(JSON::toString(ProjectCodec::encode(session.project())) == before, "One undo must remove the new track and item");
        session.redo();
        require(session.song()->tracks.size() == 1 && copy.existsAsFile(), "Redo must restore the imported item with readable media");
    });
    for (bool sequential : {false, true}) {
        test(sequential ? "External WAV batch in empty space creates one sequential track with the chosen gap"
                        : "External WAV batch in empty space creates one track per file", [&, sequential] {
            const auto folder = directory.getChildFile("batch-media-drop-" + text(uuid()));
            const Array<File> files{source(folder, "one.wav", 480), source(folder, "two.wav", 960)};
            Session session; initialise(session, folder.getChildFile("project"));
            session.importMedia(files, 4, {}, sequential ? MediaDropLayout::sameTrack : MediaDropLayout::separateTracks, 2); wait(session);
            require(session.song()->tracks.size() == (sequential ? 1u : 2u), "Wrong track count: " + session.message);
            const auto &first = session.song()->tracks.front();
            require(first.clips.front().startTime == 4, "The first item must use the drop position");
            const auto &second = sequential ? first.clips.back() : session.song()->tracks.back().clips.front();
            require(std::abs(second.startTime - (sequential ? 6.01 : 4.0)) < 1e-9,
                    "Batch placement must match the selected layout and interval");
            session.undo(); require(session.song()->tracks.empty(), "The whole drop must undo in one step");
        });
    }
    for (bool existing : {false, true}) test(existing ? "Stacked import stays aligned on an occupied track with undo and redo" : "Stacked import creates one track with independent visual lanes", [&, existing] {
        const auto folder=directory.getChildFile("stacked-import-"+text(uuid()));
        const Array<File> files{source(folder,"one.wav",480),source(folder,"two.wav",960)};
        Session session; initialise(session,folder.getChildFile("project")); ID target;
        if(existing) {
            session.importMedia({files[0]},4,{},MediaDropLayout::separateTracks,0); wait(session);
            target=session.song()->tracks.front().id;
        }
        const auto before=JSON::toString(session.snapshot()); String error="pending";
        session.importMedia(files,4,target,MediaDropLayout::stacked,12,[&](String e){error=e;},true); wait(session);
        require(error.isEmpty(),"Stacked import failed: "+error);
        require(session.song()->tracks.size()==1,"Stacked import created separate tracks");
        const auto &track=session.song()->tracks.front();
        require(track.clips.size()==(existing?3u:2u),"Stacked import lost media");
        for(const auto &clip:track.clips)require(clip.startTime==4,"Stacked import shifted an aligned item");
        const ItemLanes lanes(track);require(lanes.count==(int)track.clips.size(),"Simultaneous items must have separate visual lanes");
        std::set<int> assigned;for(const auto &clip:track.clips)assigned.insert(lanes.lanes.at(clip.id));
        require(assigned.size()==track.clips.size(),"Two aligned items share a visual lane");
        const auto after=JSON::toString(session.snapshot()); session.undo();
        require(JSON::toString(session.snapshot())==before,"Stacked batch did not undo as one edit");
        session.redo();require(JSON::toString(session.snapshot())==after,"Redo did not restore the whole aligned batch");
    });
    test("Invalid external media batch leaves an empty timeline and its media directory unchanged", [&] {
        const auto folder = directory.getChildFile("invalid-media-drop-" + text(uuid()));
        const auto valid = source(folder, "valid.wav", 480), invalid = folder.getChildFile("broken.wav");
        require(invalid.replaceWithText("This is not audio."), "Cannot create invalid media fixture");
        Session session; initialise(session, folder.getChildFile("project"));
        const auto before = JSON::toString(ProjectCodec::encode(session.project()));
        int completions = 0; String completionError;
        session.importMedia({valid, invalid}, 0, {}, MediaDropLayout::separateTracks, 0, [&](String error) { ++completions; completionError = error; }); wait(session);
        require(JSON::toString(ProjectCodec::encode(session.project())) == before && !session.canUndo(),
                "Validation failure must not create partial tracks or undo entries");
        require(session.message.isNotEmpty(), "Validation failure must provide an explanation");
        require(completions == 1 && completionError.isNotEmpty() && completionError == session.message,
                "A rejected import must deliver its error once to the visible UI");
        require(session.mediaDirectory.findChildFiles(File::findFiles, true).isEmpty(),
                "A rejected batch must not leave copied media behind");
    });
    test("Floating WAV above full scale imports with Mac waveform bounds and untouched PCM", [&] {
        const auto folder = directory.getChildFile("float-media-drop-" + text(uuid()));
        const auto input = floatingSource(folder);
        Session session; initialise(session, folder.getChildFile("project"));
        String completionError = "pending"; int completions = 0;
        session.importMedia({input}, 0, {}, MediaDropLayout::separateTracks, 0, [&](String error) { ++completions; completionError = error; }); wait(session);
        require(completions == 1 && completionError.isEmpty() && session.song()->tracks.size() == 1,
                "Overfull float media was rejected: " + completionError);
        const auto &clip = session.song()->tracks.front().clips.front();
        require(!clip.waveform.empty() && std::all_of(clip.waveform.begin(), clip.waveform.end(),
                [](double peak) { return std::isfinite(peak) && peak >= 0 && peak <= 1; }),
                "Saved waveform peaks must stay within the shared project schema");
        require(std::abs(clip.waveform.front() - .25) < 1e-7 &&
                *std::max_element(clip.waveform.begin(), clip.waveform.end()) == 1,
                "Only overfull display peaks should clamp; ordinary bins must not be rescaled");
        require(clip.audioFile.has_value(), "Imported float item has no media reference");
        const auto copy = ProjectCodec::resolveMedia(session.mediaDirectory, clip.audioFile->path);
        unchangedMedia(input, copy);
        const auto reader = readerFor(copy); AudioBuffer<float> pcm(2, 480);
        require(reader->usesFloatingPointData && reader->read(&pcm, 0, 480, 0, true, true),
                "Imported waveform fixture must still be floating-point audio");
        require(pcm.getSample(0, 200) == 1.2f && pcm.getSample(1, 400) == -1.4f,
                "Import clipped the source audio instead of only limiting its display peaks");
        jaras::validate(session.project());
    });
    test("Real MP3 media imports with bounded waveform peaks and unchanged encoded bytes", [&] {
        const auto folder = directory.getChildFile("mp3-media-drop-" + text(uuid()));
        require(folder.createDirectory().wasOk(), "Cannot create MP3 fixture directory");
        const auto input = folder.getChildFile("full-scale.mp3");
        constexpr int frames = 24000;
        {
            MP3Writer writer(input, 48000, 2, 192); AudioBuffer<float> pcm(2, frames);
            for (int n = 0; n < frames; ++n) {
                pcm.setSample(0, n, (float)(1.2 * std::sin(n * 997.0 * MathConstants<double>::twoPi / 48000)));
                pcm.setSample(1, n, (float)(.9 * std::sin(n * 613.0 * MathConstants<double>::twoPi / 48000)));
            }
            writer.write(pcm, frames); writer.finish();
        }
        const auto original = readerFor(input);
        AudioBuffer<float> decoded(2, (int)original->lengthInSamples);
        require(original->read(&decoded, 0, decoded.getNumSamples(), 0, true, true), "Cannot decode generated MP3");
        const float sourcePeak = decoded.getMagnitude(0, decoded.getNumSamples());
        require(sourcePeak > .5f, "MP3 fixture must contain audible audio");
        Session session; initialise(session, folder.getChildFile("project"));
        String completionError = "pending";
        session.importMedia({input}, 0, {}, MediaDropLayout::separateTracks, 0, [&](String error) { completionError = error; }); wait(session);
        require(completionError.isEmpty() && session.song()->tracks.size() == 1, "MP3 import failed: " + completionError);
        const auto &clip = session.song()->tracks.front().clips.front();
        require(!clip.waveform.empty() && std::all_of(clip.waveform.begin(), clip.waveform.end(),
                [](double peak) { return std::isfinite(peak) && peak >= 0 && peak <= 1; }),
                "Decoded MP3 overshoots must not invalidate project waveform data");
        require(std::abs(*std::max_element(clip.waveform.begin(), clip.waveform.end()) - std::min(1.f, sourcePeak)) < 1e-6,
                "MP3 display peak must match the decoded signal, bounded like the Mac");
        require(clip.audioFile.has_value(), "Imported MP3 item has no media reference");
        unchangedMedia(input, ProjectCodec::resolveMedia(session.mediaDirectory, clip.audioFile->path));
        jaras::validate(session.project());
    });
    const auto requestedFiles = SystemStats::getEnvironmentVariable("CATLIVE_TEST_MEDIA_IMPORT_FILES", {});
    if (requestedFiles.isNotEmpty()) test("External real media files import with valid waveforms, intact copies and one undo", [&] {
        Array<File> sources;
        for (const auto &line : StringArray::fromLines(requestedFiles)) {
            const auto path = line.trim();
            if (path.isNotEmpty()) sources.addIfNotAlreadyThere(File(path));
        }
        require(!sources.isEmpty(), "Requested external media list is empty");
        Array<var> sourcePeaks;
        for (const auto &file : sources) {
            require(file.existsAsFile(), "Requested media fixture does not exist: " + file.getFileName());
            const auto reader = readerFor(file);
            AudioBuffer<float> pcm((int)std::min(2u, reader->numChannels), 32768);
            double peak = 0;
            for (int64 offset = 0; offset < reader->lengthInSamples; offset += pcm.getNumSamples()) {
                const int count = (int)std::min<int64>(pcm.getNumSamples(), reader->lengthInSamples - offset);
                require(reader->read(&pcm, 0, count, offset, true, true), "Cannot inspect the original media peak");
                peak = std::max(peak, (double)pcm.getMagnitude(0, count));
            }
            auto entry = object(); put(entry, "name", file.getFileName()); put(entry, "decodedPeak", peak);
            sourcePeaks.add(entry);
        }
        require(directory.getChildFile("real-media-import-peaks.json").replaceWithText(JSON::toString(var(sourcePeaks))),
                "Cannot write the real media peak diagnostics");
        const auto folder = directory.getChildFile("real-media-import-" + text(uuid()));
        Session session; initialise(session, folder);
        const auto before = JSON::toString(ProjectCodec::encode(session.project()));
        String completionError = "pending"; int completions = 0;
        session.importMedia(sources, 0, {}, MediaDropLayout::separateTracks, 0, [&](String error) { ++completions; completionError = error; });
        wait(session, 120000);
        require(completions == 1 && completionError.isEmpty(), "Real media import failed: " + completionError);
        require(session.song()->tracks.size() == (size_t)sources.size(), "Real media drop did not create one track per source");
        for (int i = 0; i < sources.size(); ++i) {
            const auto &track = session.song()->tracks[(size_t)i];
            require(track.clips.size() == 1, "Real media track must have exactly one imported item");
            const auto &clip = track.clips.front();
            require(clip.audioFile.has_value() && !clip.waveform.empty() && clip.duration > 0,
                    "Real media item lost its source, duration or waveform");
            require(std::all_of(clip.waveform.begin(), clip.waveform.end(),
                    [](double peak) { return std::isfinite(peak) && peak >= 0 && peak <= 1; }),
                    "Real media decoded a waveform peak outside the shared project schema");
            unchangedMedia(sources[i], ProjectCodec::resolveMedia(session.mediaDirectory, clip.audioFile->path));
        }
        jaras::validate(session.project());
        session.undo();
        require(JSON::toString(ProjectCodec::encode(session.project())) == before,
                "One undo must restore the empty project after the real media batch");
    });
}
} // namespace catlive::mediaImportTests
