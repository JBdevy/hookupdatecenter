#import "JarasEffects.h"
#import <Accelerate/Accelerate.h>
#if defined(__x86_64__)
#include <xmmintrin.h>
#endif
#include <array>
#include <atomic>
#include <cmath>
#include <algorithm>
#include <memory>
#include <set>
#include <vector>
#include <mach/mach_time.h>
// A callback may pull several nested units. Only the outermost unit changes
// the floating-point mode; restoring it preserves the caller's environment.
struct ScopedAudioDenormals {
#if defined(__aarch64__)
    uint64_t previous=0;
    bool changed=false;
    ScopedAudioDenormals() {
        asm volatile("mrs %0, fpcr" : "=r"(previous));
        const auto next=previous | (uint64_t(1)<<24);
        changed=next!=previous;
        if(changed) asm volatile("msr fpcr, %0" :: "r"(next));
    }
    ~ScopedAudioDenormals() { if(changed) asm volatile("msr fpcr, %0" :: "r"(previous)); }
#elif defined(__x86_64__)
    unsigned previous=_mm_getcsr();
    ScopedAudioDenormals() { _mm_setcsr(previous | 0x8040); }
    ~ScopedAudioDenormals() { _mm_setcsr(previous); }
#endif
};
static void scaleAudioBlock(float* data,unsigned count,float gain) {
    if(!count || gain==1) return;
    if(count>=64) vDSP_vsmul(data,1,&gain,data,1,count);
    else for(unsigned i=0;i<count;++i) data[i]*=gain;
}
// Level meters read the same maximum absolute sample as the former node taps.
// Capture the existing render buffer directly; the UI consumes only atomics.
struct StereoLevelPeaks {
    std::atomic<bool> enabled{false};
    std::array<std::atomic<float>,2> peaks{};
    StereoLevelPeaks() { for(auto& peak:peaks) peak.store(0,std::memory_order_relaxed); }
    void capture(const AudioBufferList *buffers,unsigned frames) {
        if(!enabled.load(std::memory_order_relaxed) || !frames || !buffers->mNumberBuffers) return;
        for(unsigned ch=0;ch<2;++ch) {
            const auto& buffer=buffers->mBuffers[std::min(ch,buffers->mNumberBuffers-1)];
            auto data=static_cast<const float*>(buffer.mData);
            if(!data) continue;
            const auto stride=std::max(1u,buffer.mNumberChannels);
            if(buffers->mNumberBuffers==1 && stride>1) data+=ch;
            float peak=0;
            vDSP_maxmgv(data,stride,&peak,frames);
            float old=peaks[ch].load(std::memory_order_relaxed);
            while(peak>old && !peaks[ch].compare_exchange_weak(old,peak,std::memory_order_relaxed)) {}
        }
    }
    float take(NSUInteger channel) {
        return channel<peaks.size() ? peaks[channel].exchange(0,std::memory_order_relaxed) : 0;
    }
};
// Storage is prepared on the control thread. The render block uses only
// bounded arithmetic and atomic snapshots, never locks, files or allocations.
struct EffectAnalysis {
    static constexpr unsigned capacity=8192, window=2048;
    std::array<std::atomic<float>,capacity> samples, rightSamples;
    std::atomic<uint64_t> head{0};
    std::atomic<bool> enabled{false}, resetRequested{false};
    std::atomic<float> left{0},right{0};
    uint64_t consumed=0, enabledAt=0;
    EffectAnalysis() { for(auto& sample:samples) sample.store(0,std::memory_order_relaxed); for(auto& sample:rightSamples) sample.store(0,std::memory_order_relaxed); }
    void capture(AudioBufferList *buffers,unsigned frames) {
        if(!enabled.load(std::memory_order_relaxed) || buffers->mNumberBuffers<1) return;
        const auto &leftBuffer=buffers->mBuffers[0];
        const auto &rightBuffer=buffers->mBuffers[std::min(1u,buffers->mNumberBuffers-1)];
        const float *l=static_cast<float*>(leftBuffer.mData), *r=static_cast<float*>(rightBuffer.mData);
        const auto leftStride=std::max(1u,leftBuffer.mNumberChannels), rightStride=std::max(1u,rightBuffer.mNumberChannels);
        if(!l || !r) return;
        if(buffers->mNumberBuffers==1 && leftStride>1) ++r;
        auto next=head.load(std::memory_order_relaxed);
        float pl=0,pr=0;
        for(unsigned i=0;i<frames;i++) {
            const float lv=l[i*leftStride], rv=r[i*rightStride];
            samples[next%capacity].store(lv,std::memory_order_relaxed);
            rightSamples[next++%capacity].store(rv,std::memory_order_relaxed);
            pl=std::max(pl,fabsf(lv)); pr=std::max(pr,fabsf(rv));
        }
        left.store(std::max(left.load(std::memory_order_relaxed),pl),std::memory_order_relaxed);
        right.store(std::max(right.load(std::memory_order_relaxed),pr),std::memory_order_relaxed);
        head.store(next,std::memory_order_release);
    }
    NSData *snapshot() {
        const auto end=head.load(std::memory_order_acquire);
        if(end<window || end==consumed || end-enabledAt<window) return nil;
        float frame[window*2];
        for(unsigned i=0;i<window;i++) { frame[i]=samples[(end-window+i)%capacity].load(std::memory_order_relaxed); frame[window+i]=rightSamples[(end-window+i)%capacity].load(std::memory_order_relaxed); }
        if(head.load(std::memory_order_acquire)-end>capacity-window) return nil;
        consumed=end;
        return [NSData dataWithBytes:frame length:sizeof(frame)];
    }
};

@implementation JarasAudioAnalysisProbe {
    std::shared_ptr<EffectAnalysis> storage;
    __weak AVAudioNode *observedNode;
}
- (instancetype)init { if ((self=[super init])) storage=std::make_shared<EffectAnalysis>(); return self; }
- (void)attachToNode:(AVAudioNode *)node {
    if(observedNode==node) return;
    [self detach];
    observedNode=node;
    storage->consumed=storage->head.load(); storage->enabledAt=storage->consumed;
    storage->enabled.store(true);
    auto capture=storage;
    [node installTapOnBus:0 bufferSize:1024 format:nil block:^(AVAudioPCMBuffer *buffer, AVAudioTime *time) {
        if(buffer.format.commonFormat==AVAudioPCMFormatFloat32) capture->capture(buffer.mutableAudioBufferList,buffer.frameLength);
    }];
}
- (void)detach {
    storage->enabled.store(false);
    if(observedNode) [observedNode removeTapOnBus:0];
    observedNode=nil; storage->left.store(0); storage->right.store(0);
}
- (void)dealloc { [self detach]; }
- (NSData *)frame { return storage->enabled.load() ? storage->snapshot() : nil; }
- (NSArray<NSNumber *> *)takePeaks { return @[@(storage->left.exchange(0)),@(storage->right.exchange(0))]; }
@end

