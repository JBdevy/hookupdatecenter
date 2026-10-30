#include "../DuplexInputBridge.h"
#include "../CallbackHubTests/AllocationAudit.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <thread>
using namespace catlive::native::audio;
using namespace catlive::native::audio::testing;
void require(bool value, const char* message) { if(!value){std::fprintf(stderr,"FAIL: %s\n",message);std::abort();} }
void signal(double inputRate, double outputRate, double ppm, double frequency=1000) {
    DuplexInputBridge bridge({2,512,512,128,128,inputRate,outputRate});
    std::array<float,512> left{},right{},outLeft{},outRight{};
    const float* input[]{left.data(),right.data()}; float* output[]{outLeft.data(),outRight.data()};
    const double actualRate=inputRate*(1.+ppm*1.e-6);
    std::uint64_t written=0, audible=0;
    double nextCapture=0, nextRender=.002, squared=0, phaseError=0;
    const double pi=3.14159265358979323846;
    while(nextRender<60) {
        if(nextCapture<=nextRender) {
            for(unsigned frame=0;frame<128;++frame){left[frame]=float(.5*std::sin(2*pi*frequency*(written+frame)/actualRate));right[frame]=-left[frame];}
            { AllocationAuditScope audit; require(bridge.push(input,128),"steady capture overrun"); }
            written+=128;nextCapture+=128./actualRate;
        } else {
            DuplexInputBridge::Result result;
            { AllocationAuditScope audit; result=bridge.pull(output,128); }
            require(!result.discontinuity,"steady capture underrun/discontinuity");
            if(nextRender>10)for(unsigned frame=0;frame<result.frames;++frame){squared+=double(outLeft[frame])*outLeft[frame];phaseError=std::max(phaseError,double(std::abs(outLeft[frame]+outRight[frame])));++audible;}
            nextRender+=128./outputRate;
        }
    }
    const double rms=std::sqrt(squared/audible);
    require(audible>100000,"no input reached render clock");
    require(phaseError<1.e-7,"stereo channels drifted independently");
    const bool aboveNyquist=frequency>outputRate*.5;
    require(aboveNyquist?rms<.002:std::abs(rms-std::sqrt(.125))<.004,"bandlimited resampling amplitude/alias rejection");
    require(bridge.statistics().overflows==0 && bridge.statistics().underruns==0,"stable clocks must not drop frames");
    std::printf("DUPLEX_SINC_RATE %.0f %.0f drift=%.0fppm rms=%.8f ratio=%.9f OK\n",inputRate,outputRate,ppm,rms,bridge.statistics().ratio);
}
void boundaries() {
    DuplexInputBridge bridge({2,128,128,128,128,48000,48000});
    std::array<float,128> inputLeft{},inputRight{},left{},right{};inputLeft.fill(.25f);inputRight.fill(-.75f);
    const float* input[]{inputLeft.data(),inputRight.data()};float* output[]{left.data(),right.data()};
    left.fill(99);auto empty=bridge.pull(output,128);require(empty.waiting && !empty.frames,"empty input primes silently");
    for(auto sample:left)require(sample==0,"stale output during priming");
    for(int i=0;i<3;++i)require(bridge.push(input,128),"prime push");
    auto full=bridge.pull(output,128);require(full.frames==128,"primed input");
    for(unsigned i=0;i<128;++i)require(std::abs(left[i]-.25f)<1.e-6 && std::abs(right[i]+.75f)<1.e-6,"DC/channel mapping");
    require(bridge.push(input,128,true),"discontinuous packet");
    require(bridge.pull(output,128).discontinuity,"gap must reach consumer");
    for(auto sample:left)require(sample==0,"gap must not replay old input");
    bool overflow=false;for(unsigned i=0;i<bridge.capacityFrames()/128+1;++i)if(!bridge.push(input,128))overflow=true;
    require(overflow && bridge.statistics().overflows>0,"bounded capture queue");
    require(bridge.pull(output,128).discontinuity,"overflow must reach consumer");
    bridge.reset();require(bridge.statistics().captured==0,"stopped reset clears history");
    for(int i=0;i<3;++i)require(bridge.push(nullptr,128),"null capture means silence");
    require(bridge.pull(output,128).frames==128,"null input still advances clock");
    for(auto sample:left)require(sample==0,"null input silence");
    require(!bridge.push(input,129),"oversized capture rejected before copying");
    require(bridge.pull(output,129).discontinuity,"oversized render rejected before writing");
    std::puts("DUPLEX_GAPS_OVERFLOW_NULL_INPUT_RESET_AND_BOUNDS_OK");
}
void concurrent() {
    DuplexInputBridge bridge({2,128,128,128,128,48000,48000});
    std::atomic<bool> finished{false};
    std::thread producer([&] {
        std::array<float,128> a{},b{};a.fill(.25f);b.fill(-.5f);const float* inputs[]{a.data(),b.data()};
        for(unsigned i=0;i<20000;++i){AllocationAuditScope audit;bridge.push(inputs,128,i%997==0);if(i%7==0)std::this_thread::yield();}
        finished.store(true,std::memory_order_release);
    });
    std::array<float,128>a{},b{};float* outputs[]{a.data(),b.data()};
    while(!finished.load(std::memory_order_acquire)) {
        DuplexInputBridge::Result result;
        {AllocationAuditScope audit;result=bridge.pull(outputs,128);}
        for(unsigned i=0;i<result.frames;++i)require(std::abs(a[i]-.25f)<1.e-6 && std::abs(b[i]+.5f)<1.e-6,"concurrent capture storage corruption");
    }
    producer.join();std::puts("DUPLEX_CONCURRENT_CAPTURE_RENDER_AND_DISCONTINUITY_OK");
}
int main(){
    boundaries();signal(48000,48000,0);signal(48000,48000,250);signal(48000,48000,-250);
    signal(44100,48000,120);signal(48000,44100,-120);signal(96000,48000,0,30000);concurrent();
    require(callbackAllocations.load()==0 && callbackDeallocations.load()==0,"callback heap allocation/deallocation");
    std::puts("DUPLEX_NO_CALLBACK_HEAP_OK");
}
