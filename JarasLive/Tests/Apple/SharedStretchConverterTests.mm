#include "../../Apple/Bridge/JarasEffects.mm"
#include <cassert>
#include <iostream>

// A 44.1/48 kHz converter can request one fewer sample from a reused
// voice, then catch up on the next pull. Copies must share that same stream,
// including a tempo edit between the prefix and suffix of a cached block.
int main() {
    @autoreleasepool {
        auto url = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:
            [@"catlive-converter-sharing-" stringByAppendingFormat:@"%@.wav", NSUUID.UUID.UUIDString]];
        auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
        auto pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:441000];
        pcm.frameLength = pcm.frameCapacity;
        for (unsigned n = 0; n < pcm.frameLength; ++n) for (int ch = 0; ch < 2; ++ch)
            pcm.floatChannelData[ch][n] = .1f * std::sin(n * (ch ? .071 : .057)) + .03f * std::sin(n * n * .00000017);
        NSError *error = nil;
        auto file = [[AVAudioFile alloc] initForWriting:url settings:format.settings error:&error];
        assert(file && [file writeFromBuffer:pcm error:&error]); file = nil;
        auto reader = PreparedPCMReader::open(url, &error);
        auto timing = std::make_shared<PreparedTimingState>();
        auto make = [&](bool shared) {
            auto kernel = std::make_unique<PreparedClipKernel>(44100, 2);
            kernel->cache = std::make_shared<PreparedPCMCache>(shared ? reader : std::make_shared<PreparedPCMReader>(reader->file));
            kernel->cache->requested.store(0);
            assert(kernel->cache->prefetch(16, &error) == PreparedPCMCache::Prefetch::ready);
            kernel->endFrame.store(441000); kernel->configureStretchGroup();
            assert(kernel->prime(0, 1.12, 0));
            kernel->rate.store(1.12); kernel->timingRun.store(1);
            if (shared) kernel->timing = timing;
            kernel->playback.start();
            return kernel;
        };
        auto a = make(true), b = make(true), reference = make(false);
        auto render = [](PreparedClipKernel &kernel, int frames) {
            auto out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:
                [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2] frameCapacity:frames];
            out.frameLength = frames;
            AudioTimeStamp time{}; // Deliberately independent converter counters.
            assert(kernel.render(&time, frames, out.mutableAudioBufferList) == noErr);
            return std::vector<float>(out.floatChannelData[0], out.floatChannelData[0] + frames);
        };
        auto controls = [&](double rate, double pitch) {
            timing->beginUpdates();
            for (auto *kernel : {a.get(), b.get()}) timing->set(kernel->timingID, {1, rate, pitch});
            timing->endUpdates(); reference->rate.store(rate); reference->semitones.store(pitch);
        };
        std::vector<float> canonical;
        size_t consumed = 0;
        float maximumError = 0;
        for (int block = 0; block < 80; ++block) {
            controls(1.12 + (block % 13) * .007, block % 19 == 0 ? 2 : 0);
            timing->beginRender();
            const int first = block % 2 == 0 ? 1882 : 1881;
            const int second = block % 2 == 0 ? 1881 : 1882;
            auto expected = render(*reference, first), actual = render(*a, first);
            canonical.insert(canonical.end(), expected.begin(), expected.end());
            auto copied = render(*b, second);
            timing->endRender();
            for (size_t n = 0; n < actual.size(); ++n) assert(std::abs(actual[n] - expected[n]) < 2e-6);
            for (size_t n = 0; n < copied.size(); ++n) {
                const auto difference = std::abs(copied[n] - canonical[consumed + n]);
                maximumError = std::max(maximumError, difference);
                assert(difference < 2e-6);
            }
            consumed += copied.size();
            if (block % 2) {
                assert(a->source == b->source);
                assert(a->stretch.handle() == b->stretch.handle());
            }
        }
        // An item-only edit must fork at the consumed prefix, never inherit
        // another track's remaining samples or its controls.
        a = make(true); b = make(true); reference = make(false);
        controls(1.12, 0); timing->beginRender();
        render(*a, 2000); auto prefix = render(*b, 1990); auto expectedPrefix = render(*reference, 1990);
        timing->endRender();
        for (size_t n = 0; n < prefix.size(); ++n) assert(std::abs(prefix[n] - expectedPrefix[n]) < 2e-6);
        timing->set(b->timingID, {1, .85, 7}); reference->rate.store(.85); reference->semitones.store(7);
        timing->beginRender();
        auto privateAudio = render(*b, 2000), privateReference = render(*reference, 2000);
        timing->endRender();
        for (size_t n = 0; n < privateAudio.size(); ++n) assert(std::abs(privateAudio[n] - privateReference[n]) < 2e-6);
        assert(b->source == reference->source && a->stretch.handle() != b->stretch.handle());
        assert(a->misses.load() == 0 && b->misses.load() == 0 && reference->misses.load() == 0);
        a.reset(); b.reset(); reference.reset(); reader.reset();
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        std::cout << "SHARED_CONVERTER_PREFIX_SUFFIX_TEMPO_PCM_PRIVATE_EDIT_OK error=" << maximumError << '\n';
    }
}
