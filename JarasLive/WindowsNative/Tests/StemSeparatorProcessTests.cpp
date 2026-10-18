#include "../Source/StemSeparator.h"
#include <array>
#include <chrono>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <windows.h>
using namespace catlive::native::stem;
void require(bool ok,const char *message){if(!ok)throw std::runtime_error(message);}
int realtime(const Paths &paths) {
    constexpr unsigned rate=48000,block=256,frames=rate*8;
    Processor processor(paths,rate,false);Mix mix;mix.enabled=true;mix.gains.fill(.5f);processor.configure(mix);
    const auto startup=std::chrono::steady_clock::now();
    while(!processor.status().ready) {
        const auto status=processor.status();if(status.state=="fault")throw std::runtime_error(status.error);
        require(std::chrono::steady_clock::now()-startup<std::chrono::seconds(180),"Realtime model warmup timed out");
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    processor.activate();require(processor.availableLatency()==72000,"Production latency contract differs");
    HANDLE timer=CreateWaitableTimerExW(nullptr,nullptr,0x2,TIMER_ALL_ACCESS);
    if(!timer)timer=CreateWaitableTimerW(nullptr,FALSE,nullptr);
    require(timer!=nullptr,"Cannot create realtime cadence timer");
    struct CloseTimer{HANDLE value;~CloseTimer(){CloseHandle(value);}} close{timer};
    const auto signal=[rate](int64_t frame,int channel){return frame<0?0.f:float(.09*std::sin(double(frame)*(channel?347:211)*6.283185307179586/rate)+.03*std::sin(double(frame)*719*6.283185307179586/rate));};
    const auto began=std::chrono::steady_clock::now();double maxError=0,maxLate=0;
    std::array<float,block> left{},right{};
    for(unsigned clock=0;clock<frames;clock+=block) {
        const auto deadline=began+std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(double(clock)/rate));
        const auto remaining=deadline-std::chrono::steady_clock::now();
        if(remaining>std::chrono::microseconds(0)) {
            LARGE_INTEGER due;due.QuadPart=-std::max<int64_t>(1,std::chrono::duration_cast<std::chrono::nanoseconds>(remaining).count()/100);
            require(SetWaitableTimer(timer,&due,0,nullptr,nullptr,FALSE)!=0,"Cadence timer could not be armed");WaitForSingleObject(timer,INFINITE);
        }
        maxLate=std::max(maxLate,std::chrono::duration<double>(std::chrono::steady_clock::now()-deadline).count());
        for(unsigned n=0;n<block;n++){left[n]=signal(clock+n,0);right[n]=signal(clock+n,1);}
        processor.process(left.data(),right.data(),block,double(clock)/rate,true);
        for(unsigned n=0;n<block;n++) {
            require(std::isfinite(left[n])&&std::isfinite(right[n]),"Production output became nonfinite");
            if(clock+n>processor.latency()+8192)for(unsigned ch=0;ch<2;ch++)maxError=std::max(maxError,std::abs(double(ch?right[n]:left[n])-.5*signal(int64_t(clock+n)-processor.latency(),ch)));
        }
        const auto status=processor.status();if(status.state=="fault")throw std::runtime_error(status.error);
    }
    const auto status=processor.status();
    require(maxError<.00002&&status.underruns==0&&status.overruns==0,"Realtime production PCM/queue validation failed");
    std::cout<<"Production C++/CST1 FP32: rate="<<rate<<" frames="<<frames<<" latency="<<processor.latency()<<" maxError="<<maxError<<" underruns="<<status.underruns<<" overruns="<<status.overruns<<" maxCallbackLatenessSeconds="<<maxLate<<"\n";
    return 0;
}
int main(int argc,char **argv) {
    if(argc!=4&&argc!=5){std::cerr<<"usage: CatStemProcessTests python.exe StemIdentityWorker.py model.th [--realtime]\n";return 2;}
    try {
        const Paths fixture{std::filesystem::u8path(argv[1]),std::filesystem::u8path(argv[2]),std::filesystem::u8path(argv[3])};
        if(argc==5){require(std::string(argv[4])=="--realtime","Unknown mode");return realtime(fixture);}
        for(unsigned rate:{44100,48000,96000}) {
            Processor p(fixture,rate,true);Mix mix;mix.enabled=true;p.configure(mix);p.waitReady();
            std::array<float,256> left{},right{};const auto delay=p.latency();unsigned clock=0;
            for(;clock<delay+8192;clock+=256) {
                for(unsigned n=0;n<256;n++){left[n]=(clock+n)==0?.75f:0;right[n]=left[n]*.5f;}
                p.process(left.data(),right.data(),256,double(clock)/rate,true);
                for(unsigned n=0;n<256;n++)require(std::abs(left[n]-((clock+n)==delay?.75f:0))<1e-7f,"Persistent worker unity must equal exact delayed input");
            }
            require(p.status().ready,"Worker unexpectedly failed");
            mix.muteMask=1;p.configure(mix);
            for(unsigned n=0;n<delay+8192;n+=256,clock+=256){left.fill(.2f);right.fill(.1f);p.process(left.data(),right.data(),256,double(clock)/rate,true);}
            require(std::abs(left[255]-.1f)<.0002f&&std::abs(right[255]-.05f)<.0002f,"Vocal mute must leave only Other, with host-rate reconstruction");
            mix.soloMask=1;mix.muteMask=0;p.configure(mix);
            for(unsigned n=0;n<8192;n+=256,clock+=256){left.fill(.2f);right.fill(.1f);p.process(left.data(),right.data(),256,double(clock)/rate,true);}
            require(std::abs(left[255]-.1f)<.0002f,"Vocal solo must isolate its source");
            mix.enabled=false;p.configure(mix);
            for(unsigned n=0;n<8192;n+=256,clock+=256){left.fill(.2f);right.fill(.1f);p.process(left.data(),right.data(),256,double(clock)/rate,true);}
            require(std::abs(left[255]-.2f)<.0002f,"Bypass must retain aligned original input");
            left.fill(0);right.fill(0);p.process(left.data(),right.data(),256,100,true);
            require(std::abs(left[255])<1e-7f,"Seek must discard previous-generation samples");
            std::cout<<"CST1 process, gain, mute, solo, bypass, seek passed at "<<rate<<" Hz\n";
        }
        auto ready=[](Processor &processor){
            const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
            while(!processor.status().ready) {
                const auto status=processor.status();if(status.state=="fault")throw std::runtime_error(status.error);
                require(std::chrono::steady_clock::now()<deadline,"Replacement worker failed to acquire the retiring slot");
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
        };
        auto previous=std::make_unique<Processor>(fixture,44100,false);ready(*previous);
        auto replacement=std::make_unique<Processor>(fixture,48000,false);
        std::this_thread::sleep_for(std::chrono::milliseconds(40)); // old device still owns its slot
        previous.reset();ready(*replacement);
        std::cout<<"Realtime device/rate replacement waits for the retiring worker lease\n";
        return 0;
    }catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 1;}
}