struct VoiceGainKernel {
    std::atomic<bool> enabled{true};
    std::atomic<float> gain{1};
    float current=1;
    std::atomic<bool> resetRequested{true};
    unsigned capacity=0, channels=0;
    std::vector<float> silence;
};
@interface JarasVoiceGainUnit : AUAudioUnit {
@public VoiceGainKernel gain;
    AUAudioUnitBus *_input, *_output;
    AUAudioUnitBusArray *_inputs, *_outputs;
}
@end
@implementation JarasVoiceGainUnit
- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    if((self=[super initWithComponentDescription:d options:o error:e])) {
        AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        _input=[[AUAudioUnitBus alloc] initWithFormat:format error:e];
        _output=[[AUAudioUnitBus alloc] initWithFormat:format error:e];
        _inputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_input]];
        _outputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_output]];
        self.maximumFramesToRender=4096;
    } return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if(![super allocateRenderResourcesAndReturnError:error]) return NO;
    gain.capacity=self.maximumFramesToRender; gain.channels=_output.format.channelCount;
    gain.silence.assign(gain.capacity*gain.channels,0);
    gain.resetRequested.store(true,std::memory_order_release);
    return YES;
}
- (void)reset { [super reset]; gain.resetRequested.store(true,std::memory_order_release); }
- (AUInternalRenderBlock)internalRenderBlock {
    VoiceGainKernel *state=&gain;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,AVAudioFrameCount frames,NSInteger bus,AudioBufferList *output,const AURenderEvent *events,AURenderPullInputBlock pull) {
        ScopedAudioDenormals denormals;
        if(frames>state->capacity) return kAudioUnitErr_TooManyFramesToProcess;
        if(!state->enabled.load(std::memory_order_acquire)) {
            for(unsigned ch=0;ch<output->mNumberBuffers && ch<state->channels;++ch) {
                auto& buffer=output->mBuffers[ch];
                if(!buffer.mData) buffer.mData=state->silence.data()+ch*state->capacity;
                buffer.mDataByteSize=frames*sizeof(float)*buffer.mNumberChannels;
                memset(buffer.mData,0,buffer.mDataByteSize);
            }
            if(flags) *flags |= kAudioUnitRenderAction_OutputIsSilence;
            return noErr;
        }
        if(!pull) return kAudioUnitErr_NoConnection;
        auto status=pull(flags,time,frames,0,output);
        if(status!=noErr) return status;
        const float target=state->gain.load(std::memory_order_relaxed);
        if(state->resetRequested.exchange(false,std::memory_order_acq_rel)) state->current=target;
        unsigned frame=0;
        for(;frame<frames && state->current!=target;++frame) {
            float next=state->current+(target-state->current)*0.02f;
            if(std::abs(target-next)<1e-6f) next=target;
            // Float interpolation can reach a fixed point before the epsilon
            // (especially above unity). Preserve that exact gain and process
            // the rest of the block contiguously instead of ramping forever.
            if(next==state->current) break;
            state->current=next;
            for(unsigned ch=0;ch<output->mNumberBuffers;++ch) {
                const auto& buffer=output->mBuffers[ch]; auto data=static_cast<float*>(buffer.mData);
                if(data) for(unsigned channel=0;channel<buffer.mNumberChannels;++channel) data[frame*buffer.mNumberChannels+channel]*=state->current;
            }
        }
        if(state->current!=1) for(unsigned ch=0;ch<output->mNumberBuffers;++ch) {
            const auto& buffer=output->mBuffers[ch]; auto data=static_cast<float*>(buffer.mData);
            if(data) scaleAudioBlock(data+frame*buffer.mNumberChannels,(frames-frame)*buffer.mNumberChannels,state->current);
        }
        return noErr;
    };
}
@end
@implementation JarasVoiceGain
+ (AVAudioUnitEffect *)makeNode {
    static dispatch_once_t once;
    AudioComponentDescription d={kAudioUnitType_Effect,'JLvg','Jara',0,0};
    dispatch_once(&once, ^{ [AUAudioUnit registerSubclass:JarasVoiceGainUnit.class asComponentDescription:d name:@"CatLive Item Gain" version:1]; });
    return [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:d];
}
+ (void)setDecibels:(AVAudioUnitEffect *)node decibels:(double)decibels {
    auto *unit=(JarasVoiceGainUnit*)node.AUAudioUnit;
    unit->gain.gain.store(float(std::pow(10,std::clamp(std::isfinite(decibels)?decibels:0.0,-96.0,24.0)/20)),std::memory_order_relaxed);
}
+ (void)setRenderEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled {
    auto *unit=(JarasVoiceGainUnit*)node.AUAudioUnit;
    unit->gain.enabled.store(enabled,std::memory_order_release);
}
@end

