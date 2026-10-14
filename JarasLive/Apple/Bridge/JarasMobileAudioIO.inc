// Included by JarasEffects.mm so every bridge/test target uses the same driver.
// AVAudioEngine remains a realtime DSP graph; only this small RemoteIO unit
// observes hardware. It has no AVAudioClock stream-format listener, which is
// the source of the iOS 16 USB-disconnect lock inversion.
@implementation JarasMobileAudioOutput {
    AVAudioEngine *_engine;
    AVAudioEngineManualRenderingBlock _render;
    AudioUnit _unit;
    std::atomic<bool> _enabled;
    std::atomic<uint64_t> _sequence, _host;
    std::atomic<int64_t> _sample;
    double _rate, _ticksPerSecond;
}
- (instancetype)initWithEngine:(AVAudioEngine *)engine {
    if ((self = [super init])) {
        _engine = engine;
        mach_timebase_info_data_t base; mach_timebase_info(&base);
        _ticksPerSecond = 1e9 * base.denom / base.numer;
    }
    return self;
}
- (AVAudioTime *)renderTime {
    // Bounded snapshot: never spin on a preempted audio callback.
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        auto serial = _sequence.load(std::memory_order_acquire);
        if (serial & 1) continue;
        auto host = _host.load(std::memory_order_relaxed);
        auto sample = _sample.load(std::memory_order_relaxed);
        if (serial == _sequence.load(std::memory_order_acquire) && host && _rate > 0)
            return [[AVAudioTime alloc] initWithHostTime:host sampleTime:sample atRate:_rate];
    }
    return nil;
}
- (AVAudioFormat *)configureWithSampleRate:(double)rate channels:(AVAudioChannelCount)channels error:(NSError **)error {
    if (!std::isfinite(rate) || rate <= 0 || !channels || channels > 1024) {
        if (error) *error = [NSError errorWithDomain:@"CatLive.MobileAudio" code:-50
            userInfo:@{NSLocalizedDescriptionKey:@"Audio output is unavailable"}];
        return nil;
    }
    if (_engine.isInManualRenderingMode && _engine.manualRenderingFormat.sampleRate == rate &&
        _engine.manualRenderingFormat.channelCount == channels) return _engine.manualRenderingFormat;
    if (_unit) {
        if (error) *error = [NSError errorWithDomain:@"CatLive.MobileAudio" code:-50
            userInfo:@{NSLocalizedDescriptionKey:@"Stop the transport before changing the audio device."}];
        return nil;
    }
    auto layout = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_DiscreteInOrder | channels];
    AVAudioFormat *format = channels > 2
        ? [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channelLayout:layout]
        : [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels];
    if (_engine.isInManualRenderingMode) [_engine disableManualRenderingMode];
    if (![_engine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime format:format maximumFrameCount:4096 error:error]) return nil;
    _rate = rate;
    _host.store(0); _sample.store(0);
    _render = _engine.manualRenderingBlock;
    return format;
}
- (OSStatus)renderFrames:(UInt32)frames time:(const AudioTimeStamp *)time flags:(AudioUnitRenderActionFlags *)flags buffers:(AudioBufferList *)data {
    if (!_enabled.load(std::memory_order_acquire)) {
        for (unsigned n = 0; n < data->mNumberBuffers; ++n)
            if (data->mBuffers[n].mData) memset(data->mBuffers[n].mData, 0, data->mBuffers[n].mDataByteSize);
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    const auto first = _engine.manualRenderingSampleTime;
    const auto host = (time->mFlags & kAudioTimeStampHostTimeValid) ? time->mHostTime : mach_absolute_time();
    const auto previous = jaras::realtimeClock;
    jaras::realtimeClock = {host, double(first), _rate, _ticksPerSecond};
    OSStatus failure = noErr;
    const auto status = _render(frames, data, &failure);
    jaras::realtimeClock = previous;
    _sequence.fetch_add(1, std::memory_order_acq_rel);
    _sample.store(_engine.manualRenderingSampleTime, std::memory_order_relaxed);
    _host.store(host + uint64_t(frames / _rate * _ticksPerSecond), std::memory_order_relaxed);
    _sequence.fetch_add(1, std::memory_order_release);
    if (status != AVAudioEngineManualRenderingStatusSuccess) {
        for (unsigned n = 0; n < data->mNumberBuffers; ++n)
            if (data->mBuffers[n].mData) memset(data->mBuffers[n].mData, 0, data->mBuffers[n].mDataByteSize);
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    return noErr;
}
static OSStatus mobileOutputRender(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                                  UInt32 bus, UInt32 frames, AudioBufferList *data) {
    return [(__bridge JarasMobileAudioOutput *)context renderFrames:frames time:time flags:flags buffers:data];
}
- (BOOL)startAndReturnError:(NSError **)error {
#if TARGET_OS_IOS
    if (_unit) return YES;
    AudioComponentDescription description = {kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
    OSStatus status = AudioComponentInstanceNew(AudioComponentFindNext(NULL, &description), &_unit);
    if (status == noErr) {
        UInt32 maximum = 4096;
        status = AudioUnitSetProperty(_unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, sizeof(maximum));
    }
    if (status == noErr) {
        auto format = _engine.manualRenderingFormat;
        status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                      format.streamDescription, sizeof(AudioStreamBasicDescription));
        if (status == noErr) status = jaras::configureDiscreteOutputMap(_unit, format.channelCount);
    }
    if (status == noErr) {
        AURenderCallbackStruct callback = {mobileOutputRender, (__bridge void *)self};
        status = AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    }
    if (status == noErr) status = AudioUnitInitialize(_unit);
    if (status == noErr) {
        _enabled.store(true, std::memory_order_release);
        status = AudioOutputUnitStart(_unit);
    }
    if (status == noErr) return YES;
    [self stop];
    if (error) *error = [NSError errorWithDomain:@"CatLive.MobileAudio" code:status
        userInfo:@{NSLocalizedDescriptionKey:@"Audio output is unavailable"}];
    return NO;
#else
    _enabled.store(true, std::memory_order_release);
    return YES; // Test harness supplies the hardware callback's timestamps.
#endif
}
- (void)gate { _enabled.store(false, std::memory_order_release); }
- (void)stop {
    [self gate];
    if (_unit) {
        AudioOutputUnitStop(_unit);
        AudioUnitUninitialize(_unit);
        AudioComponentInstanceDispose(_unit);
        _unit = NULL;
    }
    _sequence.fetch_add(1, std::memory_order_acq_rel);
    _host.store(0, std::memory_order_relaxed);
    _sample.store(0, std::memory_order_relaxed);
    _sequence.fetch_add(1, std::memory_order_release);
}
- (void)dealloc { [self stop]; }
@end

@implementation JarasMobileAudioInput {
    AudioUnit _unit;
    AVAudioPCMBuffer *_buffer;
    void (^_capture)(AVAudioPCMBuffer *);
    BOOL _running;
}
- (AVAudioFormat *)format { return _buffer.format; }
- (BOOL)running { return _running; }
- (void)setCapture:(void (^)(AVAudioPCMBuffer *))capture {
    // Caller stops the unit first: the realtime callback never loads a block
    // whose ownership is being changed by the control thread.
    _capture = [capture copy];
}
- (void)pause {
    if (_unit && _running) AudioOutputUnitStop(_unit);
    _running = NO;
}
- (OSStatus)captureFrames:(UInt32)frames time:(const AudioTimeStamp *)time flags:(AudioUnitRenderActionFlags *)flags {
    if (frames > _buffer.frameCapacity) return kAudioUnitErr_TooManyFramesToProcess;
    _buffer.frameLength = frames;
    const auto status = AudioUnitRender(_unit, flags, time, 1, frames, _buffer.mutableAudioBufferList);
    if (status == noErr && _capture) _capture(_buffer);
    return status;
}
static OSStatus mobileInputRender(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                                 UInt32 bus, UInt32 frames, AudioBufferList *data) {
    return [(__bridge JarasMobileAudioInput *)context captureFrames:frames time:time flags:flags];
}
- (BOOL)prepareWithSampleRate:(double)rate channels:(AVAudioChannelCount)channels error:(NSError **)error {
    if (_unit && _buffer.format.sampleRate == rate && _buffer.format.channelCount == channels) return YES;
    [self stop];
    OSStatus status = noErr;
#if TARGET_OS_IOS
    if (!std::isfinite(rate) || rate <= 0 || !channels || channels > 1024) status = kAudio_ParamError;
    if (status == noErr) {
        AudioComponentDescription description = {kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
        status = AudioComponentInstanceNew(AudioComponentFindNext(NULL, &description), &_unit);
    }
    if (status == noErr) {
        UInt32 enabled = 1, disabled = 0;
        status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, sizeof(enabled));
        if (status == noErr) status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, sizeof(disabled));
    }
    if (status == noErr) {
        auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels];
        _buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096];
        status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format.streamDescription, sizeof(AudioStreamBasicDescription));
        if (status == noErr) status = jaras::configureDiscreteInputMap(_unit, channels);
        UInt32 maximum = 4096;
        if (status == noErr) status = AudioUnitSetProperty(_unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, sizeof(maximum));
    }
    if (status == noErr) {
        AURenderCallbackStruct callback = {mobileInputRender, (__bridge void *)self};
        status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &callback, sizeof(callback));
    }
    if (status == noErr) status = AudioUnitInitialize(_unit);
#endif
    if (status == noErr) return YES;
    [self stop];
    if (error) *error = [NSError errorWithDomain:@"CatLive.MobileAudio" code:status userInfo:@{NSLocalizedDescriptionKey:@"No audio inputs available."}];
    return NO;
}
- (BOOL)startAndReturnError:(NSError **)error {
    if (_running) return YES;
    const auto status = _unit ? AudioOutputUnitStart(_unit) : kAudio_ParamError;
    if (status == noErr) { _running = YES; return YES; }
    if (error) *error = [NSError errorWithDomain:@"CatLive.MobileAudio" code:status userInfo:@{NSLocalizedDescriptionKey:@"No audio inputs available."}];
    return NO;
}
- (void)stop {
    if (_unit) {
        AudioOutputUnitStop(_unit);
        AudioUnitUninitialize(_unit);
        AudioComponentInstanceDispose(_unit);
        _unit = NULL;
    }
    _running = NO;
}
- (void)dealloc { [self stop]; }
@end
