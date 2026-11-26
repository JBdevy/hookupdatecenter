#import "../../../Apple/Bridge/JarasVST3.h"
#import <AudioToolbox/AudioToolbox.h>
#include <cassert>
#include <cmath>

int main() {
    @autoreleasepool {
        NSDictionary *plugin = nil;
        for (NSDictionary *candidate in JarasVST3.installedAudioUnits) {
            if ([candidate[@"classID"] isEqualToString:@"AU-61756678-68706173-6170706C"]) {
                plugin = candidate;
                break;
            }
        }
        assert(plugin);
        NSMutableDictionary *spec = [plugin mutableCopy];
        spec[@"id"] = @"highpass";
        AVAudioEngine *engine = [AVAudioEngine new];
        auto player = [AVAudioPlayerNode new];
        auto node = [JarasVST3 makeNode];
        auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        [engine attachNode:player];
        [engine attachNode:node];
        [engine connect:player to:node format:format];
        [engine connect:node to:engine.mainMixerNode format:format];
        NSError *error = nil;
        assert([engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:format maximumFrameCount:512 error:&error]);
        assert([JarasVST3 configure:node plugins:@[spec] error:&error]);
        assert([JarasVST3 isPluginLoaded:node identifier:@"highpass"]);
        NSArray *parameters = [JarasVST3 parameters:node identifier:@"highpass"];
        assert(parameters.count >= 1);
        [JarasVST3 setParameter:node identifier:@"highpass" parameter:0 value:.75];
        auto state = [JarasVST3 state:node identifier:@"highpass"];
        assert([state[@"componentState"] length]);
        spec[@"componentState"] = state[@"componentState"];
        assert([JarasVST3 configure:node plugins:@[] error:&error]);
        assert([JarasVST3 configure:node plugins:@[spec] error:&error]);
        auto restored = [JarasVST3 parameters:node identifier:@"highpass"];
        assert(std::abs([restored[0][@"value"] doubleValue] - .75) < .01);

        auto source = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096];
        source.frameLength = 4096;
        for (unsigned c = 0; c < 2; ++c)
            for (unsigned n = 0; n < source.frameLength; ++n)
                source.floatChannelData[c][n] = .4f;
        [player scheduleBuffer:source completionHandler:nil];
        assert([engine startAndReturnError:&error]);
        [player play];
        auto output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:512];
        for (unsigned block = 0; block < 7; ++block)
            assert([engine renderOffline:512 toBuffer:output error:&error] == AVAudioEngineManualRenderingStatusSuccess);
        for (unsigned c = 0; c < 2; ++c)
            for (unsigned n = 0; n < output.frameLength; ++n)
                assert(std::abs(output.floatChannelData[c][n]) < .01);
        [engine stop];
    }
    puts("Audio Unit discovery, state restoration, and offline processing passed");
}
