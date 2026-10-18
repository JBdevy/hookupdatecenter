#pragma once
#include "FloatingControlTests.h"
#include "ClickTempo.h"
#include "FXSchema.h"
namespace catlive::bpmDetectionTests {
using floatingControlTests::require;
using floatingControlTests::pump;
inline File clickFile(const File &directory) {
    const auto file = directory.getNonexistentChildFile("bpm-background-click", ".wav");
    WavAudioFormat format; auto stream = file.createOutputStream();
    std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(), 48000, 1, 24, {}, 0));
    require(bool(writer), "Cannot create Click fixture"); stream.release();
    AudioBuffer<float> pcm(1, 16 * 48000); pcm.clear();
    for (int beat = 0; beat < 32; ++beat)
        for (int sample = 0; sample < 128; ++sample)
            pcm.setSample(0, beat * 24000 + sample, .5f * float(128 - sample) / 128.f);
    require(writer->writeFromAudioSampleBuffer(pcm, 0, pcm.getNumSamples()), "Cannot write Click fixture");
    writer.reset(); return file;
}
inline jaras::Project fixture(const File &file) {
    auto result = floatingControlTests::fixture();
    auto &song = result.songs.front();
    song.parts.resize(1); song.parts.front().endTime = 15;
    auto &track = song.tracks.front(); track.name = "Click"; track.role.id = "click";
    jaras::AudioClip clip; clip.id = uuid(); clip.duration = 15;
    clip.audioFile = jaras::AudioFile{utf8(file.getFileName()), {}};
    track.clips = {clip}; return result;
}
inline void setup(Session &session, const jaras::Project &project, const File &directory) {
    session.inspection = true; session.audio.prepareOffline(48000);
    session.mediaDirectory = directory;
    session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
}
inline void wait(Session &session) {
    const auto deadline = Time::getMillisecondCounterHiRes() + 15000;
    while (session.isDetectingBPM() && Time::getMillisecondCounterHiRes() < deadline) pump();
    require(!session.isDetectingBPM() && !session.busy, "BPM job failed to finish or left the session locked");
}
inline int tempos(const Session &session) {
    return session.song()->markers ? (int)std::count_if(session.song()->markers->begin(), session.song()->markers->end(),
        [](const auto &marker) { return marker.tempoBPM.has_value(); }) : 0;
}
template <typename Test> void registerTests(const File &directory, Test &test) {
    test("BPM detection reuses prepared waveform peaks and invalidates changed source stamps", [&] {
        const auto file = clickFile(directory);
        AudioFormatManager formats; registerAudioFormats(formats);
        std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
        require(bool(reader), "Cannot read Click fixture");
        auto first = WaveformCache::forAnalysis(file, *reader);
        require(first && first->mappedBytes() == 0, "Fresh Click fixture unexpectedly reused unrelated peaks");
        auto reused = WaveformCache::forAnalysis(file, *reader);
        require(reused && reused->mappedBytes() > 0 && reused->frames == first->frames,
                "Prepared peaks were decoded again instead of mapped");
        const auto stamp = file.getLastModificationTime();
        require(file.setLastModificationTime(Time(stamp.toMilliseconds() + 2000)), "Cannot update source stamp");
        auto changed = WaveformCache::forAnalysis(file, *reader);
        require(changed && changed->mappedBytes() == 0, "Changed source reused stale peaks");
        std::atomic<bool> cancelled{true};
        require(!WaveformCache::forAnalysis(file, *reader, &cancelled), "Cancelled analysis still opened its cache");
    });
    test("BPM analysis keeps cursor and Click controls responsive and adds independent tempo Undo history", [&] {
        const auto p = fixture(clickFile(directory)); Session session; setup(session, p, directory);
        const auto track = session.song()->tracks.front().id, part = session.song()->parts.front().id;
        session.detectRegionBPM({part});
        require(session.isDetectingBPM() && !session.busy, "Analysis took the global interaction lock");
        session.command(jaras::CommandKind::editSeek, {}, 3.25);
        session.mixerCommand(jaras::CommandKind::volume, track, {track}, .35);
        auto fx = fxschema::defaults(); put(fx, "inserted", Array<var>{"EQ"}); put(fx, "eqEnabled", true);
        session.configureEffects(track, fx);
        const auto expectedFX = session.song()->tracks.front().fxJSON;
        require(session.transport().editPosition == 3.25 && session.song()->tracks.front().volume == .35,
                "Click controls or edit cursor ignored input while BPM was running");
        session.command(jaras::CommandKind::play);
        wait(session);
        require(tempos(session) > 0 && session.transport().playing && session.transport().editPosition == 3.25,
                "Analysis completion moved the cursor, stopped playback or failed to apply valid tempo");
        require(session.song()->tracks.front().fxJSON == expectedFX, "Tempo application reverted an unrelated FX edit");
        session.undo();
        require(tempos(session) == 0 && session.song()->tracks.front().fxJSON == expectedFX && session.transport().playing,
                "Tempo Undo reverted FX or stopped playback");
        session.undo(); require(!session.song()->tracks.front().fxJSON, "Interleaved FX Undo was lost");
        session.redo(); require(session.song()->tracks.front().fxJSON == expectedFX && tempos(session) == 0,
                                "Interleaved FX Redo unexpectedly applied tempo");
        session.redo(); require(tempos(session) > 0 && session.song()->tracks.front().fxJSON == expectedFX,
                                "Tempo Redo lost the independent FX state");
        session.command(jaras::CommandKind::stopAll);
    });
    test("Generated Click track accepts volume, mute and solo including selected-track groups", [&] {
        auto p = floatingControlTests::fixture();
        auto &click = p.songs.front().tracks.front(); click.role.id = "generatedClick"; click.name = "Click";
        const auto id = click.id, other = p.songs.front().tracks[1].id;
        jaras::AudioClip clip; clip.id = uuid(); clip.duration = 15; click.clips = {clip};
        Session session; setup(session, p, directory);
        auto track = [&](const ID &wanted) -> const jaras::Track & {
            for (const auto &t : session.song()->tracks) if (t.id == wanted) return t;
            throw std::runtime_error("Missing generated Click fixture track");
        };
        session.mixerCommand(jaras::CommandKind::volume, id, {id}, .4);
        session.mixerCommand(jaras::CommandKind::mute, id, {id});
        session.mixerCommand(jaras::CommandKind::solo, id, {id});
        require(track(id).volume == .4 && track(id).mute && track(id).solo,
                "Generated Click controls were filtered out as an unsupported special track");
        require(track(other).volume == 1 && !track(other).mute && !track(other).solo,
                "Single-track Click controls changed an unselected track");
        session.command(jaras::CommandKind::play);
        session.mixerCommand(jaras::CommandKind::volume, id, {id, other}, .2);
        session.mixerCommand(jaras::CommandKind::mute, id, {id, other});
        session.mixerCommand(jaras::CommandKind::solo, id, {id, other});
        require(std::abs(track(id).volume - .2) < 1e-9,
                "Generated Click source fader ignored its selected-track gesture");
        require(std::abs(track(other).volume - .5) < 1e-9,
                "Generated Click fader did not scale the selected audio track proportionally");
        require(!track(id).mute && !track(other).mute,
                "Generated Click mute did not update all selected tracks");
        require(!track(id).solo && !track(other).solo,
                "Generated Click solo did not update all selected tracks");
        require(session.transport().playing, "Generated Click controls stopped playback");
        session.command(jaras::CommandKind::stopAll);
    });
    test("BPM cancellation, stale Click edits, project replacement and read failures never lock editing", [&] {
        const auto p = fixture(clickFile(directory)); Session session; setup(session, p, directory);
        const auto part = session.song()->parts.front().id;
        session.detectRegionBPM({part}); session.cancelBPMDetection();
        require(!session.isDetectingBPM() && !session.busy, "Cancel left BPM pending");
        session.command(jaras::CommandKind::editSeek, {}, 5);
        session.detectRegionBPM({part});
        session.edit([](auto &project) { project.songs.front().tracks.front().clips.front().startTime = .25; }, false);
        wait(session);
        require(tempos(session) == 0 && session.message.contains(String::fromUTF8("mudou durante a análise")),
                "Result from old Click geometry was applied silently");
        session.detectRegionBPM({part}); session.newProject("Replacement");
        require(!session.isDetectingBPM() && !session.busy && session.project().name == "Replacement",
                "Project replacement waited for BPM work");
        pump(); require(tempos(session) == 0, "Old BPM result leaked into another project");
        auto bad = p; bad.songs.front().tracks.front().clips.front().audioFile->path = "missing-click.wav";
        setup(session, bad, directory); session.detectRegionBPM({part}); wait(session);
        require(session.message.isNotEmpty() && tempos(session) == 0, "Unreadable audio did not finish with an error");
        session.command(jaras::CommandKind::editSeek, {}, 7);
        require(session.transport().editPosition == 7, "Read failure left cursor blocked");
        setup(session, p, directory); session.detectRegionBPM({part}); wait(session);
        require(tempos(session) > 0, "BPM could not run again after cancellation/failure");
    });
}
}
