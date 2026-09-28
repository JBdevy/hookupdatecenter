#import "JarasTimecode.h"
#import <CoreMIDI/CoreMIDI.h>
#include "../../Core/Timecode/Timecode.hpp"
#include <atomic>
#include <memory>
#include <mach/mach_time.h>

struct TimecodeSignal {
    std::atomic<double> position{0},end{0},fps{30};
    std::atomic<uint64_t> host{0};
    std::atomic<bool> active{false};
    std::atomic<float> peak{0};
    std::atomic<uint64_t> generation{0};
    uint64_t renderGeneration=~uint64_t(0);
    double anchorSample=0, anchorPosition=0, renderedFPS=0;
    double ticksPerSecond, sampleRate;
    int64_t frame=-1;
    std::array<float,160> halves{};
    explicit TimecodeSignal(double rate):sampleRate(rate) { mach_timebase_info_data_t info; mach_timebase_info(&info); ticksPerSecond=1e9*info.denom/info.numer; }
    double clock(uint64_t now) const { return position.load()+double(int64_t(now-host.load()))/ticksPerSecond; }
    void render(const AudioTimeStamp* time, AVAudioFrameCount count, AudioBufferList* list) {
        const bool enabled=active.load(std::memory_order_acquire);
        const double rate=fps.load(), actualRate=rate==29.97 ? 30000.0/1001 : rate;
        const auto version=generation.load(std::memory_order_acquire);
        if(renderGeneration!=version) {
            renderGeneration=version; anchorSample=time->mSampleTime;
            anchorPosition=clock((time->mFlags & kAudioTimeStampHostTimeValid) ? time->mHostTime : mach_absolute_time());
        }
        if(renderedFPS!=rate) { renderedFPS=rate; frame=-1; }
        const double start=(time->mFlags & kAudioTimeStampSampleTimeValid) ? anchorPosition+(time->mSampleTime-anchorSample)/sampleRate : clock(mach_absolute_time());
        const double limit=end.load();
        const double first=std::max(0.0,position.load());
        float observedPeak=0;
        for(unsigned sample=0;sample<count;++sample) {
            float value=0;
            const double seconds=start+sample/sampleRate;
            if(enabled && seconds>=first && seconds<limit) {
                const int64_t half=int64_t(std::floor(seconds*actualRate*160));
                const int64_t current=half/160;
                if(current!=frame) {
                    frame=current; const auto bits=jaras::ltcFrame((current+0.01)/actualRate,rate);
                    float phase=0.25f;
                    for(int bit=0;bit<80;++bit) { phase=-phase; halves[bit*2]=phase; if(bits[bit]) phase=-phase; halves[bit*2+1]=phase; }
                }
                value=halves[half%160];
                observedPeak=std::max(observedPeak,std::abs(value));
            }
            for(unsigned b=0;b<list->mNumberBuffers;++b) {
                auto& buffer=list->mBuffers[b]; auto data=static_cast<float*>(buffer.mData);
                if(data) for(unsigned ch=0;ch<buffer.mNumberChannels;++ch) data[sample*buffer.mNumberChannels+ch]=value;
            }
        }
        if(observedPeak>0) peak.store(std::max(peak.load(std::memory_order_relaxed),observedPeak),std::memory_order_relaxed);
    }
};
@implementation JarasTimecodeGenerator {
    std::shared_ptr<TimecodeSignal> _signal;
    AVAudioSourceNode *_node;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    MIDIClientRef _client;
    MIDIPortRef _port;
    MIDIEndpointRef _destination;
    double _position, _end, _fps, _ticksPerSecond;
    uint64_t _host;
    int64_t _quarter;
    jaras::NativeMtcTimeFields _fields;
}
- (instancetype)initWithFormat:(AVAudioFormat*)format {
    if((self=[super init])) {
        _signal=std::make_shared<TimecodeSignal>(format.sampleRate);
        auto signal=_signal; _ticksPerSecond=signal->ticksPerSecond;
        _node=[[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL* silence,const AudioTimeStamp* timestamp,AVAudioFrameCount count,AudioBufferList* output){
            *silence=!signal->active.load(std::memory_order_acquire); signal->render(timestamp,count,output); return noErr;
        }];
        _queue=dispatch_queue_create("live.jaras.timecode.midi",DISPATCH_QUEUE_SERIAL);
        MIDIClientCreate(CFSTR("Jaras Live Timecode"),nullptr,nullptr,&_client);
        MIDIOutputPortCreate(_client,CFSTR("MTC Output"),&_port);
    }
    return self;
}
- (AVAudioSourceNode*)node { return _node; }
- (float)takePeak { return _signal->peak.exchange(0,std::memory_order_relaxed); }
- (void)send:(const Byte*)bytes length:(UInt16)length at:(MIDITimeStamp)timestamp {
    MIDIPacketList list; auto packet=MIDIPacketListInit(&list);
    MIDIPacketListAdd(&list,sizeof(list),packet,timestamp,length,bytes);
    if(_destination && _port) MIDISend(_port,_destination,&list);
}
- (void)pulse {
    const uint64_t now=mach_absolute_time();
    const double elapsed=double(int64_t(now-_host))/_ticksPerSecond;
    const double rate=_fps==29.97 ? 30000.0/1001 : _fps;
    if(elapsed<0 || _position+elapsed>=_end) return;
    const int64_t quarter=int64_t(std::floor(elapsed*rate*4));
    // Never flood the destination with stale packets after a stalled worker.
    if(quarter-_quarter>8) _quarter=(quarter/8)*8-1;
    while(_quarter<quarter) {
        ++_quarter;
        const double at=_position+double(_quarter)/(rate*4);
        if((_quarter&7)==0) _fields=jaras::nativeMtcTimeFields(at,_fps,_fps==29.97);
        Byte bytes[2]={0xf1,Byte(jaras::nativeMtcQuarterFrameData(_fields,int(_quarter&7)))};
        [self send:bytes length:2 at:_host+uint64_t(double(_quarter)*_ticksPerSecond/(rate*4))];
    }
}
- (void)configurePosition:(double)position end:(double)end hostTime:(uint64_t)hostTime rate:(double)fps mode:(NSString*)mode running:(BOOL)running destination:(int32_t)destination {
    _signal->active.store(false,std::memory_order_release);
    _signal->peak.store(0,std::memory_order_relaxed);
    _signal->position=position; _signal->end=end; _signal->host=hostTime; _signal->fps=fps;
    _signal->generation.fetch_add(1,std::memory_order_release);
    _signal->active.store(running && [mode isEqualToString:@"ltc"],std::memory_order_release);
    const bool mtc=[mode isEqualToString:@"mtc"];
    dispatch_async(_queue,^{
        if(self->_timer) { dispatch_source_cancel(self->_timer); self->_timer=nil; }
        self->_position=position; self->_end=end; self->_host=hostTime; self->_fps=fps; self->_quarter=-1;
        self->_destination=0;
        if(destination) for(ItemCount i=0;i<MIDIGetNumberOfDestinations();++i) { auto endpoint=MIDIGetDestination(i); SInt32 identifier=0, offline=0; MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&identifier); MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyOffline,&offline); if(identifier==destination && !offline) self->_destination=endpoint; }
        if(!mtc || !self->_destination || !self->_port) return;
        const auto fields=jaras::nativeMtcTimeFields(position,fps,fps==29.97,true);
        Byte full[10]={0xf0,0x7f,0x7f,0x01,0x01,Byte(fields.hour|(fields.rateCode<<5)),Byte(fields.minute),Byte(fields.second),Byte(fields.frame),0xf7};
        [self send:full length:10 at:hostTime];
        if(!running) return;
        self->_timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self->_queue);
        __weak JarasTimecodeGenerator* weak=self;
        dispatch_source_set_timer(self->_timer,DISPATCH_TIME_NOW,NSEC_PER_MSEC,NSEC_PER_MSEC/4);
        dispatch_source_set_event_handler(self->_timer,^{ [weak pulse]; });
        dispatch_resume(self->_timer);
    });
}
+ (NSArray<NSDictionary*>*)destinations {
    NSMutableArray* values=[NSMutableArray new];
    for(ItemCount i=0;i<MIDIGetNumberOfDestinations();++i) {
        auto endpoint=MIDIGetDestination(i); SInt32 identifier=0, offline=0; CFStringRef name=nullptr;
        MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&identifier);
        MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyOffline,&offline);
        if(!identifier || offline) continue;
        MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&name);
        [values addObject:@{@"id":@(identifier),@"name":name ? (__bridge NSString*)name : @"MIDI"}];
        if(name) CFRelease(name);
    }
    return values;
}
- (void)dealloc { if(_timer) dispatch_source_cancel(_timer); if(_port) MIDIPortDispose(_port); if(_client) MIDIClientDispose(_client); }
@end
