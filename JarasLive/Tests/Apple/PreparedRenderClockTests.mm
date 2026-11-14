// Compile the production render kernel to supply deterministic hardware times.
#include "../../Apple/Bridge/JarasEffects.mm"
#include <cassert>
#include <iostream>

int main() {
    @autoreleasepool {
        auto url = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:
            [@"catlive-render-clock-" stringByAppendingFormat:@"%@.wav", NSUUID.UUID.UUIDString]];
        auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        auto data = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:48000];
        data.frameLength = data.frameCapacity;
        for (unsigned n = 0; n < data.frameLength; ++n) {
            data.floatChannelData[0][n] = .25f * std::sin(n * .05759586531581287);
            data.floatChannelData[1][n] = -data.floatChannelData[0][n];
        }
        NSError *error = nil;
        auto writer = [[AVAudioFile alloc] initForWriting:url settings:format.settings error:&error];
        assert(writer && [writer writeFromBuffer:data error:&error]); writer = nil;
        {
            PreparedClipKernel kernel(48000, 2);
            kernel.cache = std::make_shared<PreparedPCMCache>(PreparedPCMReader::open(url, &error));
            assert(kernel.cache->prefetch(6, &error) == PreparedPCMCache::Prefetch::ready);
            kernel.endFrame.store(48000);
            kernel.configureStretchGroup();
            assert(kernel.prime(0, 1, 0));
            const uint64_t start = [AVAudioTime hostTimeForSeconds:10];
            kernel.startHost.store(start); kernel.dryClockHost = start; kernel.dryClockFrame = 0;
            kernel.playback.start();
            float left[128], right[128];
            struct Buffers { UInt32 count = 2; AudioBuffer buffers[2]; } buffers;
            buffers.buffers[0] = {1, sizeof(left), left}; buffers.buffers[1] = {1, sizeof(right), right};
            auto render = [&](int frame, int hostSkew = 0) {
                AudioTimeStamp time{};
                time.mFlags = kAudioTimeStampHostTimeValid | kAudioTimeStampSampleTimeValid;
                time.mHostTime = start + [AVAudioTime hostTimeForSeconds:double(frame + hostSkew)/48000];
                time.mSampleTime = frame;
                assert(kernel.render(&time, 128, reinterpret_cast<AudioBufferList *>(&buffers)) == noErr);
            };
            for (int frame : {0, 128, 896, 1024, 2560, 2688}) {
                render(frame);
                for (int n = 0; n < 128; ++n) {
                    assert(std::abs(left[n] - data.floatChannelData[0][frame + n]) < 1e-6f);
                    assert(left[n] == -right[n]);
                }
                assert(kernel.position.load() == frame + 128);
            }
            render(2816, 47);
            for (int n = 0; n < 128; ++n) {
                assert(std::abs(left[n] - data.floatChannelData[0][2816 + n]) < 1e-6f);
            }
            // Rate edits keep the already audible cursor continuous; they
            // must not extrapolate the new speed from the original Play time.
            const double before = kernel.position.load();
            kernel.rate.store(1.25);
            render(2944);
            assert(kernel.position.load() == before + 160);
            assert(kernel.misses.load() == 0);
            kernel.playback.stop(); kernel.playback.waitStopped();
        }
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        std::cout << "PREPARED_RENDER_CLOCK_SKIPPED_PULLS_PCM_RATE_CONTINUITY_OK\n";
    }
}