// Sample-clock item envelope, independent of UI timers and repeated source
// segments. The control thread publishes bounded atomic snapshots; rendering
// never allocates, locks, or rebuilds the graph.
struct ItemFadeKernel {
    std::atomic<uint64_t> boundaryHost{0};
    void gate(AudioBufferList* buffers,unsigned frames,const AudioTimeStamp* time) {
        const auto end=boundaryHost.load(std::memory_order_relaxed);
        if(!end || !(time->mFlags&kAudioTimeStampHostTimeValid)) return;
        const double remaining=(double(end)-double(time->mHostTime))*hostSecondsPerTick;
        if(remaining>double(frames)/rate+0.003) return;
        for(unsigned frame=0;frame<frames;++frame) {
            const float gain=float(curve((remaining-double(frame)/rate)/0.003));
            for(unsigned ch=0;ch<buffers->mNumberBuffers;++ch) {
                auto& buffer=buffers->mBuffers[ch]; auto data=static_cast<float*>(buffer.mData);
                if(data) for(unsigned channel=0;channel<buffer.mNumberChannels;++channel) data[frame*buffer.mNumberChannels+channel]*=gain;
            }
        }
    }
    std::array<std::atomic<double>,6> pending{};
    std::atomic<unsigned> generation{0};
    unsigned consumedGeneration=~0u;
    double parameters[6]{};
    double rate=48000;
    const double hostSecondsPerTick=[] {
        mach_timebase_info_data_t timebase{};
        mach_timebase_info(&timebase);
        return double(timebase.numer)/double(timebase.denom)*1e-9;
    }();
    void configure(double in,double out,double duration,double position,uint64_t host,double sample) {
        generation.fetch_add(1,std::memory_order_acq_rel);
        const double values[]={in,out,duration,position,host?double(host)*hostSecondsPerTick:0,sample};
        for(unsigned i=0;i<6;++i) pending[i].store(values[i],std::memory_order_relaxed);
        generation.fetch_add(1,std::memory_order_release);
    }
    static double curve(double t) { t=std::clamp(t,0.0,1.0); return t*t*(3-2*t); }
    void process(AudioBufferList* buffers,unsigned frames,const AudioTimeStamp* time) {
        const auto before=generation.load(std::memory_order_acquire);
        if(!(before&1) && before!=consumedGeneration) {
            double values[6];
            for(unsigned i=0;i<6;++i) values[i]=pending[i].load(std::memory_order_relaxed);
            if(generation.load(std::memory_order_acquire)==before) { std::copy(values,values+6,parameters); consumedGeneration=before; }
        }
        const double duration=parameters[2];
        const double in=std::min(duration,parameters[0]), out=std::min(duration,parameters[1]);
        if(duration<=0 || (in<=0 && out<=0)) return;
        double position=parameters[3];
        if(parameters[4]>0 && (time->mFlags&kAudioTimeStampHostTimeValid))
            position+=double(time->mHostTime)*hostSecondsPerTick-parameters[4];
        else if(time->mFlags&kAudioTimeStampSampleTimeValid) position+=(time->mSampleTime-parameters[5])/rate;
        else return;
        // Outside both edge ramps the envelope is exactly unity. Keep the
        // original sample loop for blocks crossing an edge or overlapping fades.
        if(!frames || ((in<=0 || position>=in) &&
           (out<=0 || duration-(position+double(frames-1)/rate)>=out))) return;
        for(unsigned frame=0;frame<frames;++frame) {
            const double t=position+double(frame)/rate;
            const float gain=float((in>0?curve(t/in):1)*(out>0?curve((duration-t)/out):1));
            for(unsigned ch=0;ch<buffers->mNumberBuffers;++ch) {
                auto& buffer=buffers->mBuffers[ch]; auto data=static_cast<float*>(buffer.mData);
                if(!data) continue;
                for(unsigned channel=0;channel<buffer.mNumberChannels;++channel) data[frame*buffer.mNumberChannels+channel]*=gain;
            }
        }
    }
};
static constexpr unsigned kSections=160;
struct EQKernel {
    ItemFadeKernel fade;
    StereoLevelPeaks outputPeaks;
    std::unique_ptr<EffectAnalysis> inputStorage, outputStorage;
    std::atomic<EffectAnalysis*> inputAnalysis{nullptr}, outputAnalysis{nullptr};
    std::array<std::array<std::atomic<double>,5>,kSections> pending;
    double coefficients[kSections][5] = {}, z1[2][kSections] = {}, z2[2][kSections] = {};
    std::atomic<unsigned> count{0}, generation{0};
    double desired[kSections][5] = {};
    unsigned activeSections=0;
    unsigned consumedGeneration=~0u;
    bool coefficientsSettled=false;
    std::atomic<bool> enabled{false}, resetRequested{false};
    std::atomic<double> inputGain{1};
    std::atomic<double> inputPan{0};
    std::atomic<bool> inverted{false};
    std::atomic<int> channelMode{0};
    double channelMatrix[4] = {1,0,0,1};
    double currentInputGain=1;
    double currentInputPan=0;
    bool inputGainInitialized=false;
    double mix=0;
    EQKernel() { for(unsigned n=0;n<kSections;n++) for(unsigned j=0;j<5;j++) { pending[n][j].store(j==0?1:0); coefficients[n][j]=j==0?1:0; desired[n][j]=j==0?1:0; } }
    void process(AudioBufferList *buffers, unsigned frames) {
        if (resetRequested.exchange(false, std::memory_order_acq_rel)) {
            for (unsigned ch=0; ch<2; ++ch) for (unsigned n=0; n<kSections; ++n) z1[ch][n]=z2[ch][n]=0;
            inputGainInitialized=false;
        }
        const int mode=channelMode.load(std::memory_order_relaxed);
        const double matrices[4][4]={{1,0,0,1},{1,0,1,0},{0,1,0,1},{0.5,0.5,0.5,0.5}};
        const auto &matrixTarget=matrices[std::clamp(mode,0,3)];
        if(!inputGainInitialized) std::copy(matrixTarget,matrixTarget+4,channelMatrix);
        if(buffers->mNumberBuffers>=2 && (mode!=0 || channelMatrix[0]!=1 || channelMatrix[3]!=1)) {
            auto left=static_cast<float*>(buffers->mBuffers[0].mData);
            auto right=static_cast<float*>(buffers->mBuffers[1].mData);
            if(left && right) for(unsigned frame=0;frame<frames;frame++) {
                for(int i=0;i<4;i++) { channelMatrix[i]+=(matrixTarget[i]-channelMatrix[i])*0.02; if(std::abs(matrixTarget[i]-channelMatrix[i])<1e-9) channelMatrix[i]=matrixTarget[i]; }
                const float l=left[frame], r=right[frame];
                left[frame]=float(l*channelMatrix[0]+r*channelMatrix[1]);
                right[frame]=float(l*channelMatrix[2]+r*channelMatrix[3]);
            }
        }
        const double gain=inputGain.load(std::memory_order_relaxed)*(inverted.load(std::memory_order_relaxed)?-1:1);
        const double pan=inputPan.load(std::memory_order_relaxed);
        if(!inputGainInitialized) { currentInputGain=gain; currentInputPan=pan; inputGainInitialized=true; }
        if(gain!=1 || currentInputGain!=1 || pan!=0 || currentInputPan!=0) {
            unsigned frame=0;
            // Smooth only parameter changes. Once settled, use a contiguous
            // channel pass that the compiler can vectorize instead of doing
            // control interpolation and channel lookup for every sample.
            for(;frame<frames && (currentInputGain!=gain || currentInputPan!=pan);frame++) {
                currentInputGain += (gain-currentInputGain)*0.02;
                if(std::abs(gain-currentInputGain)<1e-9) currentInputGain=gain;
                currentInputPan += (pan-currentInputPan)*0.02;
                if(std::abs(pan-currentInputPan)<1e-9) currentInputPan=pan;
                for(unsigned ch=0;ch<std::min(2u,buffers->mNumberBuffers);ch++) {
                    auto data=static_cast<float*>(buffers->mBuffers[ch].mData);
                    // Stereo balance matches the existing mixer: center is
                    // unity, with only the opposite channel attenuated.
                    const double balance=ch==0 ? 1-std::max(0.0,currentInputPan) : 1+std::min(0.0,currentInputPan);
                    if(data) data[frame]*=float(currentInputGain*balance);
                }
            }
            for(unsigned ch=0;ch<std::min(2u,buffers->mNumberBuffers);ch++) {
                auto data=static_cast<float*>(buffers->mBuffers[ch].mData);
                if(!data) continue;
                const float scale=float(gain*(ch==0 ? 1-std::max(0.0,pan) : 1+std::min(0.0,pan)));
                if(scale==1) continue;
                scaleAudioBlock(data+frame,frames-frame,scale);
            }
        }
        const auto before=generation.load(std::memory_order_acquire);
        const auto requested=std::min(kSections,count.load(std::memory_order_acquire));
        const bool on=enabled.load(std::memory_order_relaxed);
        if(!on && mix==0) return;
        double target[kSections][5];
        if((before&1)==0 && before!=consumedGeneration) {
            for(unsigned n=0;n<requested;n++) for(unsigned j=0;j<5;j++) target[n][j]=pending[n][j].load(std::memory_order_relaxed);
            if(generation.load(std::memory_order_acquire)==before) {
                activeSections=requested;
                consumedGeneration=before; coefficientsSettled=false;
                for(unsigned n=0;n<requested;n++) for(unsigned j=0;j<5;j++) desired[n][j]=target[n][j];
            }
        }
        const auto sections=activeSections;
        for(unsigned frame=0;frame<frames;frame++) {
            const double targetMix=on?1.0:0.0;
            if(mix!=targetMix) { mix += (targetMix-mix)*0.02; if(std::abs(targetMix-mix)<(on?1e-14:1e-6)) mix=targetMix; }
            if(!coefficientsSettled) {
                coefficientsSettled=true;
                for(unsigned n=0;n<sections;n++) for(unsigned j=0;j<5;j++) {
                    auto& value=coefficients[n][j]; const auto target=desired[n][j];
                    value+=(target-value)*0.02;
                    if(std::abs(target-value)<1e-14*std::max(1.0,std::abs(target))) value=target;
                    else coefficientsSettled=false;
                }
            }
            for(unsigned ch=0;ch<std::min(2u,buffers->mNumberBuffers);ch++) {
                auto data=static_cast<float*>(buffers->mBuffers[ch].mData); if(!data) continue;
                double dry=data[frame], value=dry;
                for(unsigned n=0;n<sections;n++) {
                    auto k=coefficients[n];
                    double out=k[0]*value+z1[ch][n];
                    z1[ch][n]=k[1]*value-k[3]*out+z2[ch][n];
                    z2[ch][n]=k[2]*value-k[4]*out;
                    value=out;
                }
                if(!std::isfinite(value)) {
                    for(unsigned n=0;n<sections;n++) z1[ch][n]=z2[ch][n]=0;
                    value=0;
                }
                data[frame]=float(dry+(value-dry)*mix);
            }
        }
    }
};
@interface JarasEQAudioUnit : AUAudioUnit {
@public EQKernel kernel;
    AUAudioUnitBus *_input, *_output;
    AUAudioUnitBusArray *_inputs, *_outputs;
}
@end
@implementation JarasEQAudioUnit
- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    if((self=[super initWithComponentDescription:d options:o error:e])) {
        AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        _input=[[AUAudioUnitBus alloc] initWithFormat:format error:e];
        _output=[[AUAudioUnitBus alloc] initWithFormat:format error:e];
        _inputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_input]];
        _outputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_output]];
    } return self;
}
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if(![super allocateRenderResourcesAndReturnError:error]) return NO;
    kernel.fade.rate=_output.format.sampleRate;
    return YES;
}
- (void)reset { [super reset]; kernel.resetRequested.store(true, std::memory_order_release); }
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (AUInternalRenderBlock)internalRenderBlock {
    EQKernel *state=&kernel;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,AVAudioFrameCount frames,NSInteger bus,AudioBufferList *output,const AURenderEvent *events,AURenderPullInputBlock pull) {
        ScopedAudioDenormals denormals;
        if(!pull) return kAudioUnitErr_NoConnection;
        auto status=pull(flags,time,frames,0,output);
        if(status==noErr) {
            state->fade.process(output,frames,time);
            state->fade.gate(output,frames,time);
            if(auto analysis=state->inputAnalysis.load(std::memory_order_acquire)) analysis->capture(output,frames);
            state->process(output,frames);
            if(auto analysis=state->outputAnalysis.load(std::memory_order_acquire)) analysis->capture(output,frames);
            state->outputPeaks.capture(output,frames);
        }
        return status;
    };
}
@end
@implementation JarasEqualizer
+ (void)setOutputMeteringEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled {
    auto &peaks=((JarasEQAudioUnit *)node.AUAudioUnit)->kernel.outputPeaks;
    peaks.enabled.store(enabled,std::memory_order_relaxed);
    if(!enabled) { peaks.take(0); peaks.take(1); }
}
+ (float)takeOutputPeak:(AVAudioUnitEffect *)node channel:(NSUInteger)channel {
    return ((JarasEQAudioUnit *)node.AUAudioUnit)->kernel.outputPeaks.take(channel);
}
+ (AVAudioUnitEffect *)makeNode {
    static dispatch_once_t once;
    AudioComponentDescription d={kAudioUnitType_Effect,'JLEQ','Jara',0,0};
    dispatch_once(&once, ^{ [AUAudioUnit registerSubclass:JarasEQAudioUnit.class asComponentDescription:d name:@"CatLive EQ" version:1]; });
    return [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:d];
}
+ (void)configure:(AVAudioUnitEffect *)node coefficients:(NSArray<NSArray<NSNumber *> *> *)values enabled:(BOOL)enabled {
    JarasEQAudioUnit *unit=(JarasEQAudioUnit *)node.AUAudioUnit;
    unit->kernel.generation.fetch_add(1,std::memory_order_acq_rel);
    auto count=std::min<NSUInteger>(kSections,values.count);
    for(NSUInteger n=0;n<count;n++) if(values[n].count==5) for(unsigned j=0;j<5;j++) unit->kernel.pending[n][j].store(values[n][j].doubleValue,std::memory_order_relaxed);
    unit->kernel.count.store((unsigned)count,std::memory_order_release);
    unit->kernel.enabled.store(enabled,std::memory_order_relaxed);
    unit->kernel.generation.fetch_add(1,std::memory_order_release);
}
+ (void)setPlaybackBoundary:(AVAudioUnitEffect *)node hostTime:(uint64_t)hostTime {
    ((JarasEQAudioUnit *)node.AUAudioUnit)->kernel.fade.boundaryHost.store(hostTime,std::memory_order_relaxed);
}
+ (void)setInputFade:(AVAudioUnitEffect *)node fadeIn:(double)fadeIn fadeOut:(double)fadeOut duration:(double)duration position:(double)position hostTime:(uint64_t)hostTime sampleTime:(double)sampleTime {
    if(!std::isfinite(fadeIn)||!std::isfinite(fadeOut)||!std::isfinite(duration)||!std::isfinite(position)||!std::isfinite(sampleTime)) return;
    ((JarasEQAudioUnit *)node.AUAudioUnit)->kernel.fade.configure(std::max(0.0,fadeIn),std::max(0.0,fadeOut),std::max(0.0,duration),position,hostTime,sampleTime);
}
+ (void)setInputChannelMode:(AVAudioUnitEffect *)node mode:(int)mode {
    ((JarasEQAudioUnit *)node.AUAudioUnit)->kernel.channelMode.store(std::clamp(mode,0,3),std::memory_order_relaxed);
}
+ (void)setInputPan:(AVAudioUnitEffect *)node pan:(double)pan {
    if(!std::isfinite(pan)) return;
    ((JarasEQAudioUnit *)node.AUAudioUnit)->kernel.inputPan.store(std::clamp(pan,-1.0,1.0),std::memory_order_relaxed);
}
+ (void)setPolarity:(AVAudioUnitEffect *)node inverted:(BOOL)inverted {
    ((JarasEQAudioUnit *)node.AUAudioUnit)->kernel.inverted.store(inverted,std::memory_order_relaxed);
}
+ (void)setInputGain:(AVAudioUnitEffect *)node gain:(double)gain {
    if(std::isfinite(gain)) ((JarasEQAudioUnit *)node.AUAudioUnit)->kernel.inputGain.store(std::clamp(gain,0.0,std::pow(10.0,24.0/20.0)),std::memory_order_relaxed);
}
+ (void)setAnalysisEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled {
    auto &kernel=((JarasEQAudioUnit *)node.AUAudioUnit)->kernel;
    auto configure=[&](std::unique_ptr<EffectAnalysis>& storage, std::atomic<EffectAnalysis*>& published) {
        if(enabled) {
            if(!storage) storage=std::make_unique<EffectAnalysis>();
            if(storage->enabled.exchange(true,std::memory_order_relaxed)) return;
            storage->consumed=storage->head.load(std::memory_order_acquire);
            storage->enabledAt=storage->consumed;
            published.store(storage.get(),std::memory_order_release);
        } else {
            published.store(nullptr,std::memory_order_release);
            if(storage) storage->enabled.store(false,std::memory_order_relaxed);
        }
    };
    // Allocation and publication happen on the control thread. Disabled EQs
    // retain no capture work; storage stays alive until the AU leaves the graph.
    configure(kernel.inputStorage,kernel.inputAnalysis);
    configure(kernel.outputStorage,kernel.outputAnalysis);
}
+ (NSData *)analysisFrame:(AVAudioUnitEffect *)node input:(BOOL)input {
    auto &kernel=((JarasEQAudioUnit *)node.AUAudioUnit)->kernel;
    auto analysis=(input?kernel.inputAnalysis:kernel.outputAnalysis).load(std::memory_order_acquire);
    return analysis?analysis->snapshot():nil;
}
@end

