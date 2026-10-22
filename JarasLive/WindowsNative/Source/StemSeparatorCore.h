#pragma once
// Port of the current Mac JarasStemSeparator bridge. CST1, resampling, fixed
// latency, residual Other reconstruction and three-ms smoothing are identical.
// Only render-facing bounded rings and numeric DSP live here; no pipe/model I/O.
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdint>
#include <thread>
#include <vector>
#if defined(_M_X64) || defined(__SSE2__)
#include <emmintrin.h>
#endif
namespace catlive::native::stem::detail {
// Match the Mac worker's hop and one-second HTDemucs6 context exactly.
// Windows buffers 1.5 seconds for GPU scheduling jitter and host render bursts.
// Keep this advertised delay fixed so track compensation remains stable.
constexpr unsigned modelRate=44100,hop=8192,rightContext=3072,modelDelay=66150,maxBlock=8192;
constexpr unsigned channels=2,stems=5,ringSlots=16,outputRingSlots=64;
static_assert(outputRingSlots*maxBlock > (modelDelay*192000ull+modelRate-1)/modelRate+2*maxBlock);
static_assert(std::atomic<uint64_t>::is_always_lock_free && std::atomic<float>::is_always_lock_free);
enum Fault:int {none=0,inputOverrun=1,outputUnderrun=2,protocolFailure=3,backendFailure=4,offlineTimeout=5};
enum Type:uint16_t {ready=1,audio=2,output=3,flush=4,flushed=5,error=6,close=7,closed=8};
#pragma pack(push,1)
struct Header {
    char magic[4]={'C','S','T','1'};
    uint16_t version=1,type=0;
    uint64_t stream=1,generation=0,sequence=0;
    int64_t firstFrame=0;
    uint32_t sampleRate=modelRate,frames=0;
    uint16_t channels=2,stems=0;
    uint32_t payloadBytes=0,flags=0,reserved=0;
};
#pragma pack(pop)
static_assert(sizeof(Header)==64);
template<unsigned channelCount> struct Packet {
    uint64_t generation=0;
    int64_t firstFrame=0;
    uint32_t frames=0,rate=0;
    std::array<float,maxBlock*channelCount> samples{};
};
// Each cursor has exactly one writer. Epoch changes discard packets, never reset
// the opposite thread's cursor or mutate a published slot.
template<class T,unsigned capacity=ringSlots> struct Ring {
    std::array<T,capacity> slots;
    alignas(64) std::atomic<uint64_t> read{0};
    alignas(64) std::atomic<uint64_t> write{0};
    T *producerSlot(){const auto w=write.load(std::memory_order_relaxed);return w-read.load(std::memory_order_acquire)<capacity?&slots[w%capacity]:nullptr;}
    void publish(){write.fetch_add(1,std::memory_order_release);}
    T *consumerSlot(){const auto r=read.load(std::memory_order_relaxed);return r<write.load(std::memory_order_acquire)?&slots[r%capacity]:nullptr;}
    void consume(){read.fetch_add(1,std::memory_order_release);}
};

// Streaming, zero-phase 64-tap low-pass interpolation. The 32 input frames of
// lookahead are paid from the declared fixed delay. Runs on worker I/O threads.
class Resampler {
    static constexpr unsigned taps=64,phases=1024,history=128;
    unsigned channelCount,inputRate,outputRate;
    uint64_t inputCount=0,outputCount=0;
    std::vector<float> samples,coefficients;
    std::array<float,10> frame{};
    void interpolate(int64_t center,const float *weights){
        // Keep each channel's 64 additions in their original order. Fixed
        // channel widths let the compiler retain accumulators in registers;
        // SIMD is across channels, never across taps or through an FMA.
        if(channelCount==2){
            float left=0.f,right=0.f;
            for(unsigned tap=0;tap<taps;tap++){
                const int64_t index=center-31+tap;if(index<0)continue;
                const float *row=samples.data()+(uint64_t(index)%history)*2;
                left+=row[0]*weights[tap];right+=row[1]*weights[tap];
            }
            frame[0]=left;frame[1]=right;return;
        }
#if defined(_M_X64) || defined(__SSE2__)
        if(channelCount==10){
            __m128 first=_mm_setzero_ps(),second=_mm_setzero_ps();
            float ninth=0.f,tenth=0.f;
            for(unsigned tap=0;tap<taps;tap++){
                const int64_t index=center-31+tap;if(index<0)continue;
                const float *row=samples.data()+(uint64_t(index)%history)*10;
                const __m128 weight=_mm_set1_ps(weights[tap]);
                first=_mm_add_ps(first,_mm_mul_ps(_mm_loadu_ps(row),weight));
                second=_mm_add_ps(second,_mm_mul_ps(_mm_loadu_ps(row+4),weight));
                ninth+=row[8]*weights[tap];tenth+=row[9]*weights[tap];
            }
            _mm_storeu_ps(frame.data(),first);_mm_storeu_ps(frame.data()+4,second);
            frame[8]=ninth;frame[9]=tenth;return;
        }
#endif
        std::fill_n(frame.data(),channelCount,0.f);
        for(unsigned tap=0;tap<taps;tap++){
            const int64_t index=center-31+tap;if(index<0)continue;
            const float weight=weights[tap];
            for(unsigned ch=0;ch<channelCount;ch++)frame[ch]+=samples[(uint64_t(index)%history)*channelCount+ch]*weight;
        }
    }
public:
    Resampler(unsigned count,unsigned inRate,unsigned outRate):channelCount(count),inputRate(inRate),outputRate(outRate),samples(history*count,0),coefficients(phases*taps){
        const double cutoff=std::min(1.0,double(outRate)/inRate)*0.94;
        for(unsigned phase=0;phase<phases;phase++){
            double sum=0;
            for(unsigned tap=0;tap<taps;tap++){
                const double x=double(int(tap)-31)-double(phase)/phases;
                const double sinc=std::abs(x)<1e-12?cutoff:std::sin(3.14159265358979323846*cutoff*x)/(3.14159265358979323846*x);
                const double window=0.42-0.5*std::cos(2*3.14159265358979323846*tap/(taps-1))+0.08*std::cos(4*3.14159265358979323846*tap/(taps-1));
                coefficients[phase*taps+tap]=float(sinc*window);sum+=sinc*window;
            }
            for(unsigned tap=0;tap<taps;tap++)coefficients[phase*taps+tap]/=float(sum);
        }
    }
    template<class Emit> bool feed(const float *source,unsigned count,Emit emit){
        for(unsigned n=0;n<count;n++){
            if(inputRate==outputRate){if(!emit(source+n*channelCount,int64_t(outputCount++)))return false;inputCount++;continue;}
            std::copy_n(source+n*channelCount,channelCount,samples.data()+(inputCount%history)*channelCount);inputCount++;
            for(;;){
                const long double position=static_cast<long double>(outputCount)*inputRate/outputRate;
                const int64_t center=int64_t(std::floor(position));
                if(center+32>=int64_t(inputCount))break;
                const unsigned phase=std::min(phases-1,unsigned((position-center)*phases));
                interpolate(center,coefficients.data()+phase*taps);
                if(!emit(frame.data(),int64_t(outputCount++)))return false;
            }
        }
        return true;
    }
};

struct State {
    Ring<Packet<2>> input;
    // Hold the 1.5-second preroll even at the maximum 192 kHz host rate.
    Ring<Packet<10>,outputRingSlots> output;
    std::atomic<bool> admitted{false},warmReady{false},enabled{true},offline{false};
    std::atomic<unsigned> rate{48000},latencyFrames{72000},muteMask{0},soloMask{0};
    std::array<std::atomic<float>,5> gains{{1,1,1,1,1}};
    std::atomic<uint64_t> requestedEpoch{1},renderedFrames{0},underruns{0},overruns{0};
    std::atomic<int> fault{none};
    uint64_t epoch=0,position=0,dryPosition=0,dryEpochStart=0;
    int64_t expectedSample=0;bool hadSample=false;
    unsigned outputOffset=0;
    std::array<float,maxBlock*2> scratch{};
    // Maximum supported rate is 192 kHz; allocate once, before any callback.
    std::array<float,((modelDelay*192000ull+modelRate-1)/modelRate+maxBlock)*2> dry{};
    std::array<float,5> smoothed{{1,1,1,1,1}};
    float wet=1,ramp=0.01;
    void prepare(unsigned sampleRate){rate.store(sampleRate);latencyFrames.store(unsigned(std::ceil(double(modelDelay)*sampleRate/modelRate)));ramp=float(1-std::exp(-1.0/(0.003*sampleRate)));requestedEpoch.fetch_add(1);hadSample=false;}
    void setFault(Fault value){int expected=none;fault.compare_exchange_strong(expected,value);}
    bool waitAllowed(const std::chrono::steady_clock::time_point &deadline){
        if(!offline.load(std::memory_order_relaxed)||!admitted.load()||fault.load()!=none)return false;
        if(std::chrono::steady_clock::now()>=deadline){setFault(offlineTimeout);return false;}
        std::this_thread::sleep_for(std::chrono::milliseconds(1));return true;
    }
    void process(const float *left,const float *right,float *outLeft,float *outRight,unsigned count,int64_t sampleTime, bool advancing){
        const bool accepted=admitted.load(std::memory_order_acquire);
        if(!accepted){std::copy_n(left,count,outLeft);std::copy_n(right,count,outRight);return;}
        const bool renderOffline=offline.load(std::memory_order_relaxed);
        const auto deadline=renderOffline?std::chrono::steady_clock::now()+std::chrono::seconds(30):std::chrono::steady_clock::time_point{};
        auto nextEpoch=requestedEpoch.load(std::memory_order_acquire);
        if(advancing){
            const auto sample=sampleTime;
            if(hadSample&&sample!=expectedSample&&nextEpoch==epoch)nextEpoch=requestedEpoch.fetch_add(1)+1;
            expectedSample=sample+count;hadSample=true;
        } else if(hadSample) { nextEpoch=requestedEpoch.fetch_add(1)+1;hadSample=false; }
        if(nextEpoch!=epoch){epoch=nextEpoch;position=0;dryEpochStart=dryPosition;outputOffset=0;renderedFrames.store(0);}
        if(!warmReady.load(std::memory_order_acquire)){
            // A model can take seconds to load. Do not overflow the audio queue
            // with a transport that has not yet been admitted to inference.
            while(renderOffline&&!warmReady.load()&&waitAllowed(deadline)){}
            if(!warmReady.load()){
                const auto delay=latencyFrames.load();
                for(unsigned f=0;f<count;f++){
                    const auto frame=dryPosition+f;
                    const float dl=frame-dryEpochStart>=delay?dry[((frame-delay)%(dry.size()/2))*2]:0;
                    const float dr=frame-dryEpochStart>=delay?dry[((frame-delay)%(dry.size()/2))*2+1]:0;
                    dry[(frame%(dry.size()/2))*2]=left[f];dry[(frame%(dry.size()/2))*2+1]=right[f];
                    outLeft[f]=dl;outRight[f]=dr;
                }
                dryPosition+=count;wet=0.f;return;
            }
        }
        const unsigned delay=latencyFrames.load(std::memory_order_relaxed),sampleRate=rate.load(std::memory_order_relaxed);
        auto packet=input.producerSlot();
        while(!packet&&waitAllowed(deadline))packet=input.producerSlot();
        if(!packet){overruns.fetch_add(1,std::memory_order_relaxed);setFault(inputOverrun);}
        else if(fault.load()==none){
            packet->generation=epoch;packet->firstFrame=int64_t(position);packet->frames=count;packet->rate=sampleRate;
            for(unsigned f=0;f<count;f++){packet->samples[f*2]=left[f];packet->samples[f*2+1]=right[f];}
            input.publish();
        }
        const bool active=enabled.load(std::memory_order_relaxed);
        const unsigned muted=muteMask.load(std::memory_order_relaxed),solo=soloMask.load(std::memory_order_relaxed);
        std::array<float,5> target{};
        for(unsigned s=0;s<stems;s++)target[s]=((muted&(1u<<s))||(solo&&!(solo&(1u<<s))))?0:gains[s].load(std::memory_order_relaxed);
        for(unsigned f=0;f<count;f++){
            if(requestedEpoch.load(std::memory_order_acquire)!=epoch){outLeft[f]=0;outRight[f]=0;continue;}
            const uint64_t frame=position+f;
            const uint64_t dryFrame=dryPosition+f;
            const float dl=dryFrame-dryEpochStart>=delay?dry[((dryFrame-delay)%(dry.size()/2))*2]:0;
            const float dr=dryFrame-dryEpochStart>=delay?dry[((dryFrame-delay)%(dry.size()/2))*2+1]:0;
            dry[(dryFrame%(dry.size()/2))*2]=left[f];dry[(dryFrame%(dry.size()/2))*2+1]=right[f];
            float l=0,r=0;bool available=false;
            if(frame>=delay){
                const auto wanted=int64_t(frame-delay);
                for(unsigned attempts=0;attempts<=outputRingSlots;attempts++){
                    auto readyPacket=output.consumerSlot();
                    if(!readyPacket){if(active&&waitAllowed(deadline)){attempts--;continue;}break;}
                    if(readyPacket->generation<epoch||(readyPacket->generation==epoch&&readyPacket->firstFrame+readyPacket->frames<=wanted)){output.consume();outputOffset=0;continue;}
                    if(readyPacket->generation!=epoch||readyPacket->firstFrame>wanted)break;
                    outputOffset=unsigned(wanted-readyPacket->firstFrame);
                    for(unsigned s=0;s<stems;s++)smoothed[s]+=(target[s]-smoothed[s])*ramp;
                    // Define Other from the aligned original host PCM minus the
                    // first four separated sources. Unity is bit-exact delayed
                    // dry even after sample-rate conversion; mute/solo still
                    // controls that residual solely through the Other fader.
                    l=dl*smoothed[4];r=dr*smoothed[4];
                    for(unsigned s=0;s<4;s++){
                        const float gain=smoothed[s]-smoothed[4];
                        l+=readyPacket->samples[outputOffset*10+s*2]*gain;r+=readyPacket->samples[outputOffset*10+s*2+1]*gain;
                    }
                    if(++outputOffset==readyPacket->frames){output.consume();outputOffset=0;}
                    available=true;break;
                }
                if(!available&&active&&fault.load()==none){underruns.fetch_add(1,std::memory_order_relaxed);setFault(outputUnderrun);}
            }
            if(fault.load(std::memory_order_relaxed)!=none){outLeft[f]=dl;outRight[f]=dr;continue;}
            wet+=((active?1.f:0.f)-wet)*ramp;
            outLeft[f]=l*wet+dl*(1-wet);outRight[f]=r*wet+dr*(1-wet);
        }
        position+=count;dryPosition+=count;renderedFrames.store(position,std::memory_order_release);
    }
};


}
