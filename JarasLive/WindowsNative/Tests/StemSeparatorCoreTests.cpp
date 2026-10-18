#include "../Source/StemSeparatorCore.h"
#include "../Source/AudioLatency.h"
#include <iostream>
#include <stdexcept>
#include <memory>
using namespace catlive::native;
using namespace catlive::native::stem::detail;
void require(bool ok,const char *message){if(!ok)throw std::runtime_error(message);}
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
                for(unsigned i=0;i<256;i++)require(std::abs(left[i]-(at+i>=latency?.3f:0.f))<1e-7f&&std::abs(right[i]-(at+i>=latency?.15f:0.f))<1e-7f,"Five-stem unity / fixed delay differs from Mac");
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
        std::cout<<"CatStem core: fixed delay, unity residual, 4 rates, seek epochs, PDC and resampling passed\n";return 0;
    }catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 1;}
}
