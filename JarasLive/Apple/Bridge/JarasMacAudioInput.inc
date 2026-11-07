// Included by JarasRecording.mm. Owns only the selected input device; the
// existing playback engine owns output and the monitor ring crosses clocks.
#if TARGET_OS_OSX
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include "JarasOutputChannelMap.hpp"

@implementation JarasMacAudioInput {
    AudioUnit _unit;
    AVAudioPCMBuffer *_buffer;
    void (^_capture)(AVAudioPCMBuffer *);
    BOOL _running;
    UInt32 _bufferFrames;
}
- (AVAudioFormat *)format { return _buffer.format; }
- (BOOL)running { return _running; }
- (uint32_t)bufferFrames { return _bufferFrames; }
- (uint32_t)device {
    UInt32 device = 0, bytes = sizeof(device);
    if (!_unit || AudioUnitGetProperty(_unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, &bytes) != noErr) return 0;
    return device;
}
- (void)setCapture:(void (^)(AVAudioPCMBuffer *))capture {
    // Only the control thread changes callback ownership, with input stopped.
    NSAssert(!_running, @"Pause input before changing the capture callback");
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
static OSStatus macInputRender(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                              UInt32 bus, UInt32 frames, AudioBufferList *data) {
    return [(__bridge JarasMacAudioInput *)context captureFrames:frames time:time flags:flags];
}
- (BOOL)prepareWithDevice:(uint32_t)device bufferFrames:(uint32_t)frames error:(NSError **)error {
    [self stop];
    OSStatus status = device && frames ? noErr : kAudio_ParamError;
    if (status == noErr) {
        AudioComponentDescription description = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
                                                 kAudioUnitManufacturer_Apple, 0, 0};
        const auto component = AudioComponentFindNext(NULL, &description);
        status = component ? AudioComponentInstanceNew(component, &_unit) : kAudio_ParamError;
    }
    if (status == noErr) {
        UInt32 enabled = 1, disabled = 0;
        status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, sizeof(enabled));
        if (status == noErr) status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, sizeof(disabled));
        if (status == noErr) status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device));
        if (status == noErr && self.device != device) status = kAudioHardwareBadDeviceError;
    }
    if (status == noErr) {
        AudioObjectPropertyAddress property = {kAudioDevicePropertyBufferFrameSizeRange,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioValueRange range{};
        UInt32 bytes = sizeof(range);
        if (AudioObjectGetPropertyData(device, &property, 0, NULL, &bytes, &range) == noErr)
            frames = UInt32(std::clamp(double(frames), range.mMinimum, range.mMaximum));
        property.mSelector = kAudioDevicePropertyBufferFrameSize;
        UInt32 current = 0; bytes = sizeof(current);
        status = AudioObjectGetPropertyData(device, &property, 0, NULL, &bytes, &current);
        if (status == noErr && current != frames)
            status = AudioObjectSetPropertyData(device, &property, 0, NULL, sizeof(frames), &frames);
        if (status == noErr) {
            bytes = sizeof(_bufferFrames);
            status = AudioObjectGetPropertyData(device, &property, 0, NULL, &bytes, &_bufferFrames);
        }
    }
    if (status == noErr) {
        AudioStreamBasicDescription hardware{};
        UInt32 bytes = sizeof(hardware);
        status = AudioUnitGetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &bytes);
        if (status == noErr && (!std::isfinite(hardware.mSampleRate) || hardware.mSampleRate <= 0 ||
                               hardware.mChannelsPerFrame == 0 || hardware.mChannelsPerFrame > 1024)) status = kAudio_ParamError;
        if (status == noErr) {
            auto layout = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_DiscreteInOrder | hardware.mChannelsPerFrame];
            auto format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:hardware.mSampleRate
                                                       interleaved:NO channelLayout:layout];
            if (!format) status = kAudio_ParamError;
            if (status == noErr) status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           format.streamDescription, sizeof(AudioStreamBasicDescription));
            if (status == noErr) status = jaras::configureDiscreteInputMap(_unit, hardware.mChannelsPerFrame);
            UInt32 maximum = std::max<UInt32>(4096, _bufferFrames);
            if (status == noErr) status = AudioUnitSetProperty(_unit, kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global, 0, &maximum, sizeof(maximum));
            if (status == noErr) {
                bytes = sizeof(maximum);
                status = AudioUnitGetProperty(_unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, &bytes);
            }
            if (status == noErr && (maximum == 0 || maximum > 65536)) status = kAudio_ParamError;
            if (status == noErr) {
                _buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:maximum];
                if (!_buffer) status = kAudio_MemFullError;
            }
        }
    }
    if (status == noErr) {
        AURenderCallbackStruct callback = {macInputRender, (__bridge void *)self};
        status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback));
    }
    if (status == noErr) status = AudioUnitInitialize(_unit);
    if (status == noErr) return YES;
    [self stop];
    if (error) *error = [NSError errorWithDomain:@"CatLive.MacAudioInput" code:status
        userInfo:@{NSLocalizedDescriptionKey:@"Could not open the selected audio input device."}];
    return NO;
}
- (BOOL)startAndReturnError:(NSError **)error {
    if (_running) return YES;
    const auto status = _unit ? AudioOutputUnitStart(_unit) : kAudio_ParamError;
    if (status == noErr) { _running = YES; return YES; }
    if (error) *error = [NSError errorWithDomain:@"CatLive.MacAudioInput" code:status
        userInfo:@{NSLocalizedDescriptionKey:@"Could not open the selected audio input device."}];
    return NO;
}
- (void)stop {
    [self pause];
    if (_unit) { AudioUnitUninitialize(_unit); AudioComponentInstanceDispose(_unit); _unit = NULL; }
    _buffer = nil; _bufferFrames = 0;
}
- (void)dealloc { [self stop]; }
@end
#endif
