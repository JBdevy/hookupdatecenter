#include "../../Apple/Bridge/JarasEffects.mm"
#include <cassert>
#include <iostream>

int main() {
    @autoreleasepool {
        NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:
            [@"catlive-prepared-memory-" stringByAppendingFormat:@"%@.wav", NSUUID.UUID.UUIDString]];
        auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        auto pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:96000];
        pcm.frameLength = pcm.frameCapacity;
        for (unsigned n = 0; n < pcm.frameLength; ++n)
            for (int ch = 0; ch < 2; ++ch) pcm.floatChannelData[ch][n] = .1f * std::sin(n * .057);
        NSError *error = nil;
        auto file = [[AVAudioFile alloc] initForWriting:url settings:format.settings error:&error];
        assert(file && [file writeFromBuffer:pcm error:&error]); file = nil;
        auto reader = PreparedPCMReader::open(url, &error);
        auto make = [&] {
            auto kernel = std::make_unique<PreparedClipKernel>(48000, 2);
            kernel->cache = std::make_shared<PreparedPCMCache>(reader);
            assert(kernel->cache->prefetch(16) == PreparedPCMCache::Prefetch::ready);
            kernel->endFrame.store(96000); kernel->configureStretchGroup();
            assert(kernel->prime(0, 1, 0));
            return kernel;
        };
        auto active = make();
        assert([JarasPreparedClip memoryDiagnostics][@"stretchStates"].unsignedLongLongValue == 1);
        const auto primaryPCM = [JarasPreparedClip memoryDiagnostics][@"pcmBytes"].unsignedLongLongValue;
        // An independent source has exactly one history and advances in place.
        assert(!active->stretchGroup->pool.acquire());
        auto idle = make();
        assert([JarasPreparedClip memoryDiagnostics][@"stretchStates"].unsignedLongLongValue == 3);
        assert([JarasPreparedClip memoryDiagnostics][@"pcmBytes"].unsignedLongLongValue == primaryPCM);
        assert(active->stretch.handle() == idle->stretch.handle());
        std::vector<PreparedStretchGroup::Pool::Lease> spare;
        while (auto value = active->stretchGroup->pool.acquire()) spare.push_back(std::move(value));
        assert(spare.size() == 2); spare.clear();
        const auto idleSeed = idle->stretch.handle();
        // Leave the transition history pinned while the active voice branches
        // and changes tempo/pitch. No extra allocation is allowed by this pool.
        for (int block = 0; block < 60; ++block) {
            assert(active->processStretch(1 + (block % 5) * .01, block % 7 == 0 ? 2 : 0, 512));
            assert(idle->stretch.handle() == idleSeed);
        }
        auto next = make();
        assert(next->stretch.handle() == idleSeed);
        active.reset(); idle.reset(); next.reset(); reader.reset();
        assert([JarasPreparedClip memoryDiagnostics][@"caches"].unsignedLongLongValue == 0);
        assert([JarasPreparedClip memoryDiagnostics][@"readers"].unsignedLongLongValue == 0);
        assert([JarasPreparedClip memoryDiagnostics][@"stretchStates"].unsignedLongLongValue == 0);
        {
            auto &recent = PreparedPCMReader::recentBlocks();
            std::lock_guard<std::mutex> lock(recent.mutex);
            recent.blocks.clear(); recent.bytes = 0;
        }
        assert([JarasPreparedClip memoryDiagnostics][@"pcmBytes"].unsignedLongLongValue == 0);
        @autoreleasepool {
            auto first = [[JarasPreparedClip alloc] initWithFormat:format];
            auto transition = [[JarasPreparedClip alloc] initWithFormat:format];
            for (JarasPreparedClip *source in @[first, transition]) {
                assert([source prepareURL:url sourceFrame:0 endFrame:96000 rate:1 pitch:0 loopStart:0 loopEnd:0 error:&error]);
            }
            assert([JarasPreparedClip memoryDiagnostics][@"stretchStates"].unsignedLongLongValue == 2);
            [first startAtHostTime:0 ramp:NO];
            assert(first.playing);
            assert([JarasPreparedClip memoryDiagnostics][@"stretchStates"].unsignedLongLongValue == 2);
            // A real overlap receives its converter-fork history before the
            // second playback starts, rather than allocating on render.
            [transition startAtHostTime:0 ramp:NO];
            assert(transition.playing);
            assert([JarasPreparedClip memoryDiagnostics][@"stretchStates"].unsignedLongLongValue == 3);
            [first suspendStreaming]; [transition suspendStreaming];
            assert([JarasPreparedClip memoryDiagnostics][@"stretchStates"].unsignedLongLongValue == 0);
            assert([first prepareURL:url sourceFrame:512 endFrame:96000 rate:1 pitch:0 loopStart:0 loopEnd:0 error:&error]);
            auto engine = [[AVAudioEngine alloc] init];
            [engine attachNode:first.node];
            [engine connect:first.node to:engine.mainMixerNode format:format];
            assert([engine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime format:format maximumFrameCount:512 error:&error]);
            assert([engine startAndReturnError:&error]);
            auto output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:512];
            [first startAtHostTime:0 ramp:NO];
            for (int block = 0; block < 8; ++block) {
                output.frameLength = 512; OSStatus status = noErr;
                assert(engine.manualRenderingBlock(512, output.mutableAudioBufferList, &status) == AVAudioEngineManualRenderingStatusSuccess && status == noErr);
                for (int n = 0; n < 512; ++n)
                    assert(std::abs(output.floatChannelData[0][n] - pcm.floatChannelData[0][512 + block * 512 + n]) < 1e-6);
            }
            assert(first.underruns == 0);
            [first suspendStreaming]; [engine stop];
        }
        assert([JarasPreparedClip memoryDiagnostics][@"stretchStates"].unsignedLongLongValue == 0);
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        std::cout << "PREPARED_ONE_HISTORY_THREE_WITH_TRANSITION_TEMPO_PITCH_NO_STARVATION_OK\n";
        std::cout << "PREPARED_IDLE_TRANSITION_TWO_HISTORIES_THIRD_ONLY_BEFORE_OVERLAP_OK\n";
    }
}
