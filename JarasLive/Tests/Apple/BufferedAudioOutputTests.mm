#include "../../Apple/Bridge/JarasEffects.mm"
#include <cassert>
#include <iostream>

int main() {
    @autoreleasepool {
        auto engine = [[AVAudioEngine alloc] init];
        auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        NSError *error = nil;
        assert([engine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime
            format:format maximumFrameCount:4096 error:&error]);
        auto pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:BufferedAudioState::maximumBlock];
        BufferedAudioState state(2,48000);
        __block int64_t written=0;
        auto expected=[](int64_t frame) { return .1f + float(frame%1024)/2048; };
        AVAudioEngineManualRenderingBlock render=^AVAudioEngineManualRenderingStatus(AVAudioFrameCount frames, AudioBufferList *out, OSStatus *status) {
            for(unsigned ch=0;ch<2;++ch) {
                auto *samples=static_cast<float *>(out->mBuffers[ch].mData);
                for(unsigned n=0;n<frames;++n) samples[n]=expected(written+n)*(ch ? -1 : 1);
            }
            written+=frames; *status=noErr;
            return AVAudioEngineManualRenderingStatusSuccess;
        };
        auto prepare=[&] { state.produce(engine,render,pcm); };
        auto output=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096];
        auto consume=[&](unsigned frames, bool silence=false) {
            const auto first=state.readFrame.load();
            AudioTimeStamp stamp{}; stamp.mFlags=kAudioTimeStampHostTimeValid;
            stamp.mHostTime=[AVAudioTime hostTimeForSeconds:10+double(first)/48000];
            assert(state.consume(&stamp,frames,output.mutableAudioBufferList)==noErr);
            for(unsigned ch=0;ch<2;++ch) for(unsigned n=0;n<frames;++n) {
                const auto value=output.floatChannelData[ch][n];
                const auto wanted=silence ? 0 : expected(first+n)*(ch ? -1 : 1);
                assert(std::isfinite(value) && std::abs(value-wanted)<1e-7f);
            }
        };
        // Different hardware block sizes, including unaligned boundaries,
        // must preserve every source frame across repeated ring wraparound.
        const unsigned blocks[]={128,512,480,64,1024,256,2048,192};
        for(unsigned step=0;step<4000;++step) {
            // Change producer size on the live ring, preserving the original
            // hardware clock and every sample through both transitions.
            if(step==1000) { state.setPlaybackSourceCount(610); assert(state.renderFrames==4096 && state.targetFrames()==12288); }
            if(step==3000) { state.setPlaybackSourceCount(120); assert(state.renderFrames==2048 && state.targetFrames()==4096); }
            while(state.writeFrame.load()-state.readFrame.load()<state.targetFrames()) prepare();
            consume(blocks[step%8]);
        }
        assert(state.underruns.load()==0);
        // Enter live monitoring with queued playback still audible. After draining it,
        // a live note must affect the very next device slice, including after a buffer
        // change or rate conversion. The PCM at the handoff must remain continuous.
        state.setLiveMonitoring(true);
        state.setPlaybackSourceCount(610);
        const auto originalQueue=state.writeFrame.load();
        for(unsigned cycle=0;cycle<300;++cycle) {
            const unsigned requests[]={512,32,128,480,137,256,50,1024};
            const auto frames=requests[cycle%8];
            const auto first=state.readFrame.load();
            AudioTimeStamp callback{}; callback.mFlags=kAudioTimeStampHostTimeValid;
            callback.mHostTime=[AVAudioTime hostTimeForSeconds:10+double(first)/48000];
            state.renderHardwareSlice(&callback,frames,engine,render,pcm);
            assert(state.writeFrame.load()==std::max(originalQueue,first+frames));
            consume(frames);
        }
        assert(state.underruns==0 && state.writeFrame.load()==state.readFrame.load());
        state.setLiveMonitoring(false);
        state.setPlaybackSourceCount(120);
        while(state.writeFrame.load()-state.readFrame.load()<state.targetFrames()) prepare();
        consume(512);
        assert(state.underruns==0);
        std::cout << "LIVE_INSTRUMENT_REAL_DEVICE_BUFFER_AND_CONTINUOUS_HANDOFF_OK\n";
        // Advance hardware through a stalled producer. Missing PCM is silent;
        // catching up must resume the original time instead of accumulating lag.
        while(state.readFrame.load()<state.writeFrame.load())
            consume(unsigned(std::min<int64_t>(4096,state.writeFrame.load()-state.readFrame.load())));
        for(unsigned n=0;n<10;++n) consume(4096,true);
        while(state.writeFrame.load()-state.readFrame.load()<state.targetFrames()) prepare();
        consume(512);
        assert(state.underruns.load()==10);
        auto stopFrame=state.readFrame.load();
        state.beginStop();
        AudioTimeStamp stamp{}; stamp.mFlags=kAudioTimeStampHostTimeValid;
        stamp.mHostTime=[AVAudioTime hostTimeForSeconds:10+double(stopFrame)/48000];
        assert(state.consume(&stamp,512,output.mutableAudioBufferList)==noErr);
        for(unsigned ch=0;ch<2;++ch) {
            for(unsigned n=0;n<512;++n) {
                const auto wanted=n<state.transitionLength ? expected(stopFrame+n)*(ch ? -1 : 1)*(1-float(n+1)/state.transitionLength) : 0;
                assert(std::abs(output.floatChannelData[ch][n]-wanted)<1e-7f);
            }
        }
        uint64_t host=0; int64_t frame=0;
        assert(state.hardwareClock.read(host,frame) && frame==stopFrame);
        const auto delta=[AVAudioTime secondsForHostTime:state.hostAt(frame+4800)-host];
        assert(std::abs(delta-.1)<1e-6);
        // The producer keeps running while the control side clears sources and
        // plugins. Nonzero intermediary graph output must never leak to hardware.
        for(unsigned cycle=0;cycle<12;++cycle) {
            while(state.writeFrame.load()-state.readFrame.load()<state.targetFrames())prepare();
            consume(512,true);
        }
        state.endStop();
        while(state.readFrame.load()<state.writeFrame.load())
            consume(unsigned(std::min<int64_t>(4096,state.writeFrame.load()-state.readFrame.load())),true);
        const auto restart=state.readFrame.load();
        written=restart;
        // The first post-cleanup pull drains any delayed route fade. It is not
        // fresh live audio yet, even though the cleanup hold has ended.
        prepare();consume(unsigned(state.renderFrames.load()),true);
        while(state.writeFrame.load()-state.readFrame.load()<state.targetFrames())prepare();
        consume(512);
        std::cout << "BUFFERED_OUTPUT_ADAPTIVE_QUANTUM_WRAP_UNDERRUN_RECOVERY_STOP_FADE_CLOCK_OK\n";
        std::cout << "BUFFERED_STOP_GATES_INTERMEDIATE_RESET_PCM_UNTIL_CLEAN_RESTART_OK\n";
        // Stop can begin and finish inside a single producer render. The
        // generation check must reject that mixed block after the hold expires.
        auto crossing=std::make_shared<BufferedAudioState>(2,48000);
        AVAudioEngineManualRenderingBlock crossingRender=^AVAudioEngineManualRenderingStatus(AVAudioFrameCount frames, AudioBufferList *out, OSStatus *status) {
            crossing->beginStop();
            for(unsigned ch=0;ch<2;++ch)std::fill_n(static_cast<float *>(out->mBuffers[ch].mData),frames,.9f);
            crossing->endStop();*status=noErr;
            return AVAudioEngineManualRenderingStatusSuccess;
        };
        crossing->produce(engine,crossingRender,pcm);
        assert(crossing->consume(&stamp,512,output.mutableAudioBufferList)==noErr);
        for(unsigned ch=0;ch<2;++ch)for(unsigned n=0;n<512;++n)assert(output.floatChannelData[ch][n]==0);
        std::cout << "BUFFERED_STOP_CROSSING_RENDER_REJECTS_MIXED_EPOCH_OK\n";

        // Read the real graph epoch from its render callback. Resetting the
        // engine and a rejected render must not invent an advancing timeline.
        auto clockEngine=[[AVAudioEngine alloc] init];
        assert([clockEngine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime
            format:format maximumFrameCount:4096 error:&error]);
        auto source=[[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
            ^OSStatus(BOOL *silent,const AudioTimeStamp *time,AVAudioFrameCount frames,AudioBufferList *out) {
                *silent=NO;
                for(unsigned ch=0;ch<out->mNumberBuffers;++ch)
                    std::fill_n(static_cast<float *>(out->mBuffers[ch].mData),frames,.1f);
                return noErr;
            }];
        [clockEngine attachNode:source];
        [clockEngine connect:source to:clockEngine.mainMixerNode format:format];
        [clockEngine connect:clockEngine.mainMixerNode to:clockEngine.outputNode format:format];
        auto clockState=std::make_shared<BufferedAudioState>(2,48000);
        auto unit=clockEngine.mainMixerNode.AUAudioUnit;
        auto token=[unit tokenByAddingRenderObserver:^(AudioUnitRenderActionFlags flags,
            const AudioTimeStamp *time,AVAudioFrameCount frames,NSInteger bus) {
            if(flags & kAudioUnitRenderAction_PreRender) clockState->observeGraphTime(time);
        }];
        assert([clockEngine startAndReturnError:&error]);
        pcm.frameLength=BufferedAudioState::block;
        auto graphRender=clockEngine.manualRenderingBlock;
        for(unsigned cycle=0;cycle<3;++cycle) {
            for(unsigned block=0;block<10;++block) {
                clockState->produce(clockEngine,graphRender,pcm);
                assert(clockState->failures.load()==cycle);
                assert(clockState->observedGraphTime);
                assert(clockState->graphSample==clockEngine.manualRenderingSampleTime);
            }
            const auto previous=clockState->graphSample;
            AVAudioEngineManualRenderingBlock rejected=^AVAudioEngineManualRenderingStatus(
                AVAudioFrameCount frames,AudioBufferList *out,OSStatus *status) {
                *status=noErr;
                return AVAudioEngineManualRenderingStatusCannotDoInCurrentContext;
            };
            clockState->produce(clockEngine,rejected,pcm);
            assert(clockState->graphSample==previous);
            [clockEngine reset];
            assert(clockEngine.manualRenderingSampleTime==0);
        }
        [clockEngine stop]; [unit removeRenderObserver:token];
        std::cout << "BUFFERED_OUTPUT_GRAPH_CLOCK_RESET_REJECTED_RENDER_OK\n";
    }
}