#include <vector>
#include <algorithm>
struct DynamicsKernel {
    EffectAnalysis inputAnalysis, outputAnalysis;
    bool reverb = false, limiter = false;
    double rate = 48000, envelope = 0, gain = 1, mix = 0;
    std::atomic<bool> enabled{false}, resetRequested{false};
    std::atomic<bool> meteringEnabled{false};
    std::array<std::atomic<double>,6> params;
    std::array<std::atomic<float>,4> peaks;
    std::array<std::vector<float>,8> delays;
    std::array<unsigned,8> positions{};
    std::array<double,8> damping{};
    double lowState[2]{}, highState[2]{};
    DynamicsKernel() { for(auto &v:params) v.store(0); for(auto &v:peaks) v.store(0); }
    void prepare(double sampleRate) {
        rate=sampleRate; envelope=0; gain=1; mix=0;
        positions.fill(0); damping.fill(0);
        for(auto &v:peaks) v.store(0);
        for(unsigned ch=0;ch<2;ch++) lowState[ch]=highState[ch]=0;
        if(reverb) for(auto &line:delays) line.assign(unsigned(rate*.18)+1,0);
    }
    void process(AudioBufferList *buffers, unsigned frames) {
        if (resetRequested.exchange(false, std::memory_order_acq_rel)) {
            envelope=0; gain=1; positions.fill(0); damping.fill(0);
            for (auto& line : delays) std::fill(line.begin(), line.end(), 0);
            for (unsigned ch=0; ch<2; ++ch) lowState[ch]=highState[ch]=0;
            for (auto& peak : peaks) peak.store(0);
        }

        const bool on=enabled.load(std::memory_order_relaxed);
        // Most per-item chains are prepared but bypassed. Preserve the ramp
        // when switching off, and read peaks only while an editor needs them.
        if (!reverb && !on && !meteringEnabled.load(std::memory_order_relaxed) && fabs(gain-1)<1e-7) {
            gain=1; envelope=0; return;
        }
        if(buffers->mNumberBuffers<1 || (!limiter && buffers->mNumberBuffers<2)) return;
        auto l=static_cast<float*>(buffers->mBuffers[0].mData), r=static_cast<float*>(buffers->mBuffers[buffers->mNumberBuffers>1?1:0].mData);
        if(!l || !r) return;
        float observed[4]{};
        if(limiter) {
            // Zero-latency, stereo-linked sample-peak limiter. No allocations,
            // locks or look-ahead delay in render. Fast attack catches even a
            // single-sample transient; exponential release restores the gain.
            const double inputGain=pow(10,params[0].load(std::memory_order_relaxed)/20);
            const double ceiling=pow(10,params[1].load(std::memory_order_relaxed)/20);
            const double release=exp(-1/(rate*std::max(.01,params[2].load(std::memory_order_relaxed))));
            const bool metering=meteringEnabled.load(std::memory_order_relaxed);
            for(unsigned i=0;i<frames;i++) {
                const double left=l[i], right=r[i];
                if(metering) { observed[0]=std::max(observed[0],fabsf(l[i])); observed[1]=std::max(observed[1],fabsf(r[i])); }
                const double peak=std::max(fabs(left),fabs(right))*inputGain;
                const double target=on?inputGain*std::min(1.0,ceiling/std::max(1e-20,peak)):1;
                gain=on && target<gain?target:target+(gain-target)*release;
                l[i]=float(left*gain); r[i]=float(right*gain);
                if(metering) { observed[2]=std::max(observed[2],fabsf(l[i])); observed[3]=std::max(observed[3],fabsf(r[i])); }
            }
            if(metering) for(unsigned ch=0;ch<4;ch++) {
                float previous=peaks[ch].load(std::memory_order_relaxed);
                peaks[ch].store(std::max(previous,observed[ch]),std::memory_order_relaxed);
            }
            return;
        }
        if(!reverb) {
            const double threshold=params[0].load(), ratio=std::max(1.0,params[1].load());
            const double thresholdAmplitude=pow(10,threshold/20);
            const bool metering=meteringEnabled.load(std::memory_order_relaxed);
            const double attack=exp(-1/(rate*std::max(.0001,params[2].load()))), release=exp(-1/(rate*std::max(.01,params[3].load())));
            const double makeup=pow(10,params[4].load()/20), smoothing=1-exp(-1/(rate*.002));
            for(unsigned i=0;i<frames;i++) {
                const double peak=std::max(fabs(l[i]),fabs(r[i]));
                if(metering) { observed[0]=std::max(observed[0],fabsf(l[i])); observed[1]=std::max(observed[1],fabsf(r[i])); }
                if(!on && fabs(gain-1)<1e-7) {
                    gain=1; envelope=0;
                    if(metering) { observed[2]=observed[0]; observed[3]=observed[1]; }
                    continue;
                }
                // Stereo-linked detector keeps the image stable. Attack/release
                // smooth gain reduction in dB; Ratio is the actual transfer slope.
                const double reduction=peak>thresholdAmplitude ? (20*log10(peak)-threshold)*(1-1/ratio) : 0;
                const double coefficient=reduction>envelope?attack:release;
                envelope=coefficient*envelope+(1-coefficient)*reduction;
                const double target=on?(envelope==0?makeup:pow(10,-envelope/20)*makeup):1;
                gain+=(target-gain)*smoothing;
                l[i]*=gain; r[i]*=gain;
                if(metering) { observed[2]=std::max(observed[2],fabsf(l[i])); observed[3]=std::max(observed[3],fabsf(r[i])); }
            }
            if(metering) for(unsigned ch=0;ch<4;ch++) {
                // Only the renderer writes peaks; UI exchange clears the window.
                float previous=peaks[ch].load(std::memory_order_relaxed);
                peaks[ch].store(std::max(previous,observed[ch]),std::memory_order_relaxed);
            }
            return;
        }
        if(!on && mix<1e-6) { mix=0; return; }
        const unsigned space=std::min(2u,unsigned(std::max(0.0,params[0].load())));
        const double targetMix=on?params[1].load()*.01:0;
        const double decay=std::max(.1,params[2].load());
        const double hp=exp(-2*M_PI*params[3].load()/rate), lp=1-exp(-2*M_PI*std::min(rate*.45,params[4].load())/rate);
        const double smooth=1-exp(-1/(rate*.01));
        // Eight mutually prime delay lengths, orthogonal Householder feedback.
        // RT60 is calibrated independently of room size. Plate uses dense short
        // reflections; Hall longer diffuse reflections; Room a smaller space.
        static const double times[3][8]={{.0191,.0239,.0293,.0317,.0371,.0419,.0437,.0479},{.0473,.0531,.0617,.0713,.0797,.0893,.1013,.1139},{.0113,.0137,.0179,.0199,.0233,.0271,.0299,.0313}};
        unsigned lengths[8]; double feedback[8];
        for(unsigned n=0;n<8;n++) { lengths[n]=std::min(unsigned(delays[n].size()),std::max(1u,unsigned(times[space][n]*rate))); feedback[n]=pow(.001,double(lengths[n])/rate/decay); positions[n]%=lengths[n]; }
        const double damp=space==2?.72:(space==1?.46:.6);
        for(unsigned frame=0;frame<frames;frame++) {
            mix+=(targetMix-mix)*smooth;
            double values[8],sum=0,wetL=0,wetR=0;
            for(unsigned n=0;n<8;n++) { double v=delays[n][positions[n]]; damping[n]+=damp*(v-damping[n]); values[n]=damping[n]; sum+=values[n]; }
            for(unsigned n=0;n<8;n++) {
                double input=(n&1?r[frame]:l[frame])*.24;
                // I - 2/N * ones is energy-preserving before RT60 attenuation.
                double value=input+(values[n]-.25*sum)*feedback[n];
                delays[n][positions[n]]=std::isfinite(value)?float(value):0;
                // Block setup bounds every position below its current length.
                if(++positions[n]==lengths[n]) positions[n]=0;
                wetL+=values[n]*(n&2?-1:1)*.45;
                wetR+=values[n]*(n&1?-1:1)*.45;
            }
            double wet[2]={wetL,wetR};
            for(unsigned ch=0;ch<2;ch++) {
                lowState[ch]=(1-hp)*wet[ch]+hp*lowState[ch];
                highState[ch]+=lp*((wet[ch]-lowState[ch])-highState[ch]);
                auto data=ch?r:l;
                data[frame]=float(data[frame]*(1-mix)+highState[ch]*mix);
            }
        }
    }
};
@interface JarasDynamicsAudioUnit : AUAudioUnit {
@public DynamicsKernel kernel;
    AUAudioUnitBus *_input, *_output;
    AUAudioUnitBusArray *_inputs, *_outputs;
}
@end
@implementation JarasDynamicsAudioUnit
- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    if((self=[super initWithComponentDescription:d options:o error:e])) {
        kernel.reverb=d.componentSubType=='JLRV';
        kernel.limiter=d.componentSubType=='JLLM';
        AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        _input=[[AUAudioUnitBus alloc] initWithFormat:format error:e]; _output=[[AUAudioUnitBus alloc] initWithFormat:format error:e];
        _inputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_input]];
        _outputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_output]];
    } return self;
}
- (void)reset { [super reset]; kernel.resetRequested.store(true, std::memory_order_release); }
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if(![super allocateRenderResourcesAndReturnError:error]) return NO;
    kernel.prepare(_output.format.sampleRate); return YES;
}
- (AUInternalRenderBlock)internalRenderBlock {
    DynamicsKernel *state=&kernel;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,AVAudioFrameCount frames,NSInteger bus,AudioBufferList *output,const AURenderEvent *events,AURenderPullInputBlock pull) {
        ScopedAudioDenormals denormals;
        if(!pull) return kAudioUnitErr_NoConnection;
        auto status=pull(flags,time,frames,0,output);
        if(status==noErr) { state->inputAnalysis.capture(output,frames); state->process(output,frames); state->outputAnalysis.capture(output,frames); }
        return status;
    };
}
@end
// Fixed-order item EQ/compressor: one AU pull, the same DSP kernels and ramps.
// The node remains connected when either effect is enabled during playback.
@interface CatItemEQCompressorAudioUnit : JarasEQAudioUnit {
@public DynamicsKernel compressorKernel;
}
@end
@implementation CatItemEQCompressorAudioUnit
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if(![super allocateRenderResourcesAndReturnError:error]) return NO;
    compressorKernel.prepare(self.outputBusses[0].format.sampleRate);
    return YES;
}
- (void)reset { [super reset]; compressorKernel.resetRequested.store(true, std::memory_order_release); }
- (AUInternalRenderBlock)internalRenderBlock {
    EQKernel *eq=&kernel;
    DynamicsKernel *compressor=&compressorKernel;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,AVAudioFrameCount frames,NSInteger bus,AudioBufferList *output,const AURenderEvent *events,AURenderPullInputBlock pull) {
        ScopedAudioDenormals denormals;
        if(!pull) return kAudioUnitErr_NoConnection;
        const auto status=pull(flags,time,frames,0,output);
        if(status==noErr) {
            eq->fade.process(output,frames,time);
            eq->fade.gate(output,frames,time);
            if(auto analysis=eq->inputAnalysis.load(std::memory_order_acquire)) analysis->capture(output,frames);
            eq->process(output,frames);
            if(auto analysis=eq->outputAnalysis.load(std::memory_order_acquire)) analysis->capture(output,frames);
            compressor->inputAnalysis.capture(output,frames);
            compressor->process(output,frames);
            compressor->outputAnalysis.capture(output,frames);
            eq->outputPeaks.capture(output,frames);
        }
        return status;
    };
}
@end
static DynamicsKernel& dynamicsKernel(AVAudioUnitEffect *node) {
    AUAudioUnit *unit=node.AUAudioUnit;
    if([unit isKindOfClass:CatItemEQCompressorAudioUnit.class])
        return ((CatItemEQCompressorAudioUnit *)unit)->compressorKernel;
    return ((JarasDynamicsAudioUnit *)unit)->kernel;
}

