// The test runner extracts the unchanged common ring/State code from the bridge
// and includes the actual iPad worker, so this exercises the shipped model path.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreML/CoreML.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <cassert>
#include <iostream>
#include <cstdlib>
#include "CatStemSpectrogram.hpp"
#include "CatStemCoreMLTestKernel.hpp"

thread_local bool forbidRenderAllocation = false;
void *operator new(std::size_t count) { assert(!forbidRenderAllocation); if (auto value=std::malloc(count)) return value; throw std::bad_alloc(); }
void operator delete(void *value) noexcept { std::free(value); }
void *operator new[](std::size_t count) { return ::operator new(count); }
void operator delete[](void *value) noexcept { std::free(value); }
using namespace CatStemRealtime;

struct Peer {
    std::shared_ptr<State> state=std::make_shared<State>();
    std::shared_ptr<Runtime> runtime;
    std::thread worker;
    uint64_t clock=0;
    Peer(unsigned rate, NSURL *model) {
        state->prepare(rate); state->admitted.store(true); state->offline.store(true);
        runtime=std::make_shared<Runtime>(state);
        worker=std::thread([runtime=runtime,model] { runtime->run(model); });
    }
    ~Peer() { stop(); }
    void stop() {
        runtime->cancelled.store(true); state->admitted.store(false);
        if (worker.joinable()) worker.join();
        assert(runtime->finished.load());
    }
    static float signal(unsigned frame, unsigned rate, unsigned channel) {
        const double time=double(frame)/rate;
        return float(.14*std::sin(2*M_PI*(channel ? 331 : 173)*time)+.08*std::sin(2*M_PI*2347*time));
    }
    std::array<std::vector<float>,2> render(unsigned frames, bool silent=false, bool validateUnity=false) {
        std::array<std::vector<float>,2> result{std::vector<float>(frames),std::vector<float>(frames)};
        std::array<float,512> l{},r{},ol{},orr{};
        for (unsigned offset=0;offset<frames;offset+=512) {
            const unsigned count=std::min(512u,frames-offset);
            for(unsigned f=0;f<count;f++) {
                l[f]=silent ? 0 : signal(offset+f,state->rate.load(),0);
                r[f]=silent ? 0 : signal(offset+f,state->rate.load(),1);
            }
            AudioTimeStamp stamp{}; stamp.mFlags=kAudioTimeStampSampleTimeValid; stamp.mSampleTime=double(clock);
            forbidRenderAllocation=true;
            state->process(l.data(),r.data(),ol.data(),orr.data(),count,&stamp);
            forbidRenderAllocation=false;
            clock+=count;
            if(state->fault.load()!=none) { std::cerr<<"FAULT "<<state->fault.load()<<" "<<runtime->message<<"\n"; std::abort(); }
            std::copy_n(ol.data(),count,result[0].data()+offset);
            std::copy_n(orr.data(),count,result[1].data()+offset);
        }
        if(validateUnity) {
            const unsigned delay=state->latencyFrames.load();
            for(unsigned ch=0;ch<2;ch++) for(unsigned f=0;f<frames;f++)
                assert(result[ch][f] == (f<delay ? 0 : signal(f-delay,state->rate.load(),ch)));
        }
        return result;
    }
};

int main(int argc,const char *argv[]) { @autoreleasepool {
    assert(argc==2); NSURL *model=[NSURL fileURLWithPath:@(argv[1])];
    for(unsigned rate : {44100u,48000u}) {
        Peer peer(rate,model);
        const auto delay=peer.state->latencyFrames.load();
        peer.render(delay+rate,false,true);
        peer.state->requestedEpoch.fetch_add(1);
        const auto silence=peer.render(delay+rate,true);
        for(const auto &channel:silence) for(float value:channel) assert(value==0);
        peer.state->requestedEpoch.fetch_add(1); peer.state->soloMask.store(1);
        const auto isolated=peer.render(delay+rate);
        double energy=0,error=0;
        for(unsigned f=delay+rate/4;f<isolated[0].size();f++) {
            const float value=isolated[0][f]; assert(std::isfinite(value));
            energy+=value*value;
            const float delta=value-Peer::signal(f-delay,rate,0); error+=delta*delta;
        }
        assert(energy>1e-8); assert(error>1e-5);
        peer.state->muteMask.store(31);
        const auto muted=peer.render(rate);
        for(unsigned f=rate/2;f<rate;f++) assert(std::abs(muted[0][f])<1e-6 && std::abs(muted[1][f])<1e-6);
        peer.state->enabled.store(false);
        peer.render(rate); // allow the bypass ramp and prior dry history to finish
        const auto bypass=peer.render(rate);
        for(unsigned f=delay;f<rate;f++)
            assert(std::abs(bypass[0][f]-Peer::signal(f-delay,rate,0))<1e-6);
        peer.stop(); assert(!peer.state->warmReady.load());
        std::cout<<"CATSTEM_COREML_"<<rate<<"_UNITY_LATENCY_SOLO_MUTE_BYPASS_RESET_STOP_OK\n";
    }
    std::cout<<"CATSTEM_COREML_WORKER_OK\n";
}}
