#import "JarasEffects.h"
#import "JarasTimecode.h"
#include "JarasRealtimeClock.hpp"
#include <cassert>
#include <cmath>
#include <vector>

int main() { @autoreleasepool {
    mach_timebase_info_data_t base; mach_timebase_info(&base);
    const double ticks = 1e9 * base.denom / base.numer;
    for (double rate : {44100., 48000.}) {
        auto engine = [AVAudioEngine new];
        auto driver = [[JarasMobileAudioOutput alloc] initWithEngine:engine];
        NSError *error = nil;
        for (unsigned channels : {6u, 2u, 18u, 32u, 6u}) {
            auto format = [driver configureWithSampleRate:rate channels:channels error:&error];
            assert(format && !error && engine.isInManualRenderingMode);
            auto stereo = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
            auto player = [AVAudioPlayerNode new];
            auto controls = [JarasEqualizer makeNode];
            auto router = [JarasChannelRouter makeNode];
            [engine attachNode:player]; [engine attachNode:controls]; [engine attachNode:router];
            [engine connect:player to:controls format:stereo];
            [engine connect:controls to:router format:stereo];
            [engine connect:router to:engine.mainMixerNode format:format];
            [JarasChannelRouter configure:router first:channels > 2 ? channels - 1 : 1 count:2];
            assert([JarasAudioOutputConnection connectEngine:engine error:&error] && !error);
            auto source = [[AVAudioPCMBuffer alloc] initWithPCMFormat:stereo frameCapacity:512];
            source.frameLength = 512;
            for (unsigned n = 0; n < 512; ++n) { source.floatChannelData[0][n] = .1; source.floatChannelData[1][n] = .2; }
            [player scheduleBuffer:source atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
            assert([engine startAndReturnError:&error]);
            assert([driver startAndReturnError:&error]);
            [player play];
            auto output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:512];
            output.frameLength = 512;
            const auto epoch = mach_absolute_time();
            for (unsigned block = 0; block < 30; ++block) {
                AudioTimeStamp time = {};
                time.mHostTime = epoch + uint64_t(block * 512 / rate * ticks);
                time.mSampleTime = block * 512;
                time.mFlags = kAudioTimeStampHostTimeValid | kAudioTimeStampSampleTimeValid;
                AudioUnitRenderActionFlags flags = 0;
                assert([driver renderFrames:512 time:&time flags:&flags buffers:output.mutableAudioBufferList] == noErr);
                if (block > 2) for (unsigned ch = 0; ch < channels; ++ch) {
                    const unsigned first = channels > 2 ? channels - 2 : 0;
                    const float expected = ch == first ? .1 : ch == first + 1 ? .2 : 0;
                    if (std::abs(static_cast<float *>(output.mutableAudioBufferList->mBuffers[ch].mData)[128] - expected) >= .00001) { fprintf(stderr, "PCM rate=%g channels=%u block=%u ch=%u actual=%g expected=%g\n", rate, channels, block, ch, static_cast<float *>(output.mutableAudioBufferList->mBuffers[ch].mData)[128], expected); abort(); }
                }
            }
            auto clock = driver.renderTime;
            assert(clock.isSampleTimeValid && clock.isHostTimeValid && clock.sampleTime == 30 * 512);
            assert(std::abs(double(clock.hostTime - epoch) / ticks - 30 * 512 / rate) < 1e-6);
            // Preserve the physical timestamp inside sample-clock-only native
            // processors, including their render-ahead offset and fades.
            AudioTimeStamp sampleOnly = {}; sampleOnly.mSampleTime = 1100;
            sampleOnly.mFlags = kAudioTimeStampSampleTimeValid;
            jaras::realtimeClock = {epoch, 1000, rate, ticks};
            auto physical = jaras::physicalRenderTime(sampleOnly, rate);
            assert(physical.mFlags & kAudioTimeStampHostTimeValid);
            assert(std::abs(double(physical.mHostTime - epoch) / ticks - 100 / rate) < 1e-6);
            jaras::realtimeClock = {};
            // Gate immediately, before touching the output unit or graph.
            [driver gate];
            AudioTimeStamp time = {}; AudioUnitRenderActionFlags flags = 0;
            assert([driver renderFrames:512 time:&time flags:&flags buffers:output.mutableAudioBufferList] == noErr);
            assert(flags & kAudioUnitRenderAction_OutputIsSilence);
            for (unsigned ch = 0; ch < channels; ++ch) for (unsigned f = 0; f < 512; ++f) assert(static_cast<float *>(output.mutableAudioBufferList->mBuffers[ch].mData)[f] == 0);
            [driver stop]; [engine stop]; [player stop];
            [engine detachNode:player]; [engine detachNode:controls]; [engine detachNode:router];
            printf("MOBILE_DRIVER_PCM_DISCRETE_CHANNELS_CLOCK_GATE_RECONNECT_OK rate=%.0f channels=%u\n", rate, channels);
        }
        auto format = [driver configureWithSampleRate:rate channels:2 error:&error];
        auto click = [[JarasMetronomeGenerator alloc] initWithFormat:format];
        auto router = [JarasChannelRouter makeNode];
        [engine attachNode:click.node]; [engine attachNode:router];
        [engine connect:click.node to:router format:format];
        [engine connect:router to:engine.mainMixerNode format:format];
        [JarasChannelRouter configure:router first:1 count:2];
        assert([JarasAudioOutputConnection connectEngine:engine error:&error]);
        float pulse[32]; for (auto& value : pulse) value = .8;
        [click setClickSections:@[@{@"start":@0, @"end":@2, @"origin":@0, @"bpm":@120, @"beats":@4, @"unit":@4}]
                         sound:[NSData dataWithBytes:pulse length:sizeof(pulse)]];
        [click setEnabled:YES];
        const auto epoch = mach_absolute_time();
        [click configurePosition:0 hostTime:epoch + uint64_t(.05 * ticks) running:YES loopStart:0 loopEnd:.5 sampleTime:NAN];
        assert([engine startAndReturnError:&error]); assert([driver startAndReturnError:&error]);
        auto output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:128]; output.frameLength = 128;
        std::vector<unsigned> onsets; bool loud = false;
        for (unsigned first = 0; first < unsigned(rate * 1.2); first += 128) {
            AudioTimeStamp time = {}; time.mFlags = kAudioTimeStampHostTimeValid | kAudioTimeStampSampleTimeValid;
            time.mHostTime = epoch + uint64_t(first / rate * ticks); time.mSampleTime = first;
            AudioUnitRenderActionFlags flags = 0;
            assert([driver renderFrames:128 time:&time flags:&flags buffers:output.mutableAudioBufferList] == noErr);
            for (unsigned n = 0; n < 128; ++n) {
                bool next = std::abs(static_cast<float *>(output.mutableAudioBufferList->mBuffers[0].mData)[n]) > .001;
                if (next && !loud) onsets.push_back(first + n);
                loud = next;
            }
        }
        assert(onsets.size() == 3);
        for (unsigned n = 0; n < onsets.size(); ++n) {
            if (std::abs(double(onsets[n]) / rate - (.05 + .5 * n)) >= 8 / rate) { fprintf(stderr, "CLICK expected=%g actual=%g sample=%u rate=%g\n", .05+.5*n, double(onsets[n])/rate, onsets[n], rate); abort(); }
        }
        for (unsigned n = 1; n < onsets.size(); ++n)
            assert(std::abs(double(onsets[n] - onsets[n-1]) / rate - .5) < 2 / rate);
        [driver stop]; [engine stop];
        printf("MOBILE_PHYSICAL_HOST_CLOCK_CLICK_FIRST_BEAT_AND_LOOP_PCM_OK rate=%.0f\n", rate);
    }
} }
