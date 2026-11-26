#include "../Source/StemSeparatorCore.h"
#include "../Source/AudioLatency.h"
#include <iostream>
#include <stdexcept>
#include <memory>
using namespace catlive::native;
using namespace catlive::native::stem::detail;
void require(bool ok,const char *message){if(!ok)throw std::runtime_error(message);}

// Frozen scalar implementation from the original Mac/Windows bridge. Keep it
// independent of Resampler's specialized kernels so exact PCM, phase and frame
// accounting are checked when those kernels change.
class ScalarResamplerReference {
    static constexpr unsigned taps=64,phases=1024,history=128;
    unsigned channelCount,inputRate,outputRate;
    uint64_t inputCount=0,outputCount=0;
    std::vector<float> samples,coefficients;
    std::array<float,10> frame{};
public:
    ScalarResamplerReference(unsigned count,unsigned inRate,unsigned outRate):channelCount(count),inputRate(inRate),outputRate(outRate),samples(history*count,0),coefficients(phases*taps){
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
                std::fill_n(frame.data(),channelCount,0.f);
                for(unsigned tap=0;tap<taps;tap++){
                    const int64_t index=center-31+tap;if(index<0)continue;
                    const float weight=coefficients[phase*taps+tap];
                    for(unsigned ch=0;ch<channelCount;ch++)frame[ch]+=samples[(uint64_t(index)%history)*channelCount+ch]*weight;
                }
                if(!emit(frame.data(),int64_t(outputCount++)))return false;
            }
        }
        return true;
    }
};

template<class Converter>
std::vector<float> resampleFixture(const std::vector<float>& input,unsigned channelCount,unsigned inRate,unsigned outRate,unsigned block){
    Converter converter(channelCount,inRate,outRate);
    std::vector<float> output;
    const size_t count=input.size()/channelCount;
    output.reserve(size_t(std::ceil(double(count)*outRate/inRate))*channelCount);
    uint64_t nextFrame=0;
    for(size_t at=0;at<count;at+=block){
        const auto size=unsigned(std::min<size_t>(block,count-at));
        require(converter.feed(input.data()+at*channelCount,size,[&](const float *frame,int64_t index){
            require(index==int64_t(nextFrame++),"Resampler output frame sequence changed");
            output.insert(output.end(),frame,frame+channelCount);return true;
        }),"Resampler unexpectedly stopped");
    }
    return output;
}

