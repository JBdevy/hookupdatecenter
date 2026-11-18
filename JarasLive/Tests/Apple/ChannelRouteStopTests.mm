#include "../../Apple/Bridge/JarasEffects.mm"
#include <cassert>
#include <iostream>
int main() {
    @autoreleasepool {
        for(double rate:{44100.,48000.,96000.}) {
            auto *node=[JarasChannelRouter makeNode];
            auto *unit=(JarasChannelRouteUnit *)node.AUAudioUnit;
            [JarasChannelRouter configurePatches:node firsts:@[@1] counts:@[@2] outputChannels:2];
            unit->route.prepare(512,2,rate);
            float samples[2][512]{};
            struct {UInt32 count;AudioBuffer buffers[2];} storage{2,{{1,sizeof(samples[0]),samples[0]},{1,sizeof(samples[1]),samples[1]}}};
            auto *output=reinterpret_cast<AudioBufferList *>(&storage);
            AudioTimeStamp time{};time.mFlags=kAudioTimeStampSampleTimeValid;
            AudioUnitRenderActionFlags flags=0;
            __block unsigned pulls=0;
            AURenderPullInputBlock input=^AUAudioUnitStatus(AudioUnitRenderActionFlags *,const AudioTimeStamp *,AVAudioFrameCount frames,NSInteger,AudioBufferList *buffers) {
                ++pulls;
                for(unsigned channel=0;channel<2;++channel)for(unsigned n=0;n<frames;++n)
                    static_cast<float *>(buffers->mBuffers[channel].mData)[n]=(n%2 ? .3f : -.3f)*(channel ? -1 : 1);
                return noErr;
            };
            auto render=unit.internalRenderBlock;
            for(unsigned i=0;i<12;++i)assert(render(&flags,&time,512,0,output,nullptr,input)==noErr);
            const auto before=pulls;
            [JarasChannelRouter beginStop:node];
            assert(render(&flags,&time,512,0,output,nullptr,input)==noErr);
            assert(pulls==before);
            double dc=0;
            for(unsigned n=0;n<512;++n){assert(std::isfinite(samples[0][n]));dc+=samples[0][n];if(n>=unit->route.stopFadeFrames)assert(samples[0][n]==0);}
            assert(std::abs(dc)<.31);
            // A slow source/FX cleanup spans many callbacks. Once the fade
            // finishes, the old graph must not be pulled again before release.
            for(unsigned block=0;block<12;++block) {
                assert(render(&flags,&time,512,0,output,nullptr,input)==noErr);
                assert(pulls==before);
                for(float sample:samples[0])assert(sample==0);
            }
            [JarasChannelRouter endStop:node];
            assert(render(&flags,&time,512,0,output,nullptr,input)==noErr);
            assert(pulls==before+1);
            [JarasChannelRouter setRenderEnabled:node enabled:NO];
            assert(render(&flags,&time,512,0,output,nullptr,input)==noErr);
            assert(render(&flags,&time,512,0,output,nullptr,input)==noErr);
            for(float sample:samples[0])assert(sample==0);
        }
        std::cout<<"CHANNEL_ROUTE_STOP_WAVEFORM_NO_HELD_SAMPLE_PULSE_AND_NO_SOURCE_PULL_OK\n";
    }
}