@implementation JarasDynamics
 + (AVAudioUnitEffect *)makeItemEqualizerCompressor {
    static dispatch_once_t once;
    AudioComponentDescription d={kAudioUnitType_Effect,'CLIC','Jara',0,0};
    dispatch_once(&once, ^{
        [AUAudioUnit registerSubclass:CatItemEQCompressorAudioUnit.class asComponentDescription:d name:@"CatLive Item EQ/Compressor" version:1];
    });
    return [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:d];
}
+ (AVAudioUnitEffect *)make:(OSType)subtype {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for(NSNumber *type in @[@((unsigned)'JLCP'),@((unsigned)'JLRV'),@((unsigned)'JLLM')]) {
            AudioComponentDescription d={kAudioUnitType_Effect,type.unsignedIntValue,'Jara',0,0};
            [AUAudioUnit registerSubclass:JarasDynamicsAudioUnit.class asComponentDescription:d name:type.unsignedIntValue=='JLCP'?@"CatLive Compressor":(type.unsignedIntValue=='JLLM'?@"CatLive Limiter":@"CatLive Reverb") version:1];
        }
    });
    AudioComponentDescription d={kAudioUnitType_Effect,subtype,'Jara',0,0};
    return [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:d];
}
+ (AVAudioUnitEffect *)makeCompressor { return [self make:'JLCP']; }
+ (AVAudioUnitEffect *)makeReverb { return [self make:'JLRV']; }
+ (AVAudioUnitEffect *)makeLimiter { return [self make:'JLLM']; }
+ (void)configureLimiter:(AVAudioUnitEffect *)node enabled:(BOOL)enabled gain:(double)gain ceiling:(double)ceiling release:(double)release {
    auto &k=dynamicsKernel(node);
    if(!std::isfinite(gain) || !std::isfinite(ceiling) || !std::isfinite(release)) return;
    k.params[0].store(std::clamp(gain,-24.0,24.0),std::memory_order_relaxed);
    k.params[1].store(std::clamp(ceiling,-24.0,0.0),std::memory_order_relaxed);
    k.params[2].store(std::clamp(release,.01,3.0),std::memory_order_relaxed);
    k.enabled.store(enabled,std::memory_order_relaxed);
}
+ (void)configureCompressor:(AVAudioUnitEffect *)node enabled:(BOOL)enabled threshold:(double)threshold ratio:(double)ratio attack:(double)attack release:(double)release gain:(double)gain {
    auto &k=dynamicsKernel(node);
    const double values[]={threshold,ratio,attack,release,gain}; for(unsigned i=0;i<5;i++) k.params[i].store(values[i]); k.enabled.store(enabled);
}
+ (void)configureReverb:(AVAudioUnitEffect *)node enabled:(BOOL)enabled space:(NSInteger)space mix:(double)mix decay:(double)decay lowCut:(double)lowCut highCut:(double)highCut {
    auto &k=dynamicsKernel(node);
    const double values[]={double(space),mix,decay,lowCut,highCut}; for(unsigned i=0;i<5;i++) k.params[i].store(values[i]); k.enabled.store(enabled);
}
+ (void)setAnalysisEnabled:(AVAudioUnitEffect *)node input:(BOOL)input enabled:(BOOL)enabled {
    auto &k=dynamicsKernel(node);
    auto &analysis=input?k.inputAnalysis:k.outputAnalysis;
    if(analysis.enabled.exchange(enabled)==enabled) return;
    analysis.consumed=analysis.head.load();
    analysis.enabledAt=analysis.consumed;
    analysis.left.store(0); analysis.right.store(0);
}
+ (void)setCompressorMeteringEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled {
    dynamicsKernel(node).meteringEnabled.store(enabled, std::memory_order_relaxed);
}
+ (NSData *)analysisFrame:(AVAudioUnitEffect *)node input:(BOOL)input {
    auto &k=dynamicsKernel(node);
    return (input?k.inputAnalysis:k.outputAnalysis).snapshot();
}
+ (NSArray<NSNumber *> *)analysisPeaks:(AVAudioUnitEffect *)node input:(BOOL)input {
    auto &k=dynamicsKernel(node);
    auto &analysis=input?k.inputAnalysis:k.outputAnalysis;
    return @[@(analysis.left.exchange(0)),@(analysis.right.exchange(0))];
}
+ (NSArray<NSNumber *> *)takeCompressorPeaks:(AVAudioUnitEffect *)node {
    auto &k=dynamicsKernel(node);
    return @[@(k.peaks[0].exchange(0)),@(k.peaks[1].exchange(0)),@(k.peaks[2].exchange(0)),@(k.peaks[3].exchange(0))];
}
@end

