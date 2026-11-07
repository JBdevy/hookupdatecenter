#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import "JarasRecording.h"
#include <algorithm>
#include <cmath>
#include <cassert>
#include <cstdio>

namespace probe {
UInt32 device=0, frames=512, maximum=4096;
bool input=false, output=true, readable=true, acceptDevice=true;
int starts=0, stops=0, renders=0, disposals=0;
OSStatus setFailure=0;
AURenderCallbackStruct callback{};
AudioStreamBasicDescription client{};
AudioComponent component(AudioComponent, const AudioComponentDescription *d) {
    assert(d->componentSubType==kAudioUnitSubType_HALOutput);
    return reinterpret_cast<AudioComponent>(0x200);
}
OSStatus create(AudioComponent, AudioComponentInstance *unit) { *unit=reinterpret_cast<AudioComponentInstance>(0x100); return noErr; }
OSStatus dispose(AudioComponentInstance) { ++disposals; device=0; return noErr; }
OSStatus set(AudioUnit,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement element,const void *data,UInt32 bytes) {
    if(setFailure)return setFailure;
    if(property==kAudioOutputUnitProperty_EnableIO) {
        if(scope==kAudioUnitScope_Input&&element==1)input=*static_cast<const UInt32*>(data);
        if(scope==kAudioUnitScope_Output&&element==0)output=*static_cast<const UInt32*>(data);
    } else if(property==kAudioOutputUnitProperty_CurrentDevice) {
        if(acceptDevice)device=*static_cast<const UInt32*>(data);
    } else if(property==kAudioUnitProperty_StreamFormat) {
        assert(scope==kAudioUnitScope_Output&&element==1);client=*static_cast<const AudioStreamBasicDescription*>(data);
    } else if(property==kAudioUnitProperty_MaximumFramesPerSlice)maximum=*static_cast<const UInt32*>(data);
    else if(property==kAudioOutputUnitProperty_SetInputCallback)callback=*static_cast<const AURenderCallbackStruct*>(data);
    else if(property==kAudioOutputUnitProperty_ChannelMap) {
        assert(scope==kAudioUnitScope_Input&&element==1&&bytes==4*sizeof(SInt32));
        for(int ch=0;ch<4;++ch)assert(static_cast<const SInt32*>(data)[ch]==ch);
    }
    return noErr;
}
OSStatus get(AudioUnit,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement element,void *data,UInt32 *bytes) {
    if(property==kAudioOutputUnitProperty_CurrentDevice) {
        if(!readable)return kAudioHardwareBadDeviceError;
        *static_cast<UInt32*>(data)=device;
    } else if(property==kAudioUnitProperty_MaximumFramesPerSlice)*static_cast<UInt32*>(data)=maximum;
    else if(property==kAudioUnitProperty_StreamFormat) {
        assert(scope==kAudioUnitScope_Input&&element==1);
        *static_cast<AudioStreamBasicDescription*>(data)={48000,kAudioFormatLinearPCM,
            kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked|kAudioFormatFlagIsNonInterleaved,4,1,4,4,32,0};
    }
    return noErr;
}
OSStatus objectGet(AudioObjectID id,const AudioObjectPropertyAddress *p,UInt32,const void*,UInt32*,void *data) {
    assert(id==77);
    if(p->mSelector==kAudioDevicePropertyBufferFrameSizeRange)*static_cast<AudioValueRange*>(data)={64,2048};
    else if(p->mSelector==kAudioDevicePropertyBufferFrameSize)*static_cast<UInt32*>(data)=frames;
    else assert(false);
    return noErr;
}
OSStatus objectSet(AudioObjectID id,const AudioObjectPropertyAddress *p,UInt32,const void*,UInt32,const void *data) {
    assert(id==77&&p->mSelector==kAudioDevicePropertyBufferFrameSize);
    frames=*static_cast<const UInt32*>(data);return noErr;
}
OSStatus start(AudioUnit) { assert(input&&!output&&device==77);++starts;return noErr; }
OSStatus stop(AudioUnit) { ++stops;return noErr; }
OSStatus init(AudioUnit) { return noErr; }
OSStatus render(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32 bus,UInt32 count,AudioBufferList *data) {
    assert(bus==1&&data->mNumberBuffers==4);++renders;
    for(UInt32 ch=0;ch<data->mNumberBuffers;++ch) {
        assert(data->mBuffers[ch].mDataByteSize==count*sizeof(float));
        std::fill_n(static_cast<float*>(data->mBuffers[ch].mData),count,float(ch+1)*.1f);
    }
    return noErr;
}
}
#define AudioComponentFindNext probe::component
#define AudioComponentInstanceNew probe::create
#define AudioComponentInstanceDispose probe::dispose
#define AudioUnitSetProperty probe::set
#define AudioUnitGetProperty probe::get
#define AudioObjectGetPropertyData probe::objectGet
#define AudioObjectSetPropertyData probe::objectSet
#define AudioOutputUnitStart probe::start
#define AudioOutputUnitStop probe::stop
#define AudioUnitInitialize probe::init
#define AudioUnitUninitialize probe::init
#define AudioUnitRender probe::render
#include "JarasMacAudioInput.inc"
int main() { @autoreleasepool {
    auto input=[JarasMacAudioInput new];NSError *error=nil;
    assert(![input prepareWithDevice:0 bufferFrames:128 error:&error]);
    assert(![input startAndReturnError:&error]&&probe::starts==0);
    for(UInt32 frames:{128u,512u,1024u}) {
        assert([input prepareWithDevice:77 bufferFrames:frames error:&error]);
        assert(input.device==77&&input.bufferFrames==frames&&probe::frames==frames);
        assert(input.format.sampleRate==48000&&input.format.channelCount==4);
        __block UInt32 received=0;
        [input setCapture:^(AVAudioPCMBuffer *buffer) {
            received+=buffer.frameLength;
            assert(buffer.frameLength==frames);
            for(int ch=0;ch<4;++ch)assert(std::abs(buffer.floatChannelData[ch][0]-float(ch+1)*.1f)<.00001);
        }];
        assert([input startAndReturnError:&error]&&input.running);
        const int starts=probe::starts;assert([input startAndReturnError:&error]&&probe::starts==starts);
        AudioUnitRenderActionFlags flags=0;AudioTimeStamp time{};
        for(int i=0;i<8;++i)assert(probe::callback.inputProc(probe::callback.inputProcRefCon,&flags,&time,1,frames,nullptr)==noErr);
        assert(received==frames*8); // No tap batching, hidden quantum or output route.
        assert(probe::callback.inputProc(probe::callback.inputProcRefCon,&flags,&time,1,65537,nullptr)==kAudioUnitErr_TooManyFramesToProcess);
        [input pause];[input setCapture:nil];assert(!input.running);
        [input stop];assert(input.device==0&&input.format==nil);
    }
    probe::setFailure=-50;assert(![input prepareWithDevice:77 bufferFrames:128 error:&error]);
    probe::setFailure=0;probe::acceptDevice=false;assert(![input prepareWithDevice:77 bufferFrames:128 error:&error]);
    probe::acceptDevice=true;probe::readable=false;assert(![input prepareWithDevice:77 bufferFrames:128 error:&error]);
    assert(input.device==0&&input.format==nil&&!input.running);
    puts("MAC_INPUT_SELECTED_DEVICE_HARDWARE_BUFFER_CALLBACK_MAPPING_AND_FAILURES_OK");
}}
