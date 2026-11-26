#pragma once
#include "Session.h"

namespace catlive::liveItemResizeTests {
inline void require(bool okay, const char *message) {
    if (!okay) throw std::runtime_error(message);
}
inline jaras::Project fixture(const File &folder) {
    folder.createDirectory();
    const auto file = folder.getChildFile("resize.wav");
    auto stream = file.createOutputStream();
    WavAudioFormat format;
    std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(), 48000, 2, 24, {}, 0));
    require(writer != nullptr, "Cannot create live-resize WAV"); stream.release();
    AudioBuffer<float> samples(2, 48000 * 3);
    for (int n = 0; n < samples.getNumSamples(); ++n) {
        samples.setSample(0, n, .125f); samples.setSample(1, n, .0625f);
    }
    require(writer->writeFromAudioSampleBuffer(samples, 0, samples.getNumSamples()), "Cannot write live-resize WAV");
    writer.reset();
    jaras::Project project; project.id = uuid(); project.name = "Live resize";
    jaras::Song song; song.id = uuid(); song.name = "Timeline"; song.duration = 1;
    jaras::Track track; track.id = uuid(); track.name = "Audio"; track.role.id = "other";
    jaras::AudioClip clip; clip.id = uuid(); clip.name = "Continuous PCM"; clip.duration = 1;
    clip.audioFile = jaras::AudioFile{"resize.wav", {}};
    track.clips = {clip}; song.tracks = {track}; project.songs = {song};
    return project;
}
inline void initialise(Session &session, const jaras::Project &project, const File &folder) {
    session.inspection = true; session.mediaDirectory = folder;
    session.audio.prepareOffline(48000); session.restoreSnapshot(ProjectCodec::encode(project));
    session.audio.setOffline(true);
}
inline void assertClocks(const AudioEngine::State &before, const AudioEngine::State &after) {
    require(before.playing == after.playing && before.subPlaying == after.subPlaying &&
            before.position == after.position && before.subPosition == after.subPosition,
            "Resizing stopped or sought a transport head");
}
template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Live audio item edges extend and trim both playback heads without rebuilding or seeking", [&] {
        const auto folder = directory.getNonexistentChildFile("live-item-resize", "");
        const auto project = fixture(folder);
        auto session = std::make_unique<Session>(); initialise(*session, project, folder);
        const auto id = project.songs.front().tracks.front().clips.front().id;
        session->command(jaras::CommandKind::editSeek, {}, .25);
        session->command(jaras::CommandKind::play);
        session->command(jaras::CommandKind::subSeek, {}, .4);
        session->command(jaras::CommandKind::subPlay);
        AudioBuffer<float> block(2, 480);
        auto render = [&](int frames, float left, float right) {
            while (frames > 0) {
                const auto count = std::min(frames, block.getNumSamples());
                session->audio.render(block.getArrayOfWritePointers(), 2, count);
                for (int n = 0; n < count; ++n)
                    require(std::abs(block.getSample(0,n)-left)<1e-5f &&
                            std::abs(block.getSample(1,n)-right)<1e-5f,
                            "Live edge edit produced a gap, stale duration, or wrong stereo audio");
                frames -= count;
            }
        };
        render(480, .25f, .125f);
        const auto prepared = JSON::toString(session->audio.preparationDiagnostics);
        auto resize = [&](double start, double end) {
            const auto clock = session->audio.state(); session->resizeItem(id, start, end);
            assertClocks(clock, session->audio.state());
            require(session->transport().playing && session->transport().subPlay.playing,
                    "Resize stopped the session transport");
            require(JSON::toString(session->audio.preparationDiagnostics) == prepared,
                    "Resize rebuilt the prepared song graph");
        };
        resize(0, 2);
        render(48000, .25f, .125f); // Both heads cross the old item AND old song end.
        require(session->audio.state().playing && session->audio.state().position > 1,
                "Extending the last item left the song playback boundary stale");
        resize(0, 1);
        render(480, 0, 0); // Trim behind both running heads must become silent immediately.
        resize(.1, 2);
        render(480, .25f, .125f);
        const auto previous = session->song()->tracks.front().clips.front();
        resize(1.8, 2);
        render(480, 0, 0); // Moving the left edge past both heads must also apply immediately.
        auto clock=session->audio.state(); session->undo(); assertClocks(clock,session->audio.state());
        render(480, .25f, .125f);
        clock=session->audio.state(); session->redo(); assertClocks(clock,session->audio.state());
        render(480, 0, 0);
        session->command(jaras::CommandKind::stopAll);
        session->undo();
        const auto &restored = session->song()->tracks.front().clips.front();
        require(restored.startTime == previous.startTime && restored.duration == previous.duration &&
                restored.sourceOffset == previous.sourceOffset && restored.loopLength == previous.loopLength,
                "Undo lost the previous item source interval");
        session->redo(); require(session->song()->tracks.front().clips.front().startTime == 1.8,
                                 "Redo failed to restore the live trim");
    });
    test("Live resize and structural graph adoption retain FX delay history on main and Subplay", [&] {
        const auto folder = directory.getNonexistentChildFile("live-item-fx-history", "");
        auto project = fixture(folder); project.songs.front().duration = 3;
        const std::string delay = R"({"inserted":["Delay"],"delayEnabled":true,"delayTime":0.03,"feedback":35,"delayMix":80})";
        auto &track = project.songs.front().tracks.front();
        track.fxJSON = delay; track.clips.front().fxJSON = delay; project.masterFXJSON = delay;
        auto session = std::make_unique<Session>(); initialise(*session, project, folder);
        // Session normalises FX through the project codec. Both reference
        // graphs must use that identical configuration, including the master;
        // supplying a different master JSON intentionally replaces its DSP.
        const auto normalized = session->project();
        auto reference = std::make_unique<AudioEngine>(48000, true);
        reference->prepareSong(normalized.songs.front(), folder, JSON::parse(text(*normalized.masterFXJSON)), &normalized);
        reference->setMixer(normalized, normalized.songs.front()); reference->setOffline(true);
        session->command(jaras::CommandKind::play);
        session->command(jaras::CommandKind::subSeek, {}, .1);
        session->command(jaras::CommandKind::subPlay);
        AudioEngine::State state; state.playing = true; state.subPlaying = true; state.subPosition = .1;
        reference->transport(state);
        AudioBuffer<float> actual(2, 256), expected(2, 256);
        String phase="baseline";int blockIndex=0;
        auto compare = [&] {
            session->audio.render(actual.getArrayOfWritePointers(), 2, 256);
            reference->render(expected.getArrayOfWritePointers(), 2, 256);
            for (int ch = 0; ch < 2; ++ch) for (int n = 0; n < 256; ++n)
                if(std::abs(actual.getSample(ch,n)-expected.getSample(ch,n)) >= 1e-5f)
                    throw std::runtime_error(utf8("FX history differs during "+phase+", block "+String(blockIndex)+
                        ", channel "+String(ch)+", sample "+String(n)+": actual "+String(actual.getSample(ch,n),8)+
                        ", expected "+String(expected.getSample(ch,n),8)));
            ++blockIndex;
        };
        for (int n = 0; n < 40; ++n) compare();
        const auto clock = session->audio.state();
        session->resizeItem(track.clips.front().id, 0, 2);
        assertClocks(clock, session->audio.state());
        phase="item resize";
        for (int n = 0; n < 40; ++n) compare();
        auto updated = session->project();
        jaras::Track added; added.id=uuid(); added.name="Inserted before playing track"; added.role.id="other";
        updated.songs.front().tracks.insert(updated.songs.front().tracks.begin(), added);
        auto prepared=std::make_unique<AudioEngine>(48000,true);
        prepared->prepareSong(updated.songs.front(), folder, JSON::parse(text(*updated.masterFXJSON)), &updated);
        prepared->setMixer(updated,updated.songs.front()); prepared->setOffline(true);
        const auto beforeAdoption=session->audio.state();
        session->audio.adoptPreparedSong(*prepared,true);
        assertClocks(beforeAdoption,session->audio.state());
        // A control-thread snapshot can already be stale when adopted. Routing
        // updates must ignore its position/playing fields rather than seek back.
        AudioEngine::State routing;
        session->audio.updateTransportRouting(routing);
        // Bus indexes changed. Identical FX on item/track/master must retain
        // their populated delay lines, as must both compensated clocks.
        phase="graph adoption";
        for (int n = 0; n < 40; ++n) compare();
        require(std::abs(session->audio.state().position-reference->state().position)<1e-12 &&
                std::abs(session->audio.state().subPosition-reference->state().subPosition)<1e-12,
                "Routing metadata update rewound a playback clock");
        session->command(jaras::CommandKind::stopAll);
    });
    test("Live resize retains missing-media, MIDI and text items while respecting the movement lock", [&] {
        const auto folder = directory.getNonexistentChildFile("live-item-kind", "");
        auto project = fixture(folder); project.songs.front().duration = 5;
        auto &tracks = project.songs.front().tracks;
        tracks.front().clips.front().audioFile->path = "missing.wav";
        auto midi = tracks.front(); midi.id = uuid(); midi.clips.front().id = uuid();
        midi.clips.front().audioFile.reset(); midi.clips.front().midi.emplace();
        midi.clips.front().midi->sourceBPM = 120;
        midi.clips.front().midi->notes = {{uuid(),0,.2,60,100,1}};
        auto lyrics = tracks.front(); lyrics.id = uuid(); lyrics.role.id = "teleprompt";
        lyrics.name = jaras::fixedTrackName(lyrics.role); lyrics.clips.front().id = uuid();
        lyrics.clips.front().audioFile.reset(); lyrics.clips.front().text = "Lyrics";
        tracks.push_back(midi); tracks.push_back(lyrics);
        auto session = std::make_unique<Session>(); initialise(*session, project, folder);
        session->command(jaras::CommandKind::play);
        AudioBuffer<float> block(2, 128); session->audio.render(block.getArrayOfWritePointers(), 2, 128);
        for (const auto &track : tracks) {
            const auto clock = session->audio.state(); session->resizeItem(track.clips.front().id, 0, 2);
            assertClocks(clock, session->audio.state());
        }
        session->edit([](auto &value) { value.timelineMovementLocked = true; }, false);
        const auto before = JSON::toString(session->snapshot()); bool blocked = false;
        try { session->resizeItem(midi.clips.front().id, 0, 3); } catch (...) { blocked = true; }
        require(blocked && JSON::toString(session->snapshot()) == before, "Live trim bypassed the explicit movement lock");
        session->command(jaras::CommandKind::stopAll);
    });
}
} // namespace catlive::liveItemResizeTests