// Stereo-to-hardware routing. Storage is allocated with the graph, never in render.
struct ChannelRouteKernel {
    StereoLevelPeaks inputPeaks;
    std::array<std::atomic<uint32_t>, 1024> destinations;
    ChannelRouteKernel() { for(auto& value : destinations) value.store(0, std::memory_order_relaxed); }
    std::atomic<bool> renderEnabled{true};
    std::atomic<bool> hasDestinations{false};
    std::atomic<bool> stopFadeRequested{false};
    std::vector<float> input, output, leftGain, rightGain, lastOutput, fadeOrigin;
    unsigned capacity=0, channels=0, stopFadeFrames=0, stopFadePosition=0;
    bool wasRendering=false;
    bool routingSilent=true;
    void prepare(unsigned frames,unsigned count,double rate) {
        capacity=frames; channels=count;
        input.assign(frames*2,0); output.assign(frames*count,0);
        leftGain.assign(count,0); rightGain.assign(count,0);
        lastOutput.assign(count,0); fadeOrigin.assign(count,0);
        stopFadeFrames=std::max(64u,static_cast<unsigned>(rate*0.005)); stopFadePosition=stopFadeFrames;
        wasRendering=false;
        routingSilent=true;
        stopFadeRequested.store(false,std::memory_order_relaxed);
    }
};
@interface JarasChannelRouteUnit : AUAudioUnit {
@public ChannelRouteKernel route;
    AUAudioUnitBus *_input, *_output;
    AUAudioUnitBusArray *_inputs, *_outputs;
}
@end
@implementation JarasChannelRouteUnit
- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    if ((self=[super initWithComponentDescription:d options:o error:e])) {
        AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        _input=[[AUAudioUnitBus alloc] initWithFormat:format error:e];
        _output=[[AUAudioUnitBus alloc] initWithFormat:format error:e];
        _output.maximumChannelCount=1024;
        _inputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_input]];
        _outputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_output]];
        self.maximumFramesToRender=4096;
    }
    return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    route.prepare(self.maximumFramesToRender,_output.format.channelCount,_output.format.sampleRate);
    return YES;
}
- (AUInternalRenderBlock)internalRenderBlock {
    ChannelRouteKernel *state=&route;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,AVAudioFrameCount frames,NSInteger bus,AudioBufferList *output,const AURenderEvent *events,AURenderPullInputBlock pull) {
        ScopedAudioDenormals denormals;
        if (frames>state->capacity) return kAudioUnitErr_TooManyFramesToProcess;
        const bool enabled=state->renderEnabled.load(std::memory_order_relaxed);
        const bool stopRequested=state->stopFadeRequested.exchange(false,std::memory_order_relaxed);
        if (!enabled || stopRequested || state->stopFadePosition<state->stopFadeFrames) {
            if (stopRequested || (!enabled && state->wasRendering)) {
                std::copy(state->lastOutput.begin(),state->lastOutput.end(),state->fadeOrigin.begin());
                state->stopFadePosition=0;
                state->wasRendering=false;
            }
            const unsigned fadePosition=state->stopFadePosition;
            const bool fading=fadePosition<state->stopFadeFrames;
            for(unsigned ch=0;ch<output->mNumberBuffers && ch<state->channels;ch++) {
                auto& buffer=output->mBuffers[ch];
                if(!buffer.mData) buffer.mData=state->output.data()+ch*state->capacity;
                buffer.mDataByteSize=frames*sizeof(float);
                auto *out=static_cast<float*>(buffer.mData);
                if (!fading || state->fadeOrigin[ch]==0) { memset(out,0,buffer.mDataByteSize); continue; }
                for(unsigned frame=0;frame<frames;frame++) {
                    const unsigned position=std::min(state->stopFadeFrames,fadePosition+frame+1);
                    out[frame]=state->fadeOrigin[ch]*(1-float(position)/float(state->stopFadeFrames));
                }
            }
            state->stopFadePosition=std::min(state->stopFadeFrames,fadePosition+frames);
            if (flags) {
                if (fading) *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
                else *flags |= kAudioUnitRenderAction_OutputIsSilence;
            }
            return noErr;
        }
        // A track without a direct hardware patch is already heard through
        // its master/group/internal sends. Do not pull that entire graph a
        // second time through a hardware route which produces only silence.
        // Let a removed patch finish its existing gain ramp before sleeping.
        // A pre-routing Master meter continues observing even without a patch.
        if (!state->hasDestinations.load(std::memory_order_acquire) && state->routingSilent &&
            !state->inputPeaks.enabled.load(std::memory_order_relaxed)) {
            for (unsigned ch=0; ch<output->mNumberBuffers && ch<state->channels; ++ch) {
                auto& buffer=output->mBuffers[ch];
                if (!buffer.mData) buffer.mData=state->output.data()+ch*state->capacity;
                buffer.mDataByteSize=frames*sizeof(float);
                memset(buffer.mData,0,buffer.mDataByteSize);
            }
            if (flags) *flags |= kAudioUnitRenderAction_OutputIsSilence;
            return noErr;
        }
        state->wasRendering=true;
        state->stopFadePosition=state->stopFadeFrames;
        if (!pull) return kAudioUnitErr_NoConnection;
        struct { UInt32 count; AudioBuffer buffers[2]; } input;
        input.count=2;
        for(unsigned ch=0;ch<2;ch++) input.buffers[ch]={1,UInt32(frames*sizeof(float)),state->input.data()+ch*state->capacity};
        auto status=pull(flags,time,frames,0,reinterpret_cast<AudioBufferList*>(&input));
        if(status!=noErr) return status;
        state->inputPeaks.capture(reinterpret_cast<AudioBufferList*>(&input),frames);
        const auto left=static_cast<const float*>(input.buffers[0].mData),right=static_cast<const float*>(input.buffers[1].mData);
        bool silentRouting=true;
        for(unsigned ch=0;ch<output->mNumberBuffers && ch<state->channels;ch++) {
            auto& buffer=output->mBuffers[ch];
            if(!buffer.mData) buffer.mData=state->output.data()+ch*state->capacity;
            buffer.mDataByteSize=frames*sizeof(float);
            auto out=static_cast<float*>(buffer.mData);
            const uint32_t gains=state->destinations[ch].load(std::memory_order_relaxed);
            const float l=float(gains & 0xffff) * 0.5f, r=float(gains >> 16) * 0.5f;
            float gl=state->leftGain[ch],gr=state->rightGain[ch];
            if(l==0 && r==0 && std::abs(gl)<1e-6f && std::abs(gr)<1e-6f) {
                state->leftGain[ch]=0; state->rightGain[ch]=0;
                state->lastOutput[ch]=0;
                memset(out,0,frames*sizeof(float)); continue;
            }
            // Keep the exact float fixed point reached by the ramp. Snapping
            // to its target would change PCM; a settled block only needs mixing.
            const float nextLeft=gl+(l-gl)*0.02f, nextRight=gr+(r-gr)*0.02f;
            if(nextLeft==gl && nextRight==gr) {
                for(unsigned frame=0;frame<frames;frame++)
                    out[frame]=(left ? left[frame]:0)*gl+(right ? right[frame]:0)*gr;
            } else for(unsigned frame=0;frame<frames;frame++) {
                gl+=(l-gl)*0.02f; gr+=(r-gr)*0.02f;
                out[frame]=(left ? left[frame]:0)*gl+(right ? right[frame]:0)*gr;
            }
            state->leftGain[ch]=gl; state->rightGain[ch]=gr;
            if(l!=0 || r!=0 || std::abs(gl)>=1e-6f || std::abs(gr)>=1e-6f) silentRouting=false;
            state->lastOutput[ch]=frames ? out[frames-1] : 0;
        }
        state->routingSilent=silentRouting;
        return noErr;
    };
}
@end
@implementation JarasChannelRouter
+ (void)setInputMeteringEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled {
    auto &peaks=((JarasChannelRouteUnit *)node.AUAudioUnit)->route.inputPeaks;
    peaks.enabled.store(enabled,std::memory_order_relaxed);
    if(!enabled) { peaks.take(0); peaks.take(1); }
}
+ (float)takeInputPeak:(AVAudioUnitEffect *)node channel:(NSUInteger)channel {
    return ((JarasChannelRouteUnit *)node.AUAudioUnit)->route.inputPeaks.take(channel);
}
+ (AVAudioUnitEffect *)makeNode {
    static dispatch_once_t once;
    AudioComponentDescription d={kAudioUnitType_Effect,'JLrt','Jara',0,0};
    dispatch_once(&once, ^{ [AUAudioUnit registerSubclass:JarasChannelRouteUnit.class asComponentDescription:d name:@"CatLive Channel Route" version:1]; });
    return [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:d];
}
+ (void)setRenderEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled {
    auto *unit=(JarasChannelRouteUnit*)node.AUAudioUnit;
    unit->route.renderEnabled.store(enabled,std::memory_order_relaxed);
}
+ (void)beginStopFade:(AVAudioUnitEffect *)node {
    auto *unit=(JarasChannelRouteUnit*)node.AUAudioUnit;
    unit->route.stopFadeRequested.store(true,std::memory_order_relaxed);
}
+ (void)configure:(AVAudioUnitEffect *)node first:(NSInteger)first count:(NSInteger)count {
    [self configurePatches:node firsts:@[@(first)] counts:@[@(count)]];
}
+ (void)configurePatches:(AVAudioUnitEffect *)node firsts:(NSArray<NSNumber *> *)firsts counts:(NSArray<NSNumber *> *)counts {
    // Build the hardware matrix on the control thread. Changing route count
    // needs no new audio units, graph rebuilds or render-time allocations.
    auto *unit=(JarasChannelRouteUnit*)node.AUAudioUnit;
    std::array<uint32_t,1024> gains{};
    std::set<std::pair<unsigned,unsigned>> seen;
    const unsigned channels=unit.outputBusses[0].format.channelCount;
    for (NSUInteger i=0; i<MIN(firsts.count, counts.count); ++i) {
        const NSInteger first=firsts[i].integerValue, count=counts[i].integerValue;
        if (first<1 || first>1024 || count<1 || count>2 || first+count-1>channels || !seen.insert({unsigned(first),unsigned(count)}).second) continue;
        if (count==1) gains[first-1] += (1u<<16)|1u;
        else { gains[first-1] += 2u; gains[first] += 2u<<16; }
    }
    for(unsigned i=0; i<1024; ++i) unit->route.destinations[i].store(gains[i],std::memory_order_relaxed);
    unit->route.hasDestinations.store(std::any_of(gains.begin(),gains.end(),[](uint32_t gain) { return gain!=0; }),std::memory_order_release);
}
@end

