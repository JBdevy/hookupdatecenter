#pragma once
#include "AudioEngine.h"

namespace catlive::transportFadeoutTests {
inline void require(bool passed, const String &message) {
    if (!passed) throw std::runtime_error(utf8(message));
}
inline void staleCallback() {
    TransportFadeout fade;
    require(!fade.block().active && fade.block().gain() == 1, "Initial fade is not unity");
    fade.start(48000);
    const auto previous = fade.block();
    require(previous.gain() == 1 && previous.gain(47999) == 0, "Sample endpoints changed");
    fade.cancel(); fade.advance(previous, 512);
    require(!fade.block().active && fade.block().gain() == 1, "Old callback resurrected cancel");
    fade.start(48000); const auto beforeRestart = fade.block();
    fade.cancel(); fade.start(48000); fade.advance(beforeRestart, 512);
    require(fade.block().remaining == 48000, "Old callback consumed frames of a restarted fade");
    const auto next = fade.block(); fade.advance(next, 48000);
    require(fade.block().active && fade.block().remaining == 0 && fade.block().gain() == 0,
            "Completed fade must remain silent until explicit cancel");
}
inline void audio(const File &directory) {
    const auto folder = directory.getChildFile("transport-fade-" + text(uuid())); folder.createDirectory();
    const auto file = folder.getChildFile("constant.wav");
    {
        WavAudioFormat format; auto stream = file.createOutputStream();
        require(stream != nullptr, "Cannot create fade fixture");
        auto writer = std::unique_ptr<AudioFormatWriter>(format.createWriterFor(stream.get(), 48000, 1, 24, {}, 0));
        require(writer != nullptr, "Cannot create fade fixture writer"); stream.release();
        AudioBuffer<float> block(1, 4800);
        for (int n = 0; n < block.getNumSamples(); ++n) block.setSample(0, n, .5f);
        for (int n = 0; n < 200; ++n) require(writer->writeFromAudioSampleBuffer(block, 0, block.getNumSamples()), "Fixture write failed");
    }
    jaras::Project project; project.id = uuid();
    jaras::Song song; song.id = uuid(); song.duration = 20;
    for (int i = 0; i < 2; ++i) {
        jaras::Track track; track.id = uuid(); track.name = "Fade " + std::to_string(i);
        track.role.id = "other"; track.volume = i == 0 ? .7 : .5;
        track.outputs = std::vector<jaras::OutputPatch>{{i + 1, 1}};
        if (i == 0) {
            auto settings = object(); put(settings, "mode", "read");
            put(settings, "envelopes", Array<var>{automation::envelope("volume", AutomationCurve::normalized(.8))});
            track.automationJSON = utf8(JSON::toString(settings, true));
        }
        jaras::AudioClip clip; clip.id = uuid(); clip.duration = 20; clip.audioFile = jaras::AudioFile{"constant.wav", {}};
        track.clips.push_back(clip); song.tracks.push_back(track);
    }
    project.songs.push_back(song);
    AudioEngine engine; engine.prepareOffline(48000); engine.prepareSong(song, folder, {}, &project);
    engine.setOffline(true); engine.setMixer(project, song);
    AudioEngine::State state; state.playing = true; engine.transport(state);
    AudioBuffer<float> output(2, 4096);
    auto render = [&](int count) { engine.render(output.getArrayOfWritePointers(), 2, count); };
    render(1);
    require(std::abs(output.getSample(0, 0) - .4f) < .0002f && std::abs(output.getSample(1, 0) - .25f) < .0002f,
            "Fade fixture routing/automation differs from expected gain");
    const auto selected = song.tracks[0].id, other = song.tracks[1].id;
    for (int seconds = 1; seconds <= 5; ++seconds) {
        engine.transport(state);
        engine.startTrackFadeout({selected}, seconds);
        require(engine.trackFadeoutActive() && !engine.trackFadeoutComplete() && engine.trackFadeoutGain(selected) == 1,
                "Fade did not start at unity");
        require(engine.trackFadeoutGain(other) == 1 && std::abs(engine.trackFadeoutRemainingSeconds() - seconds) < 1e-9,
                "Selected fade changed other track or duration");
        const int frames = seconds * 48000;
        for (int frame = 0; frame < frames; frame += 257) {
            const int count = std::min(257, frames - frame); render(count);
            for (int i : {0, count - 1}) {
                const float gain = float(frames - 1 - frame - i) / float(frames - 1);
                require(std::abs(output.getSample(0, i) - .4f * gain) < .0003f, "Fade is not sample-accurate after automation");
                require(std::abs(output.getSample(1, i) - .25f) < .0003f, "Unselected track was faded");
            }
        }
        require(engine.trackFadeoutComplete() && engine.trackFadeoutGain(selected) == 0 && engine.trackFadeoutRemainingSeconds() == 0,
                "Fade did not complete exactly at the last frame");
        render(1024); require(output.getMagnitude(0, 0, 1024) == 0, "Completed fade resumed before Stop/cancel");
        engine.cancelTrackFadeout(); render(1);
        require(!engine.trackFadeoutActive() && !engine.trackFadeoutComplete() && std::abs(output.getSample(0, 0) - .4f) < .0002f,
                "Cancel did not restore automation/fader gain on next buffer");
    }
    engine.transport(state); engine.startTrackFadeout({selected, other}, 2); render(4096);
    require(engine.trackFadeoutGain(selected) == engine.trackFadeoutGain(other), "Selected tracks did not share one frame clock");
    engine.cancelTrackFadeout(); render(1);
    require(std::abs(output.getSample(1, 0) - .25f) < .0002f, "Mid-fade cancel changed the second fader");
    engine.startTrackFadeout({selected}, 1); render(4096);
    engine.prepareSong(song, folder, {}, &project);
    require(!engine.trackFadeoutActive() && engine.trackFadeoutGain(selected) == 1, "prepareSong retained transient fade state");
    require(song.tracks[0].volume == .7 && song.tracks[1].volume == .5, "Fade mutated saved faders");
    bool rejected = false; try { engine.startTrackFadeout({selected}, .5); } catch (...) { rejected = true; }
    require(rejected, "Invalid fade duration was accepted");
    engine.startTrackFadeout({"missing"}, 1); require(!engine.trackFadeoutActive(), "Unknown track started a fade");

    // Exercise the actual Master effects: they intentionally keep processing
    // after a source stops, so muting the selected buses alone is insufficient.
    for (const String kind : {String("Reverb"), String("Delay")}) {
        auto masterProject = project;
        auto masterSong = song;
        for (auto &track : masterSong.tracks)
            track.outputs = std::vector<jaras::OutputPatch>{{0, 2}};
        masterProject.songs[0] = masterSong;
        auto settings = object();
        put(settings, "inserted", Array<var>{kind});
        put(settings, "reverbEnabled", true); put(settings, "reverbMix", 80);
        put(settings, "reverbDecay", 10.0); put(settings, "reverbRoom", 1.0);
        put(settings, "delayEnabled", true); put(settings, "delayMix", 80);
        put(settings, "delayTime", .2); put(settings, "feedback", 75.0);
        masterProject.masterFXJSON = utf8(JSON::toString(settings, true));
        engine.prepareSong(masterSong, folder, settings, &masterProject);
        engine.setOffline(true);
        engine.setMixer(masterProject, masterSong);
        state.playing = true; state.position = 0; engine.transport(state);
        engine.startTrackFadeout({selected, other}, 1);
        for (int frame = 0; frame < 48000; frame += 257)
            render(std::min(257, 48000 - frame));
        require(engine.trackFadeoutComplete(), "Master-tail fixture did not complete fade");
        render(512);
        require(output.getMagnitude(0, 0, 512) > .000001f,
                kind + " fixture has no tail to exercise the stopped-output guard");
        state.playing = false; engine.transport(state);
        for (int block = 0; block < 5; ++block) {
            render(1024);
            require(output.getMagnitude(0, 1024) == 0,
                    kind + " Master tail escaped after completed Fadeout/Stop");
        }
        engine.cancelTrackFadeout();
        state.playing = true; state.position = 0; engine.transport(state);
        float resumed = 0;
        for (int block = 0; block < 8; ++block) {
            render(4096); resumed = std::max(resumed, output.getMagnitude(0, 4096));
        }
        require(engine.trackFadeoutGain(selected) == 1 && engine.trackFadeoutGain(other) == 1 && resumed > .01f,
                kind + " next Play did not restore the original fader gains/audio");
    }
}
template <typename Register>
void registerTests(const File &directory, Register &&test) {
    test("Transport fadeout cancel/restart rejects stale callbacks", [] { staleCallback(); });
    test("Transport fadeout is sample accurate, transient and restores faders", [&] { audio(directory); });
}
} // namespace catlive::transportFadeoutTests
