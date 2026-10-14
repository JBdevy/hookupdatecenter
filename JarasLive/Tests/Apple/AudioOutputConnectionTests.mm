#import "JarasEffects.h"
#include "JarasOutputChannelMap.hpp"
#include <cassert>
#include <cmath>

static UInt32 expectedChannels = 0;
static OSStatus mapStatus = noErr;
static unsigned mapWrites = 0;
static OSStatus verifyOutputMap(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                               AudioUnitElement bus, const void *data, UInt32 bytes) {
    assert(unit && property == kAudioOutputUnitProperty_ChannelMap && scope == kAudioUnitScope_Global && bus == 0);
    assert(bytes == expectedChannels * sizeof(SInt32));
    const auto *mapping = static_cast<const SInt32 *>(data);
    for (UInt32 channel = 0; channel < expectedChannels; ++channel) assert(mapping[channel] == channel);
    ++mapWrites;
    return mapStatus;
}

// Simulates transient HAL results without changing a real device or system
// preference. Objective-C dispatch lets the exact production bridge exercise
// a device that loses its format or throws during connect.
@interface OutputFormatFixture : NSObject
@property double sampleRate;
@property AVAudioChannelCount channelCount;
@end
@implementation OutputFormatFixture
@end
@interface OutputNodeFixture : NSObject
@property double rate;
@property AVAudioChannelCount channels;
@property NSInteger reads;
@property BOOL disappearsAfterRead;
- (AVAudioFormat *)outputFormatForBus:(AVAudioNodeBus)bus;
@end
@implementation OutputNodeFixture
- (AVAudioFormat *)outputFormatForBus:(AVAudioNodeBus)bus {
    OutputFormatFixture *format = [OutputFormatFixture new];
    format.sampleRate = self.rate; format.channelCount = self.channels;
    self.reads += 1;
    if (self.disappearsAfterRead) { self.rate = 0; self.channels = 0; }
    return (AVAudioFormat *)format;
}
@end
@interface OutputEngineFixture : NSObject
@property OutputNodeFixture *outputNode;
@property AVAudioMixerNode *mainMixerNode;
@property AVAudioFormat *connectedFormat;
@property NSInteger connections;
@property BOOL failConnection;
@property BOOL isInManualRenderingMode;
@property AVAudioFormat *manualRenderingFormat;
@end
@implementation OutputEngineFixture
- (instancetype)init {
    if ((self = [super init])) {
        _outputNode = [OutputNodeFixture new];
        _outputNode.rate = 44100; _outputNode.channels = 2;
        _mainMixerNode = [AVAudioMixerNode new];
    }
    return self;
}
- (void)connect:(AVAudioNode *)source to:(AVAudioNode *)target format:(AVAudioFormat *)format {
    self.connections += 1;
    if (self.failConnection) {
        @throw [NSException exceptionWithName:@"com.apple.coreaudio.avfaudio"
            reason:@"Device disappeared between validation and connection" userInfo:nil];
    }
    self.connectedFormat = format;
}
@end

int main() {
    @autoreleasepool {
        for (UInt32 channels : {1u, 2u, 6u, 8u, 10u, 18u}) {
            expectedChannels = channels;
            assert(jaras::configureDiscreteOutputMap(reinterpret_cast<AudioUnit>(1), channels, verifyOutputMap) == noErr);
        }
        const unsigned writes = mapWrites;
        assert(jaras::configureDiscreteOutputMap(nullptr, 2, verifyOutputMap) != noErr);
        assert(jaras::configureDiscreteOutputMap(reinterpret_cast<AudioUnit>(1), 0, verifyOutputMap) != noErr);
        assert(jaras::configureDiscreteOutputMap(reinterpret_cast<AudioUnit>(1), 1025, verifyOutputMap) != noErr);
        assert(mapWrites == writes);
        mapStatus = kAudioUnitErr_InvalidPropertyValue;
        assert(jaras::configureDiscreteOutputMap(reinterpret_cast<AudioUnit>(1), expectedChannels, verifyOutputMap) == mapStatus);
        puts("REMOTEIO_OUTPUT_MAP_PRESERVES_EVERY_DISCRETE_CHANNEL_AND_REPORTS_FAILURE_OK");
        for (double rate : {44100.0, 48000.0, 96000.0}) {
            for (AVAudioChannelCount channels : {1u, 2u, 8u}) {
                OutputEngineFixture *engine = [OutputEngineFixture new];
                engine.outputNode.rate = rate; engine.outputNode.channels = channels;
                engine.outputNode.disappearsAfterRead = YES;
                NSError *error = nil;
                AVAudioFormat *format = [JarasAudioOutputConnection connectEngine:(AVAudioEngine *)engine error:&error];
                assert(format && !error && engine.connections == 1 && engine.outputNode.reads == 1);
                assert(format.sampleRate == rate && format.channelCount == channels);
                assert(engine.connectedFormat == format);
            }
        }
        puts("OUTPUT_GRAPH_USES_ONE_VALIDATED_FORMAT_SNAPSHOT_OK");
        for (double rate : {0.0, -1.0, double(NAN), double(INFINITY)}) {
            OutputEngineFixture *engine = [OutputEngineFixture new]; engine.outputNode.rate = rate;
            NSError *error = nil;
            assert(![JarasAudioOutputConnection connectEngine:(AVAudioEngine *)engine error:&error]);
            assert(error && engine.connections == 0);
        }
        OutputEngineFixture *noChannels = [OutputEngineFixture new]; noChannels.outputNode.channels = 0;
        NSError *error = nil;
        assert(![JarasAudioOutputConnection connectEngine:(AVAudioEngine *)noChannels error:&error]);
        assert(error && noChannels.connections == 0);
        puts("ZERO_CHANNELS_ZERO_NEGATIVE_NAN_INFINITE_RATE_NEVER_REACH_ENGINE_CONNECT_OK");
        OutputEngineFixture *vanished = [OutputEngineFixture new]; vanished.failConnection = YES;
        error = nil;
        assert(![JarasAudioOutputConnection connectEngine:(AVAudioEngine *)vanished error:&error]);
        assert(error.code == 2 && vanished.connections == 1);
        vanished.failConnection = NO;
        error = nil;
        assert([JarasAudioOutputConnection connectEngine:(AVAudioEngine *)vanished error:&error]);
        assert(!error && vanished.connections == 2);
        puts("HAL_EXCEPTION_STAYS_IN_OBJC_AND_SAME_ENGINE_RECOVERS_OK");
        AVAudioEngine *engine = [AVAudioEngine new];
        AVAudioFormat *manual = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        error = nil;
        assert([engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:manual maximumFrameCount:512 error:&error]);
        AVAudioFormat *connected = [JarasAudioOutputConnection connectEngine:engine error:&error];
        assert(connected && !error && connected.sampleRate == 48000 && connected.channelCount == 2);
        puts("REAL_OFFLINE_ENGINE_CONNECTION_OK");
    }
}
