#pragma once
#include "AudioEngine.h"

namespace catlive::longTimelineAudioTests {
inline void require(bool value, const String &message) {
    if (!value) throw std::runtime_error(utf8(message));
}
inline int64 segments(const AudioEngine &engine) {
    return (int64)engine.callbackMetrics.snapshot()["renderSegments"];
}
template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Long timelines retain block-sized rendering, PCM and both playback clocks", [&] {
        const auto folder = directory.getNonexistentChildFile("long-timeline-audio", "");
        folder.createDirectory();
        auto stream = folder.getChildFile("source.wav").createOutputStream();
        WavAudioFormat format;
        std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(), 48000, 2, 32, {}, 0));
        require(writer != nullptr, "Cannot create long-timeline audio fixture");
        stream.release();
        AudioBuffer<float> pcm(2, 96000);
        for (int channel = 0; channel < 2; ++channel)
            for (int n = 0; n < pcm.getNumSamples(); ++n)
                pcm.setSample(channel, n, float(.08 * std::sin(n * (.017 + channel * .009)) +
                                               .04 * ((n % 97) / 96. - .5)));
        require(writer->writeFromAudioSampleBuffer(pcm, 0, pcm.getNumSamples()), "Cannot write long-timeline audio fixture");
        writer.reset();

        constexpr double anchor = 7745.076344;
        jaras::Project project; project.id = uuid();
        jaras::Song song; song.id = uuid(); song.duration = anchor + 10;
        jaras::Track track; track.id = uuid(); track.role.id = "other";
        jaras::AudioClip clip; clip.id = uuid(); clip.startTime = anchor; clip.duration = 2;
        clip.audioFile = jaras::AudioFile{"source.wav", {}};
        track.clips = {clip}; song.tracks = {track}; project.songs = {song};
        auto prepare = [&](double duration) {
            auto value = project; value.songs.front().duration = duration;
            auto engine = std::make_unique<AudioEngine>(48000, true);
            engine->prepareSong(value.songs.front(), folder, {}, &value);
            engine->setMixer(value, value.songs.front()); engine->setOffline(true);
            return engine;
        };
        // No onset, media, routing or current position changes between graphs.
        // Only the distant timeline end crosses the 32-bit sample-count limit.
        for (double duration : {56605.733581225104, 1.e15, std::numeric_limits<double>::infinity()}) {
            for (int mode = 0; mode < 3; ++mode) {
                auto reference = prepare(anchor + 10), actual = prepare(duration);
                AudioEngine::State initial; initial.playing = true; initial.position = anchor + .2;
                initial.subPlaying = mode == 1; initial.subPosition = anchor + .6;
                initial.loop = mode == 2; initial.loopStart = anchor + .1; initial.loopEnd = anchor + .205;
                reference->transport(initial); actual->transport(initial);
                AudioBuffer<float> expected(2, 480), output(2, 480);
                bool heardAudio = false, crossedLoop = false;
                for (int block = 0; block < 24; ++block) {
                    const auto before = segments(*actual);
                    reference->render(expected.getArrayOfWritePointers(), 2, 480);
                    actual->render(output.getArrayOfWritePointers(), 2, 480);
                    const auto count = segments(*actual) - before;
                    const String context = "duration " + String(duration) + ", mode " + String(mode) + ", block " + String(block);
                    require(count >= 1 && count <= (mode == 0 ? 1 : 2),
                            "Timeline rendering fragmented into " + String(count) + " segments: " + context);
                    if (mode == 2 && count == 2) crossedLoop = true;
                    for (int channel = 0; channel < 2; ++channel)
                        for (int n = 0; n < 480; ++n) {
                            heardAudio = heardAudio || std::abs(expected.getSample(channel, n)) > .001f;
                            require(std::abs(output.getSample(channel, n) - expected.getSample(channel, n)) < .000002f,
                                    "Long timeline changed PCM: " + context + ", sample " + String(n));
                        }
                    const auto a = actual->state(), b = reference->state();
                    require(a.playing == b.playing && a.subPlaying == b.subPlaying && a.playing &&
                            std::abs(a.position - b.position) < 1e-10 &&
                            std::abs(a.subPosition - b.subPosition) < 1e-10,
                            "Long timeline stopped or sought a playback clock: " + context);
                }
                require(heardAudio, "Long-timeline PCM fixture remained silent");
                require(mode != 2 || crossedLoop, "Long-timeline loop case did not cross its loop boundary");
            }
        }
    });
}
} // namespace catlive::longTimelineAudioTests
