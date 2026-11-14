// Included by JarasEffects.mm. Device selection remains owned by the existing
// hardware engine. The render graph and its preallocated PCM ring are separate.
#include <mach/mach.h>
#include <pthread.h>
#include <thread>

namespace {
struct BufferedRenderClock {
    std::atomic<uint64_t> sequence{0}, host{0};
    std::atomic<int64_t> sample{0};
    void publish(uint64_t h, int64_t s) {
        sequence.fetch_add(1, std::memory_order_acq_rel);
        host.store(h, std::memory_order_relaxed); sample.store(s, std::memory_order_relaxed);
        sequence.fetch_add(1, std::memory_order_release);
    }
    bool read(uint64_t &h, int64_t &s) const {
        for (unsigned attempt=0; attempt<3; ++attempt) {
            const auto before=sequence.load(std::memory_order_acquire);
            if (before & 1) continue;
            h=host.load(std::memory_order_relaxed); s=sample.load(std::memory_order_relaxed);
            if (before==sequence.load(std::memory_order_acquire)) return h!=0;
        }
        return false;
    }
};
struct BufferedAudioState {
#ifndef CATLIVE_BUFFERED_BLOCK_FRAMES
#define CATLIVE_BUFFERED_BLOCK_FRAMES 2048
#endif
#ifndef CATLIVE_BUFFERED_AHEAD_BLOCKS
#define CATLIVE_BUFFERED_AHEAD_BLOCKS 2
#endif
    static constexpr int64_t capacity=32768, block=CATLIVE_BUFFERED_BLOCK_FRAMES,
        target=block*CATLIVE_BUFFERED_AHEAD_BLOCKS, stampFrames=64;
    static_assert(block>0 && block<=4096 && block%stampFrames==0);
    static_assert(target>=block && target+block<=capacity);
    const unsigned channels;
    const double rate, ticksPerSecond;
    std::vector<float> pcm, lastOutput, transitionOrigin;
    std::array<uint64_t, capacity/stampFrames> stamps{};
    std::atomic<int64_t> readFrame{0}, writeFrame{0};
    std::atomic<uint64_t> generation{1};
    uint64_t audibleGeneration=1;
    unsigned transitionFrame=0, transitionLength;
    std::atomic<bool> enabled{false};
    std::atomic<uint64_t> callbacks{0}, underruns{0}, failures{0}, renders{0}, renderTicks{0}, maxRenderTicks{0};
    std::atomic<unsigned> callbackFrames{0};
    BufferedRenderClock hardwareClock, graphClock;
    uint64_t fallbackHost=0;
    // Owned by the graph producer. AVAudioEngine's sample-time getter takes
    // its control lock, so it must not be queried between realtime renders.
    // The output render observer supplies the actual epoch, including resets.
    int64_t graphSample=0;
    bool observedGraphTime=false;
    semaphore_t wake=SEMAPHORE_NULL;
    BufferedAudioState(unsigned ch,double sr) : channels(ch),rate(sr),ticksPerSecond([] {
        mach_timebase_info_data_t base; mach_timebase_info(&base);
        return 1e9*double(base.denom)/base.numer;
    }()),pcm(capacity*ch),lastOutput(ch),transitionOrigin(ch),transitionLength(std::max(1u,unsigned(sr*.005))) {
        transitionFrame=transitionLength;
        semaphore_create(mach_task_self(),&wake,SYNC_POLICY_FIFO,0);
    }
    ~BufferedAudioState() { if(wake!=SEMAPHORE_NULL) semaphore_destroy(mach_task_self(),wake); }
    void observeGraphTime(const AudioTimeStamp *time) {
        if (!(time->mFlags & kAudioTimeStampSampleTimeValid)) return;
        graphSample=int64_t(time->mSampleTime);
        observedGraphTime=true;
        jaras::realtimeClock.sample=time->mSampleTime;
    }
    uint64_t hostAt(int64_t frame) const {
        uint64_t host=0; int64_t sample=0;
        if(!hardwareClock.read(host,sample)) { host=fallbackHost; sample=0; }
        const double value=double(host)+(frame-sample)/rate*ticksPerSecond;
        return uint64_t(std::max(0.,value));
    }
    OSStatus consume(const AudioTimeStamp *time,unsigned frames,AudioBufferList *output) {
        const auto first=readFrame.load(std::memory_order_relaxed);
        const auto host=(time->mFlags & kAudioTimeStampHostTimeValid) ? time->mHostTime : mach_absolute_time();
        hardwareClock.publish(host,first);
        ++callbacks; callbackFrames.store(frames,std::memory_order_relaxed);
        const auto published=writeFrame.load(std::memory_order_acquire);
        const auto available=unsigned(std::clamp<int64_t>(published-first,0,frames));
        if(available<frames) ++underruns;
        const auto currentGeneration=generation.load(std::memory_order_acquire);
        if(currentGeneration!=audibleGeneration) {
            audibleGeneration=currentGeneration;
            std::copy(lastOutput.begin(),lastOutput.end(),transitionOrigin.begin()); transitionFrame=0;
        }
        for(unsigned ch=0;ch<output->mNumberBuffers && ch<channels;++ch) {
            auto &buffer=output->mBuffers[ch]; auto *data=static_cast<float *>(buffer.mData);
            if(!data) continue;
            for(unsigned n=0;n<frames;++n) {
                const auto index=(first+n)%capacity;
                float value=n<available && stamps[index/stampFrames]==currentGeneration ? pcm[ch*capacity+index] : 0;
                if(transitionFrame+n<transitionLength) {
                    const float amount=float(transitionFrame+n+1)/transitionLength;
                    value=transitionOrigin[ch]+(value-transitionOrigin[ch])*amount;
                }
                data[n]=value;
            }
            if(frames) lastOutput[ch]=data[frames-1];
            buffer.mDataByteSize=frames*sizeof(float);
        }
        transitionFrame=std::min(transitionLength,transitionFrame+frames);
        // A missed deadline is silence at its original time, never a growing
        // delay. The producer renders/catches up, discarding already missed PCM.
        readFrame.store(first+frames,std::memory_order_release);
        semaphore_signal(wake);
        return noErr;
    }
    void produce(AVAudioEngine *engine, AVAudioEngineManualRenderingBlock render, AVAudioPCMBuffer *buffer) {
        const auto first=writeFrame.load(std::memory_order_relaxed);
        const auto stamp=generation.load(std::memory_order_acquire);
        const auto host=hostAt(first);
        const auto sample=graphSample;
        observedGraphTime=false;
        const auto previous=jaras::realtimeClock;
        jaras::realtimeClock={host,double(sample),rate,ticksPerSecond};
        const auto began=mach_absolute_time();
        OSStatus error=noErr;
        const auto result=render(block,buffer.mutableAudioBufferList,&error);
        const auto duration=mach_absolute_time()-began;
        jaras::realtimeClock=previous;
        ++renders; renderTicks.fetch_add(duration,std::memory_order_relaxed);
        maxRenderTicks.store(std::max(maxRenderTicks.load(std::memory_order_relaxed),duration),std::memory_order_relaxed);
        if(result!=AVAudioEngineManualRenderingStatusSuccess || error!=noErr) ++failures;
        const auto offset=first%capacity;
        const auto initial=std::min<int64_t>(block,capacity-offset);
        for(unsigned ch=0;ch<channels;++ch) {
            auto *destination=pcm.data()+ch*capacity;
            const auto *source=buffer.floatChannelData[ch];
            if(result==AVAudioEngineManualRenderingStatusSuccess && error==noErr) {
                std::copy_n(source,initial,destination+offset);
                if(initial<block) std::copy_n(source+initial,block-initial,destination);
            } else {
                std::fill_n(destination+offset,initial,0.f);
                if(initial<block) std::fill_n(destination,block-initial,0.f);
            }
        }
        for(int64_t n=0;n<block;n+=stampFrames) stamps[((first+n)%capacity)/stampFrames]=stamp;
        if (result==AVAudioEngineManualRenderingStatusSuccess ||
            result==AVAudioEngineManualRenderingStatusInsufficientDataFromInputNode) {
            const auto rendered=buffer.mutableAudioBufferList->mBuffers[0].mDataByteSize/sizeof(float);
            graphSample=(observedGraphTime ? graphSample : sample)+rendered;
        }
        graphClock.publish(host+uint64_t(block/rate*ticksPerSecond),graphSample);
        writeFrame.store(first+block,std::memory_order_release);
    }
};
}
@implementation JarasBufferedAudioOutput {
    AVAudioEngine *_engine,*_hardware;
    AVAudioSourceNode *_source;
    AVAudioPCMBuffer *_buffer;
    AVAudioEngineManualRenderingBlock _render;
    AUAudioUnit *_clockUnit;
    NSInteger _clockObserver;
    std::shared_ptr<BufferedAudioState> _state;
    std::thread _worker;
    BOOL _running;
    BOOL _outputEnabled;
}
- (instancetype)initWithEngine:(AVAudioEngine *)engine hardwareEngine:(AVAudioEngine *)hardware {
    if((self=[super init])) { _engine=engine; _hardware=hardware; }
    return self;
}
- (AVAudioEngine *)hardwareEngine { return _hardware; }
- (AVAudioFormat *)configureAndReturnError:(NSError **)error {
    const auto hardware=[_hardware.outputNode outputFormatForBus:0];
    const auto rate=hardware.sampleRate; const auto channels=hardware.channelCount;
    if(!std::isfinite(rate) || rate<=0 || !channels || channels>1024) {
        if(error) *error=[NSError errorWithDomain:@"CatLive.BufferedAudio" code:-50 userInfo:@{NSLocalizedDescriptionKey:@"Audio output is unavailable"}];
        return nil;
    }
    if(_state && _state->rate==rate && _state->channels==channels) return _engine.manualRenderingFormat;
    [self stop];
    if(_clockUnit) { [_clockUnit removeRenderObserver:_clockObserver]; _clockUnit=nil; }
    if(_source) [_hardware detachNode:_source];
    if(_engine.isRunning) [_engine stop];
    if(_engine.isInManualRenderingMode) [_engine disableManualRenderingMode];
    const auto layout=[[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_DiscreteInOrder | channels];
    const auto format=channels>2 ? [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channelLayout:layout]
        : [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels];
    if(![_engine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime format:format maximumFrameCount:4096 error:error]) return nil;
    _render=_engine.manualRenderingBlock;
    _state=std::make_shared<BufferedAudioState>(channels,rate);
    _buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:BufferedAudioState::block];
    auto state=_state;
    _clockUnit=_engine.mainMixerNode.AUAudioUnit;
    _clockObserver=[_clockUnit tokenByAddingRenderObserver:^(AudioUnitRenderActionFlags flags,
        const AudioTimeStamp *time, AVAudioFrameCount frames, NSInteger bus) {
        if(flags & kAudioUnitRenderAction_PreRender) state->observeGraphTime(time);
    }];
    _source=[[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *silent,const AudioTimeStamp *time,AVAudioFrameCount frames,AudioBufferList *output) {
        *silent=NO; return state->consume(time,frames,output);
    }];
    [_hardware attachNode:_source]; [_hardware connect:_source to:_hardware.mainMixerNode format:format];
    [_hardware connect:_hardware.mainMixerNode to:_hardware.outputNode format:format];
    return format;
}
- (BOOL)startAndReturnError:(NSError **)error {
    if(_running && _hardware.isRunning) return YES;
    if(!_state || !_engine.isRunning) {
        if(error) *error=[NSError errorWithDomain:@"CatLive.BufferedAudio" code:-50 userInfo:@{NSLocalizedDescriptionKey:@"Audio graph is unavailable"}];
        return NO;
    }
    [self stop];
    auto state=_state;
    state->readFrame.store(0); state->writeFrame.store(0);
    state->graphSample=_engine.manualRenderingSampleTime;
    state->hardwareClock.publish(0,0); state->graphClock.publish(0,0);
    state->fallbackHost=mach_absolute_time();
    state->lastOutput.assign(state->channels,0); state->transitionOrigin.assign(state->channels,0);
    state->transitionFrame=state->transitionLength;
    _buffer.frameLength=BufferedAudioState::block;
    while(state->writeFrame.load()<BufferedAudioState::target) state->produce(_engine,_render,_buffer);
    state->enabled.store(true,std::memory_order_release);
    auto render=_render; auto buffer=_buffer; auto engine=_engine;
    _worker=std::thread([state,render,buffer,engine] {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
        while(state->enabled.load(std::memory_order_acquire)) {
            if(state->writeFrame.load(std::memory_order_relaxed)-state->readFrame.load(std::memory_order_acquire)<BufferedAudioState::target)
                state->produce(engine,render,buffer);
            else { mach_timespec_t timeout{0,5'000'000}; semaphore_timedwait(state->wake,timeout); }
        }
    });
    // Licensing and transport gates remain in the render graph, before every
    // hardware channel. Device selection has already been validated by Swift.
    _hardware.mainMixerNode.outputVolume=_outputEnabled ? 1 : 0;
    if(![_hardware startAndReturnError:error]) { [self stop]; return NO; }
    _running=YES;
    return YES;
}
- (void)discardPreparedOutput { if(_state) _state->generation.fetch_add(1,std::memory_order_acq_rel); }
- (void)setOutputEnabled:(BOOL)enabled {
    _outputEnabled=enabled;
    _hardware.mainMixerNode.outputVolume=enabled ? 1 : 0;
}
- (void)stop {
    [_hardware stop];
    if(_state) { _state->enabled.store(false,std::memory_order_release); semaphore_signal(_state->wake); }
    if(_worker.joinable()) _worker.join();
    _running=NO;
}
- (AVAudioTime *)renderTime {
    if(!_state) return nil;
    uint64_t host; int64_t sample;
    if(!_state->graphClock.read(host,sample)) return nil;
    return [[AVAudioTime alloc] initWithHostTime:host sampleTime:sample atRate:_state->rate];
}
- (NSDictionary<NSString *,id> *)diagnostics {
    if(!_state) return @{};
    auto &s=*_state; const auto count=s.renders.load();
    return @{@"callbacks":@(s.callbacks.load()),@"callbackFrames":@(s.callbackFrames.load()),@"underruns":@(s.underruns.load()),
        @"renderFailures":@(s.failures.load()),@"renders":@(count),@"renderFrames":@(BufferedAudioState::block),
        @"meanRenderMs":@(count ? s.renderTicks.load()/s.ticksPerSecond*1000/count : 0),
        @"maxRenderMs":@(s.maxRenderTicks.load()/s.ticksPerSecond*1000),
        @"bufferedFrames":@(s.writeFrame.load()-s.readFrame.load())};
}
- (void)dealloc {
    [self stop];
    if(_clockUnit) [_clockUnit removeRenderObserver:_clockObserver];
    if(_source) [_hardware detachNode:_source];
}
@end
