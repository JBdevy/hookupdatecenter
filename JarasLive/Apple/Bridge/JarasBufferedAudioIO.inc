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
        maximumBlock=4096, target=block*CATLIVE_BUFFERED_AHEAD_BLOCKS, stampFrames=64;
    static_assert(block>0 && block<=4096 && block%stampFrames==0);
    static_assert(target>=block && target+block<=capacity);
    static_assert(maximumBlock*(CATLIVE_BUFFERED_AHEAD_BLOCKS+1)<=capacity);
    const unsigned channels;
    const double rate, ticksPerSecond;
    std::vector<float> pcm, lastOutput, transitionOrigin;
    // Hardware callbacks can request non-aligned frame counts during rate conversion.
    std::array<uint64_t, capacity> stamps{};
    std::atomic<bool> liveMonitoring{false};
    std::atomic_flag producing = ATOMIC_FLAG_INIT;
    std::atomic<int64_t> readFrame{0}, writeFrame{0};
    std::atomic<uint64_t> generation{1};
    std::atomic<bool> stopping{false};
    std::atomic<bool> discardPostStopRender{false};
    void beginStop() {
        stopping.store(true,std::memory_order_release);
        generation.fetch_add(1,std::memory_order_acq_rel);
    }
    void endStop() {
        // If cleanup was shorter than a producer interval, routers can still
        // own a pending fade of pre-Stop samples. Drain it behind the gate.
        discardPostStopRender.store(true,std::memory_order_release);
        stopping.store(false,std::memory_order_release);
    }
    uint64_t audibleGeneration=1;
    uint64_t transitionGeneration=1;
    unsigned transitionFrame=0, transitionLength;
    std::atomic<bool> enabled{false};
    std::atomic<uint64_t> callbacks{0}, underruns{0}, failures{0}, renders{0}, renderTicks{0}, maxRenderTicks{0};
    std::atomic<unsigned> callbackFrames{0};
    std::atomic<unsigned> renderFrames{block};
    std::atomic<unsigned> readAheadFrames{target};
    // A larger producer quantum amortizes the source graph's per-pull cost.
    // This is a buffering hint, never a voice/BPM limit or a hardware setting.
    void setPlaybackSourceCount(size_t count) {
        renderFrames.store(count>=256 ? maximumBlock : block,std::memory_order_release);
        readAheadFrames.store(count>=256 ? maximumBlock*3 : target,std::memory_order_release);
    }
    int64_t targetFrames() const {
        return readAheadFrames.load(std::memory_order_acquire);
    }
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
            transitionGeneration=audibleGeneration;
            audibleGeneration=currentGeneration;
            std::copy(lastOutput.begin(),lastOutput.end(),transitionOrigin.begin()); transitionFrame=0;
        }
        for(unsigned ch=0;ch<output->mNumberBuffers && ch<channels;++ch) {
            auto &buffer=output->mBuffers[ch]; auto *data=static_cast<float *>(buffer.mData);
            if(!data) continue;
            for(unsigned n=0;n<frames;++n) {
                const auto index=(first+n)%capacity;
                float value=n<available && stamps[index]==currentGeneration ? pcm[ch*capacity+index] : 0;
                if(transitionFrame+n<transitionLength) {
                    const float amount=float(transitionFrame+n+1)/transitionLength;
                    // Fade the actual queued waveform, not a held last sample.
                    // Holding one sample through Stop creates a DC pulse.
                    const bool hasTail=n<available && stamps[index]==transitionGeneration;
                    const float tail=hasTail ? pcm[ch*capacity+index] : transitionOrigin[ch]*(1-amount);
                    value=value*amount+tail*(1-amount);
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
        if (!liveMonitoring.load(std::memory_order_relaxed)) semaphore_signal(wake);
        return noErr;
    }
    void produce(AVAudioEngine *engine, AVAudioEngineManualRenderingBlock render, AVAudioPCMBuffer *buffer, unsigned frames) {
        const auto first=writeFrame.load(std::memory_order_relaxed);
        const auto stamp=generation.load(std::memory_order_acquire);
        const bool stoppingBefore=stopping.load(std::memory_order_acquire);
        const auto host=hostAt(first);
        const auto sample=graphSample;
        observedGraphTime=false;
        const auto previous=jaras::realtimeClock;
        jaras::realtimeClock={host,double(sample),rate,ticksPerSecond};
        const auto began=mach_absolute_time();
        OSStatus error=noErr;
        buffer.frameLength=frames;
        auto *buffers = buffer.mutableAudioBufferList;
        const auto result=render(frames,buffers,&error);
        const auto duration=mach_absolute_time()-began;
        jaras::realtimeClock=previous;
        ++renders; renderTicks.fetch_add(duration,std::memory_order_relaxed);
        maxRenderTicks.store(std::max(maxRenderTicks.load(std::memory_order_relaxed),duration),std::memory_order_relaxed);
        if(result!=AVAudioEngineManualRenderingStatusSuccess || error!=noErr) ++failures;
        const auto offset=first%capacity;
        const auto initial=std::min<int64_t>(frames,capacity-offset);
        // A reset may start/end while render holds a block. Never publish that
        // mixed epoch as fresh PCM, even if cleanup finished before this check.
        const bool clean=!stoppingBefore && !stopping.load(std::memory_order_acquire) &&
            stamp==generation.load(std::memory_order_acquire) &&
            !discardPostStopRender.exchange(false,std::memory_order_acq_rel);
        // A starved input may still return valid PCM from the other sources.
        // The ABL reports how many bytes each channel actually rendered.
        const bool hasPCM = error == noErr && (result == AVAudioEngineManualRenderingStatusSuccess ||
            result == AVAudioEngineManualRenderingStatusInsufficientDataFromInputNode);
        for (unsigned ch = 0; ch < channels; ++ch) {
            auto *destination = pcm.data() + ch * capacity;
            const auto &channel = buffers->mBuffers[ch];
            const float *source = static_cast<const float *>(channel.mData);
            const int64_t valid = clean && hasPCM && source
                ? std::min<int64_t>(frames, channel.mDataByteSize / sizeof(float)) : 0;
            auto write = [&](float *dest, int64_t start, int64_t count) {
                const auto copied = std::clamp<int64_t>(valid - start, 0, count);
                if (copied) std::copy_n(source + start, copied, dest);
                std::fill(dest + copied, dest + count, 0.f);
            };
            write(destination + offset, 0, initial);
            if (initial < frames) write(destination, initial, frames - initial);
        }
        std::fill_n(stamps.begin()+offset,initial,stamp);
        if(initial<frames) std::fill_n(stamps.begin(),frames-initial,stamp);
        if (hasPCM) {
            const auto rendered = std::min<unsigned>(frames, buffers->mBuffers[0].mDataByteSize / sizeof(float));
            graphSample=(observedGraphTime ? graphSample : sample)+rendered;
        }
        graphClock.publish(host+uint64_t(frames/rate*ticksPerSecond),graphSample);
        writeFrame.store(first+frames,std::memory_order_release);
    }
    void produce(AVAudioEngine *engine, AVAudioEngineManualRenderingBlock render, AVAudioPCMBuffer *buffer) {
        produce(engine,render,buffer,renderFrames.load(std::memory_order_acquire));
    }
    void setLiveMonitoring(bool live) {
        liveMonitoring.store(live,std::memory_order_release);
        semaphore_signal(wake);
    }
    void renderHardwareSlice(const AudioTimeStamp *time, unsigned frames, AVAudioEngine *engine,
                             AVAudioEngineManualRenderingBlock render, AVAudioPCMBuffer *buffer) {
        if(!liveMonitoring.load(std::memory_order_acquire)) return;
        const auto first=readFrame.load(std::memory_order_relaxed);
        const auto end=first+frames;
        if(writeFrame.load(std::memory_order_acquire)>=end) return;
        // Only the handoff from buffered playback can have a render in flight.
        // Never wait for that render in the hardware callback.
        if(producing.test_and_set(std::memory_order_acquire)) return;
        const auto host=(time->mFlags & kAudioTimeStampHostTimeValid) ? time->mHostTime : mach_absolute_time();
        hardwareClock.publish(host,first);
        if(writeFrame.load(std::memory_order_relaxed)<first)
            writeFrame.store(first,std::memory_order_relaxed);
        auto missing=end-writeFrame.load(std::memory_order_relaxed);
        while (missing>0) {
            const auto slice=unsigned(std::min(missing,maximumBlock));
            produce(engine,render,buffer,slice);
            missing-=slice;
        }
        producing.clear(std::memory_order_release);
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
    NSUInteger _playbackSourceCount;
    BOOL _liveInstrumentMonitoring;
    double _hardwareRate;
    AVAudioChannelCount _hardwareChannels;
    double _preferredProcessingSampleRate;
}
- (instancetype)initWithEngine:(AVAudioEngine *)engine hardwareEngine:(AVAudioEngine *)hardware {
    if((self=[super init])) { _engine=engine; _hardware=hardware; }
    return self;
}
- (AVAudioEngine *)hardwareEngine { return _hardware; }
- (double)configuredHardwareSampleRate { return _hardwareRate; }
- (AVAudioChannelCount)configuredHardwareChannels { return _hardwareChannels; }
- (double)preferredProcessingSampleRate { return _preferredProcessingSampleRate; }
- (void)setPreferredProcessingSampleRate:(double)rate { _preferredProcessingSampleRate=rate; }
- (void)clearConfiguration {
    if (_clockUnit) { [_clockUnit removeRenderObserver:_clockObserver]; _clockUnit = nil; }
    if (_source.engine) [_hardware detachNode:_source];
    _source = nil; _render = nil; _buffer = nil; _state.reset();
    _hardwareRate = 0; _hardwareChannels = 0;
}
- (AVAudioFormat *)configureAndReturnError:(NSError **)error {
    @try {
        return [self configureHardware:error];
    } @catch (NSException *exception) {
        // Hardware can disappear after validation but before AVFAudio connects it.
        [self stop];
        [self clearConfiguration];
        if (error) *error = [NSError errorWithDomain:@"CatLive.BufferedAudio" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"Audio output is unavailable",
                       NSDebugDescriptionErrorKey:exception.reason ?: exception.name}];
        return nil;
    }
}
- (AVAudioFormat *)configureHardware:(NSError **)error {
    const auto hardware=[_hardware.outputNode outputFormatForBus:0];
    const char *testRate=getenv("CATLIVE_GRAPH_SAMPLE_RATE");
    const auto requested=testRate ? atof(testRate) : (_preferredProcessingSampleRate>0 ? _preferredProcessingSampleRate : hardware.sampleRate);
    const auto rate=std::isfinite(requested) && requested>=8000 && requested<=192000 ? requested : hardware.sampleRate;
    const auto channels=hardware.channelCount;
    if(!std::isfinite(hardware.sampleRate) || hardware.sampleRate<=0 || !channels || channels>1024) {
        if(error) *error=[NSError errorWithDomain:@"CatLive.BufferedAudio" code:-50 userInfo:@{NSLocalizedDescriptionKey:@"Audio output is unavailable"}];
        return nil;
    }
    if(_state && _state->rate==rate && _state->channels==channels &&
       _hardwareRate==hardware.sampleRate && _hardwareChannels==channels) return _engine.manualRenderingFormat;
    [self stop];
    [self clearConfiguration];
    if(_engine.isRunning) [_engine stop];
    if(_engine.isInManualRenderingMode) [_engine disableManualRenderingMode];
    const auto layout=[[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_DiscreteInOrder | channels];
    const auto format=channels>2 ? [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channelLayout:layout]
        : [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels];
    const auto sinkFormat=channels>2 ? [[AVAudioFormat alloc] initStandardFormatWithSampleRate:hardware.sampleRate channelLayout:layout]
        : [[AVAudioFormat alloc] initStandardFormatWithSampleRate:hardware.sampleRate channels:channels];
    if(![_engine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime format:format maximumFrameCount:4096 error:error]) return nil;
    _render=_engine.manualRenderingBlock;
    _state=std::make_shared<BufferedAudioState>(channels,rate);
    _state->setPlaybackSourceCount(_playbackSourceCount);
    _state->setLiveMonitoring(_liveInstrumentMonitoring);
    _buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:BufferedAudioState::maximumBlock];
    auto state=_state;
    auto unit = _engine.mainMixerNode.AUAudioUnit;
    auto observer = [unit tokenByAddingRenderObserver:^(AudioUnitRenderActionFlags flags,
        const AudioTimeStamp *time, AVAudioFrameCount frames, NSInteger bus) {
        if(flags & kAudioUnitRenderAction_PreRender) state->observeGraphTime(time);
    }];
    _clockUnit = unit; _clockObserver = observer;
    auto engine=_engine; auto render=_render; auto buffer=_buffer;
    _source=[[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *silent,const AudioTimeStamp *time,AVAudioFrameCount frames,AudioBufferList *output) {
        *silent=NO;
        state->renderHardwareSlice(time,frames,engine,render,buffer);
        return state->consume(time,frames,output);
    }];
    [_hardware attachNode:_source]; [_hardware connect:_source to:_hardware.mainMixerNode format:format];
    [_hardware connect:_hardware.mainMixerNode to:_hardware.outputNode format:sinkFormat];
    _hardwareRate=hardware.sampleRate; _hardwareChannels=channels;
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
    while(!state->liveMonitoring.load() && state->writeFrame.load()<state->targetFrames()) {
        @autoreleasepool { state->produce(_engine,_render,_buffer); }
    }
    state->enabled.store(true,std::memory_order_release);
    auto render=_render; auto buffer=_buffer; auto engine=_engine;
    _worker=std::thread([state,render,buffer,engine] {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
        while(state->enabled.load(std::memory_order_acquire)) {
            if(state->liveMonitoring.load(std::memory_order_acquire)) {
                semaphore_wait(state->wake);
            } else if(state->writeFrame.load(std::memory_order_relaxed)-state->readFrame.load(std::memory_order_acquire)<state->targetFrames()
                      && !state->producing.test_and_set(std::memory_order_acquire)) {
                if(!state->liveMonitoring.load(std::memory_order_acquire)) {
                    @autoreleasepool { state->produce(engine,render,buffer); }
                }
                state->producing.clear(std::memory_order_release);
            } else { mach_timespec_t timeout{0,5'000'000}; semaphore_timedwait(state->wake,timeout); }
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
- (void)beginStop { if(_state) _state->beginStop(); }
- (void)endStop { if(_state) _state->endStop(); }
- (void)setOutputEnabled:(BOOL)enabled {
    _outputEnabled=enabled;
    _hardware.mainMixerNode.outputVolume=enabled ? 1 : 0;
}
- (void)setLiveInstrumentMonitoring:(BOOL)monitoring {
    _liveInstrumentMonitoring=monitoring;
    if(_state) _state->setLiveMonitoring(monitoring);
}
- (void)setPlaybackSourceCount:(NSUInteger)count {
    _playbackSourceCount=count;
    if(_state) _state->setPlaybackSourceCount(count);
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
        @"renderFailures":@(s.failures.load()),@"renders":@(count),@"renderFrames":@(s.liveMonitoring.load() ? s.callbackFrames.load() : s.renderFrames.load()),
        @"targetFrames":@(s.liveMonitoring.load() ? 0 : s.targetFrames()),@"sampleRate":@(s.rate),@"hardwareSampleRate":@(_hardwareRate),@"channels":@(s.channels),
        @"meanRenderMs":@(count ? s.renderTicks.load()/s.ticksPerSecond*1000/count : 0),
        @"maxRenderMs":@(s.maxRenderTicks.load()/s.ticksPerSecond*1000),
        @"bufferedFrames":@(s.writeFrame.load()-s.readFrame.load())};
}
- (void)dealloc {
    [self stop];
    [self clearConfiguration];
}
@end
