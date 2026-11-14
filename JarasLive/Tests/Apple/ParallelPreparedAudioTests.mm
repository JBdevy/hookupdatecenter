#include "../../Apple/Bridge/JarasEffects.mm"
#include <cassert>
#include <iostream>

int main() {
    @autoreleasepool {
        setenv("CATLIVE_PARALLEL_STRETCH", "1", 1);
        for (double sourceRate : {44100., 48000.}) {
            auto url = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:
                [@"catlive-parallel-" stringByAppendingFormat:@"%@.wav", NSUUID.UUID.UUIDString]];
            auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sourceRate channels:2];
            auto pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:480000];
            pcm.frameLength = pcm.frameCapacity;
            for (unsigned n = 0; n < pcm.frameLength; ++n) for (int ch = 0; ch < 2; ++ch)
                pcm.floatChannelData[ch][n] = .1f * std::sin(n * (ch ? .071 : .057)) + .03f * std::sin(n * n * .00000017);
            NSError *error = nil;
            auto file = [[AVAudioFile alloc] initForWriting:url settings:format.settings error:&error];
            assert(file && [file writeFromBuffer:pcm error:&error]); file = nil;
            auto reader = PreparedPCMReader::open(url, &error);
            auto make = [&] {
                auto kernel = std::make_shared<PreparedClipKernel>(sourceRate, 2);
                // Separate histories, as with different source files; no source
                // processing can be shared between these test voices.
                kernel->cache = std::make_shared<PreparedPCMCache>(std::make_shared<PreparedPCMReader>(reader->file));
                kernel->cache->requested.store(0);
                assert(kernel->cache->prefetch(16, &error) == PreparedPCMCache::Prefetch::ready);
                kernel->endFrame.store(480000); kernel->configureStretchGroup();
                assert(kernel->prime(0, 1.12, 0)); kernel->rate.store(1.12); kernel->playback.start();
                return kernel;
            };
            PreparedRenderSources coordinator;
            std::vector<std::shared_ptr<PreparedClipKernel>> actual, references;
            for (int n = 0; n < 12; ++n) {
                actual.push_back(make()); references.push_back(make()); coordinator.add(actual.back());
            }
            auto render = [&](PreparedClipKernel &kernel, int frames) {
                auto out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];
                out.frameLength = frames;
                AudioTimeStamp time{};
                assert(kernel.render(&time, frames, out.mutableAudioBufferList) == noErr);
                return std::vector<float>(out.floatChannelData[0], out.floatChannelData[0] + frames);
            };
            double maximumError = 0;
            for (int block = 0; block < 60; ++block) {
                for (size_t n = 0; n < actual.size(); ++n) {
                    const double rate = 1.12 + ((block + n) % 13) * .007;
                    const double tuning = block % 19 == 0 ? 2 : 0;
                    for (auto *kernel : {actual[n].get(), references[n].get()}) {
                        kernel->rate.store(rate); kernel->semitones.store(tuning);
                    }
                }
                jaras::realtimeClock = {1, double(block * 2048), 48000, 1e9};
                coordinator.prepare(2048);
                jaras::realtimeClock = {};
                for (size_t n = 0; n < actual.size(); ++n) {
                    // A rate converter consumes its guaranteed prefix and
                    // sometimes one additional frame on this pull.
                    const int frames = sourceRate == 48000 ? 2048 : 1881 + (block + n) % 2;
                    const auto expected = render(*references[n], frames), result = render(*actual[n], frames);
                    for (size_t sample = 0; sample < result.size(); ++sample)
                        maximumError = std::max(maximumError, double(std::abs(result[sample] - expected[sample])));
                    assert(maximumError < 2e-6);
                    assert(std::abs(actual[n]->source - references[n]->source) < 1e-6);
                    assert(actual[n]->misses.load() == 0);
                }
                coordinator.finish();
            }
            // A disconnected/gated graph need not pull every scheduled source.
            // Ending that render must still release every preparation gate.
            jaras::realtimeClock = {1, 200000, 48000, 1e9};
            coordinator.prepare(2048); coordinator.finish(); coordinator.finish();
            jaras::realtimeClock = {};
            for (auto &kernel : actual) {
                kernel->playback.stop(); kernel->playback.waitStopped();
                coordinator.remove(kernel.get());
            }
            actual.clear(); references.clear(); reader.reset();
            [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
            std::cout << "PARALLEL_DISTINCT_TEMPO_PITCH_PCM_OK rate=" << sourceRate << " error=" << maximumError << '\n';
        }
    }
}
