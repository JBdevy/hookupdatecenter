#import "JarasTimecode.h"
#import <CoreMIDI/CoreMIDI.h>
#include "../../Core/Timecode/Timecode.hpp"
#include <atomic>
#include <memory>
#include <vector>
#include <cstring>
#include <algorithm>
#include <mach/mach_time.h>

struct TimecodeSignal {
    std::atomic<double> position{0},end{0},fps{30};
    std::atomic<uint64_t> host{0};
    std::atomic<bool> active{false};
    std::atomic<float> peak{0}, gain{1};
    float renderedGain = 1;
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
        const float targetGain = gain.load(std::memory_order_relaxed);
        const float smoothing = float(1.0 - std::exp(-1.0 / (sampleRate * 0.01)));
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
                renderedGain += (targetGain - renderedGain) * smoothing;
                value=halves[half%160] * renderedGain;
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
        MIDIClientCreate(CFSTR("CatLive Timecode"),nullptr,nullptr,&_client);
        MIDIOutputPortCreate(_client,CFSTR("MTC Output"),&_port);
    }
    return self;
}
- (AVAudioSourceNode*)node { return _node; }
- (void)setGain:(float)gain { _signal->gain.store(std::max(-4.f, std::min(4.f, gain)), std::memory_order_relaxed); }
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