void verifyResamplerKernels(){
    unsigned configurations=0;
    for(unsigned channelCount:{2,10}){
        constexpr unsigned inputFrames=8192*2+137;
        std::vector<float> input(size_t(inputFrames)*channelCount);
        uint32_t random=108;
        for(auto &value:input){random=random*1664525u+1013904223u;value=(float(random>>8)/8388608.f-1.f)*.3f;}
        // Independent impulses straddle the 128-frame history and feed bounds.
        for(unsigned at:{0u,31u,32u,127u,128u,8191u,8192u,16383u})
            for(unsigned channel=0;channel<channelCount;channel++)input[size_t(at)*channelCount+channel]=(channel%2?-.7f:.7f);
        for(unsigned hostRate:{32000,44100,48000,96000,192000})for(bool toModel:{false,true}){
            const unsigned inRate=toModel?hostRate:modelRate,outRate=toModel?modelRate:hostRate;
            const auto expected=resampleFixture<ScalarResamplerReference>(input,channelCount,inRate,outRate,8192);
            for(unsigned block:{1,8192}){
                const auto actual=resampleFixture<Resampler>(input,channelCount,inRate,outRate,block);
                if(actual.size()!=expected.size()||std::memcmp(actual.data(),expected.data(),expected.size()*sizeof(float))){
                    std::cerr<<"Resampler mismatch: channels="<<channelCount<<" inputRate="<<inRate<<" outputRate="<<outRate<<" block="<<block<<'\n';
                    throw std::runtime_error("Specialized resampling differs from original scalar PCM");
                }
                configurations++;
            }
        }
    }
    std::cout<<"CatStem resampler: "<<configurations<<" scalar-reference comparisons passed bit-exactly\n";
}
int main(){
    try {
        StereoDelay delay(123);std::array<float,512> left{},right{};left[0]=1;right[0]=.25f;
        delay.process(left.data(),right.data(),512,0,true);
        require(left[123]==1&&right[123]==.25f&&left[0]==0,"Stereo PDC impulse misaligned");
        left.fill(0);right.fill(0);delay.process(left.data(),right.data(),512,10000,true);
        require(*std::max_element(left.begin(),left.end())==0,"Seek leaked stale delayed audio");
        TimelineDelay timeline(123);timeline.reset(2.);
        for(int n=0;n<512;n++) {
            const double at=2.+double(n%80)/44100;
            const auto shown=timeline.process({at,n<180});
            if(n<123)require(shown.position==2.&&!shown.moving,"Presentation preroll must hold seek position");
            else require(std::abs(shown.position-(2.+double((n-123)%80)/44100))<1e-12&&shown.moving==((n-123)<180),"Presentation must preserve loop wraps and natural tail");
        }
        timeline.reset(20.);require(timeline.process({20.,false}).position==20.,"Stopped seek must clear presentation history");
        for(unsigned rate:{44100,48000,96000,192000}) {
            auto state=std::make_unique<State>();state->prepare(rate);state->admitted=true;state->warmReady=true;
            const auto epoch=state->requestedEpoch.load();const unsigned latency=state->latencyFrames.load();
            // Known five-channel estimate. Unity reconstruction must be exact
            // delayed original, independent of the model's residual error.
            for(unsigned chunk=0;chunk<8;chunk++) {
                auto *p=state->output.producerSlot();require(p,"Output capacity");p->generation=epoch;p->firstFrame=chunk*8192;p->frames=8192;p->rate=rate;
                for(unsigned f=0;f<8192;f++)for(unsigned stem=0;stem<5;stem++){p->samples[f*10+stem*2]=.02f*(stem+1);p->samples[f*10+stem*2+1]=.01f*(stem+1);}state->output.publish();
            }
            unsigned at=0;
            for(;at<latency+8192;at+=256){
                left.fill(.3f);right.fill(.15f);state->process(left.data(),right.data(),left.data(),right.data(),256,at,true);
                while(state->input.consumerSlot())state->input.consume();
                for(unsigned i=0;i<256;i++)require(std::abs(left[i]-(at+i>=latency?.3f:0.f))<1e-7f&&std::abs(right[i]-(at+i>=latency?.15f:0.f))<1e-7f,"Five-stem unity / fixed Windows delay is incorrect");
            }
            require(state->fault==none,"Unexpected stream fault");
            state->soloMask=1; // Vocal converges to its own estimate, not dry.
            for(unsigned n=0;n<8192;n+=256){left.fill(.3f);right.fill(.15f);state->process(left.data(),right.data(),left.data(),right.data(),256,at+n,true);while(state->input.consumerSlot())state->input.consume();}
            require(std::abs(left[255]-.02f)<.0002f&&std::abs(right[255]-.01f)<.0002f,"Solo must isolate Vocal with three-ms smoothing");
            // Use a deliberate seek rather than accidentally testing discontinuity
            // in a partially consumed block: old-generation output must be rejected.
            left.fill(0);right.fill(0);state->process(left.data(),right.data(),left.data(),right.data(),256,10000000,true);
            require(state->requestedEpoch.load()>epoch,"Seek must advance the model epoch");
        }
        Resampler resampler(2,48000,44100);std::vector<float> input(48000*2,.25f);size_t frames=0;double maxError=0;
        require(resampler.feed(input.data(),48000,[&](const float *sample,int64_t index){if(index>100)maxError=std::max(maxError,std::abs(double(sample[0])-.25));frames++;return true;}),"Resampler failed");
        require(frames>44000&&frames<44101&&maxError<1e-6,"Mac resampling DC gain/timing changed");
        verifyResamplerKernels();
        std::cout<<"CatStem core: fixed delay, unity residual, 4 rates, seek epochs, PDC and resampling passed\n";return 0;
    }catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 1;}
}