// One packed buffer serves all export lanes. Allocating a full multichannel
// buffer per track would grow memory quadratically with the number of tracks.
@interface JarasExportUnit : AUAudioUnit {
    AUAudioUnitBusArray *_exportInputs, *_exportOutputs;
    std::vector<float> _exportStorage;
}
@end
@implementation JarasExportUnit
- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    if ((self=[super initWithComponentDescription:d options:o error:e])) {
        AVAudioFormat *stereo=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        NSMutableArray *inputs=[NSMutableArray array];
        const unsigned count=std::clamp(unsigned(d.componentSubType-'JE00'),1u,512u);
        for(unsigned i=0;i<count;i++) [inputs addObject:[[AUAudioUnitBus alloc] initWithFormat:stereo error:e]];
        AVAudioChannelLayout *layout=[[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_DiscreteInOrder|(count*2)];
        AVAudioFormat *packed=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channelLayout:layout];
        AUAudioUnitBus *output=[[AUAudioUnitBus alloc] initWithFormat:packed error:e]; output.maximumChannelCount=1024;
        _exportInputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:inputs];
        _exportOutputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[output]];
        self.maximumFramesToRender=4096;
    }
    return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _exportInputs; }
- (AUAudioUnitBusArray *)outputBusses { return _exportOutputs; }
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if(![super allocateRenderResourcesAndReturnError:error]) return NO;
    _exportStorage.assign(self.maximumFramesToRender*_exportOutputs[0].format.channelCount,0);
    return YES;
}
- (AUInternalRenderBlock)internalRenderBlock {
    float *storage=_exportStorage.data();
    const unsigned capacity=self.maximumFramesToRender, channels=_exportOutputs[0].format.channelCount;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,AVAudioFrameCount frames,NSInteger bus,AudioBufferList *output,const AURenderEvent *events,AURenderPullInputBlock pull) {
        ScopedAudioDenormals denormals;
        if(!pull) return kAudioUnitErr_NoConnection;
        if(frames>capacity || output->mNumberBuffers!=channels) return kAudioUnitErr_TooManyFramesToProcess;
        for(unsigned ch=0;ch<channels;ch++) {
            if(!output->mBuffers[ch].mData) output->mBuffers[ch].mData=storage+ch*capacity;
            output->mBuffers[ch].mDataByteSize=frames*sizeof(float);
        }
        for(unsigned i=0;i<channels/2;i++) {
            struct { UInt32 count; AudioBuffer data[2]; } input;
            input.count=2; input.data[0]=output->mBuffers[i*2]; input.data[1]=output->mBuffers[i*2+1];
            AudioUnitRenderActionFlags inputFlags=0;
            auto status=pull(&inputFlags,time,frames,i,reinterpret_cast<AudioBufferList*>(&input));
            if(status!=noErr) return status;
            for(unsigned c=0;c<2;c++) {
                void *destination=output->mBuffers[i*2+c].mData;
                if(inputFlags & kAudioUnitRenderAction_OutputIsSilence) memset(destination,0,frames*sizeof(float));
                else if(input.data[c].mData!=destination) memcpy(destination,input.data[c].mData,frames*sizeof(float));
            }
        }
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    };
}
@end
@implementation JarasExportMultiplexer
 + (AVAudioUnitEffect *)makeNode:(NSInteger)outputs {
    const unsigned count=unsigned(std::clamp(outputs,NSInteger(1),NSInteger(512)));
    AudioComponentDescription d={kAudioUnitType_Effect,OSType('JE00'+count),'Jara',0,0};
    @synchronized(self) {
        static NSMutableSet<NSNumber *> *registered;
        if(!registered) registered=[NSMutableSet set];
        if(![registered containsObject:@(count)]) {
            [AUAudioUnit registerSubclass:JarasExportUnit.class asComponentDescription:d name:@"CatLive Offline Export" version:1];
            [registered addObject:@(count)];
        }
    }
    return [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:d];
}
@end