// Immutable sound/tempo programs are published with a hazard pointer. The render
// callback neither locks nor allocates; retired programs are reclaimed by the UI.
struct MetronomeProgram {
    struct Tempo { double start, bpm; int beats, unit; double end=INFINITY, origin=NAN; };
    std::vector<Tempo> sections;
    std::vector<float> a, b;
    int mode = 0;
    bool bounded = false;
};
struct MetronomeSignal {
    std::atomic<MetronomeProgram*> program{nullptr}, reading{nullptr};
    std::atomic<float> gainA{1}, gainB{1};
    float renderedA=1, renderedB=1;
    std::vector<std::unique_ptr<MetronomeProgram>> programs;
    std::atomic<double> position{0}, loopStart{0}, loopEnd{0}, referenceSample{NAN};
    std::atomic<uint64_t> host{0}, generation{0};
    std::atomic<bool> running{false}, enabled{true};
    struct Jump { uint64_t version=0, host=0; double position=0, sample=NAN, first=0, last=0; };
    std::atomic<uint64_t> jumpVersion{0}, jumpHost{0};
    std::atomic<double> jumpPosition{0}, jumpSample{NAN}, jumpFirst{0}, jumpLast{0};
    std::atomic<uint64_t> acknowledgedJump{0};
    Jump renderJump;
    uint64_t consumedJump=0;
    void scheduleJump(double destination, uint64_t deadline, double sample, double first=0, double last=0) {
        if(jumpHost.load()==deadline) return;
        // UI promotion can lead audible output by one buffer. Preserve that
        // pending edge before accepting the following short loop/queued song.
        if(jumpHost.load() && acknowledgedJump.load(std::memory_order_acquire)!=jumpVersion.load()) return;
        // Commit the previous mapping on the control side before replacing it.
        // The renderer already owns that anchor; no generation/reset is needed.
        if(jumpHost.load()) {
            position.store(jumpPosition.load()); host.store(jumpHost.load()); referenceSample.store(jumpSample.load());
        }
        jumpVersion.fetch_add(1,std::memory_order_acq_rel);
        jumpPosition.store(destination); jumpSample.store(sample); jumpHost.store(deadline);
        jumpFirst.store(first); jumpLast.store(last);
        jumpVersion.fetch_add(1,std::memory_order_release);
    }
    void cancelJump() {
        jumpVersion.fetch_add(1,std::memory_order_acq_rel);
        jumpHost.store(0);
        jumpVersion.fetch_add(1,std::memory_order_release);
    }
    uint64_t renderedGeneration = ~uint64_t(0);
    double sampleRate, ticksPerSecond, anchorSample=0, anchorPosition=0;
    double previousPosition=-1, previousSample=-1; int64_t previousBeat=-1; size_t previousSection=~size_t(0);
    struct Voice { size_t frame=0; bool a=true; MetronomeProgram* sound=nullptr; };
    std::array<Voice,32> voices{};
    std::array<std::atomic<MetronomeProgram*>,32> voicePrograms;
    uint32_t activeVoices=0;
    size_t nextVoice=0; float gain=0;
    explicit MetronomeSignal(double rate):sampleRate(rate) {
        for(auto& sound : voicePrograms) sound.store(nullptr);
        mach_timebase_info_data_t info; mach_timebase_info(&info); ticksPerSecond=1e9*info.denom/info.numer;
    }
    void clearVoices() {
        for(uint32_t pending=activeVoices;pending;pending&=pending-1)
            voicePrograms[unsigned(__builtin_ctz(pending))].store(nullptr);
        activeVoices=0;
    }
    double wrap(double p) const {
        const double first=loopStart.load(), last=loopEnd.load();
        return last>first && p>=last ? first+std::fmod(p-first,last-first) : p;
    }
    double clock(uint64_t now) const {
        const auto deadline=jumpHost.load();
        if(deadline && now>=deadline) return jumpPosition.load()+double(now-deadline)/ticksPerSecond;
        return position.load()+double(int64_t(now-host.load()))/ticksPerSecond;
    }
    void publish(std::unique_ptr<MetronomeProgram> value) {
        auto* next=value.get(); programs.push_back(std::move(value)); program.store(next);
        const auto* protectedProgram=reading.load();
        // Read the callback hazard before the voice hazards: the callback
        // publishes a voice's sound before releasing its program hazard.
        std::array<MetronomeProgram*,32> sounding{};
        for(size_t i=0;i<sounding.size();++i) sounding[i]=voicePrograms[i].load();
        programs.erase(std::remove_if(programs.begin(),programs.end(),[&](const auto& p) {
            return p.get()!=next && p.get()!=protectedProgram &&
                std::find(sounding.begin(),sounding.end(),p.get())==sounding.end();
        }),programs.end());
    }
    void render(const AudioTimeStamp* time, AVAudioFrameCount count, AudioBufferList* list) {
        MetronomeProgram* p;
        do { p=program.load(); reading.store(p); } while(p!=program.load());
        const auto version=generation.load(std::memory_order_acquire);
        const auto jumpSerial=jumpVersion.load(std::memory_order_acquire);
        if(!(jumpSerial&1)) {
            Jump next{jumpSerial,jumpHost.load(),jumpPosition.load(),jumpSample.load(),jumpFirst.load(),jumpLast.load()};
            if(jumpVersion.load(std::memory_order_acquire)==jumpSerial) renderJump=next;
        }
        const bool active=running.load() && enabled.load(std::memory_order_acquire);
        if(!active && gain==0) {
            for(unsigned b=0;b<list->mNumberBuffers;++b) if(list->mBuffers[b].mData) std::memset(list->mBuffers[b].mData,0,list->mBuffers[b].mDataByteSize);
            reading.store(nullptr); return;
        }
        if(renderedGeneration!=version || time->mSampleTime<previousSample) {
            renderedGeneration=version; anchorSample=time->mSampleTime;
            const double reference=referenceSample.load();
            if(std::isfinite(reference)) { anchorSample=reference; anchorPosition=position.load(); }
            else anchorPosition=clock((time->mFlags & kAudioTimeStampHostTimeValid) ? time->mHostTime : mach_absolute_time());
            previousPosition=-1; previousBeat=-1; previousSection=~size_t(0);
            if(p && p->bounded) clearVoices();
        }
        previousSample=time->mSampleTime;
        double start=(time->mFlags & kAudioTimeStampSampleTimeValid) ? anchorPosition+(time->mSampleTime-anchorSample)/sampleRate : clock(mach_absolute_time());
        const float step=float(1.0/(sampleRate*0.003));
        const float targetA=gainA.load(std::memory_order_relaxed), targetB=gainB.load(std::memory_order_relaxed);
        double first=renderJump.host && consumedJump==renderJump.version ? renderJump.position : position.load();
        size_t section=0;
        for(unsigned sample=0;sample<count;++sample) {
            if(active && renderJump.host && consumedJump!=renderJump.version) {
                const double since=std::isfinite(renderJump.sample) && (time->mFlags & kAudioTimeStampSampleTimeValid)
                    ? (time->mSampleTime+sample-renderJump.sample)/sampleRate
                    : double(int64_t(time->mHostTime-renderJump.host))/ticksPerSecond+sample/sampleRate;
                if(since>=-0.5/sampleRate) {
                    consumedJump=renderJump.version;
                    anchorPosition=renderJump.position;
                    anchorSample=time->mSampleTime+sample-std::max(0.0,since)*sampleRate;
                    start=anchorPosition+(time->mSampleTime-anchorSample)/sampleRate;
                    first=renderJump.position;
                    previousPosition=-1; previousBeat=-1; previousSection=~size_t(0);
                    section=0; clearVoices();
                    acknowledgedJump.store(consumedJump,std::memory_order_release);
                }
            }
            const double raw=start+sample/sampleRate;
            const bool jumped=renderJump.host && consumedJump==renderJump.version;
            const double position=jumped ? (renderJump.last>renderJump.first && raw>=renderJump.last
                ? renderJump.first+std::fmod(raw-renderJump.first,renderJump.last-renderJump.first) : raw) : wrap(raw);
            bool inside = !p || !p->bounded;
            if(p && !p->sections.empty() && active && position>=0 && start+sample/sampleRate>=first) {
                if(position<previousPosition) { section=0; previousBeat=-1; previousPosition=-1; }
                while(section+1<p->sections.size() && p->sections[section+1].start<=position) ++section;
                const auto& tempo=p->sections[section];
                inside = !p->bounded || (position>=tempo.start && position<tempo.end);
                if(inside) {
                const double beatSeconds=60.0/tempo.bpm*4.0/tempo.unit;
                const double exact=(position-(std::isfinite(tempo.origin) ? tempo.origin : tempo.start))/beatSeconds;
                const int64_t beat=int64_t(std::floor(std::max(0.0,exact)+1e-9));
                const double phase=(exact-double(beat))*beatSeconds;
                if((beat!=previousBeat || section!=previousSection) && (previousPosition>=0 || phase<0.003)) {
                    const auto index=nextVoice++%voices.size();
                    voices[index]={0,p->mode==1 || (p->mode==0 && beat%tempo.beats==0),p};
                    voicePrograms[index].store(p);
                    activeVoices|=uint32_t(1)<<index;
                }
                previousBeat=beat; previousSection=section; previousPosition=position;
                }
            }
            if(!inside) {
                clearVoices();
                previousPosition=-1; previousBeat=-1; previousSection=~size_t(0);
            }
            gain=active ? std::min(1.0f,gain+step) : std::max(0.0f,gain-step);
            renderedA += (targetA-renderedA)*step;
            renderedB += (targetB-renderedB)*step;
            float value=0;
            // Visit only sounding slots, from lowest to highest index, so
            // overlapping one-shots retain the exact original summation order.
            if(p && gain>0) for(uint32_t pending=activeVoices;pending;pending&=pending-1) {
                const auto index=unsigned(__builtin_ctz(pending));
                auto& voice=voices[index];
                const auto& data=voice.a ? voice.sound->a : voice.sound->b;
                if(voice.frame<data.size()) value+=data[voice.frame++]*(voice.a ? renderedA : renderedB);
                else {
                    activeVoices&=~(uint32_t(1)<<index);
                    voicePrograms[index].store(nullptr);
                }
            }
            value*=gain;
            if(!active && gain==0) clearVoices();
            for(unsigned b=0;b<list->mNumberBuffers;++b) {
                auto& buffer=list->mBuffers[b]; auto* data=static_cast<float*>(buffer.mData);
                if(data) for(unsigned ch=0;ch<buffer.mNumberChannels;++ch) data[sample*buffer.mNumberChannels+ch]=value;
            }
        }
        reading.store(nullptr);
    }
};
@implementation JarasMetronomeGenerator {
    std::shared_ptr<MetronomeSignal> _signal;
}
- (instancetype)initWithFormat:(AVAudioFormat*)format {
    if((self=[super init])) {
        _signal=std::make_shared<MetronomeSignal>(format.sampleRate); auto signal=_signal;
        _node=[[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL* silent,const AudioTimeStamp* time,AVAudioFrameCount count,AudioBufferList* buffers) {
            *silent=NO; signal->render(time,count,buffers); return noErr;
        }];
    } return self;
}
- (void)setSections:(NSArray<NSDictionary*>*)sections soundA:(NSData*)a soundB:(NSData*)b mode:(NSInteger)mode {
    auto value=std::make_unique<MetronomeProgram>(); value->mode=int(mode);
    for(NSDictionary* s in sections) value->sections.push_back({[s[@"start"] doubleValue],[s[@"bpm"] doubleValue],[s[@"beats"] intValue],[s[@"unit"] intValue]});
    const auto* pa=static_cast<const float*>(a.bytes); const auto* pb=static_cast<const float*>(b.bytes);
    if(a.length) value->a.assign(pa,pa+a.length/sizeof(float));
    if(b.length) value->b.assign(pb,pb+b.length/sizeof(float));
    _signal->publish(std::move(value));
}
- (void)setClickSections:(NSArray<NSDictionary*>*)sections sound:(NSData*)sound {
    auto value=std::make_unique<MetronomeProgram>(); value->mode=1; value->bounded=true;
    for(NSDictionary* s in sections) value->sections.push_back({[s[@"start"] doubleValue],[s[@"bpm"] doubleValue],[s[@"beats"] intValue],[s[@"unit"] intValue],[s[@"end"] doubleValue],[s[@"origin"] doubleValue]});
    const auto* samples=static_cast<const float*>(sound.bytes);
    if(sound.length) value->a.assign(samples,samples+sound.length/sizeof(float));
    _signal->publish(std::move(value));
}
- (void)setEnabled:(BOOL)enabled { _signal->enabled.store(enabled, std::memory_order_release); }
- (void)scheduleJump:(double)position hostTime:(uint64_t)host sampleTime:(double)sampleTime loopStart:(double)first loopEnd:(double)last {
    _signal->scheduleJump(position,host,sampleTime,first,last);
}
- (void)cancelJump { _signal->cancelJump(); }
- (void)setGainA:(float)a gainB:(float)b { _signal->gainA.store(a); _signal->gainB.store(b); }
- (void)configurePosition:(double)position hostTime:(uint64_t)host running:(BOOL)running loopStart:(double)first loopEnd:(double)last sampleTime:(double)sampleTime {
    _signal->loopStart.store(first); _signal->loopEnd.store(last);
    const bool wasRunning=_signal->running.load();
    if(wasRunning!=bool(running) || std::abs(_signal->wrap(_signal->clock(host))-position)>0.06) {
        _signal->cancelJump();
        _signal->position.store(position); _signal->host.store(host); _signal->referenceSample.store(sampleTime);
        _signal->generation.fetch_add(1,std::memory_order_release);
    }
    if(_signal->jumpHost.load() && _signal->acknowledgedJump.load(std::memory_order_acquire)==_signal->jumpVersion.load()) {
        // The audio callback has crossed the boundary. Keep its exact anchor
        // when adopting the UI state; never reset to a late, overshot position.
        _signal->position.store(_signal->jumpPosition.load());
        _signal->host.store(_signal->jumpHost.load());
        _signal->referenceSample.store(_signal->jumpSample.load());
        _signal->cancelJump();
    }
    _signal->running.store(running);
}
@end
