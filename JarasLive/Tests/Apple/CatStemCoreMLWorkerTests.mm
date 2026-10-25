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
#include <functional>
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
    // Low-memory iPads use the CPU path. Exercise it explicitly even when
    // this regression runs on a Mac with enough RAM for GPU/ANE execution.
    { @autoreleasepool {
        MobileModel compact(model,MLComputeUnitsCPUOnly);
        std::vector<float> input(hop*2),output(hop*10);
        for(unsigned frame=0;frame<hop;frame++)for(unsigned channel=0;channel<2;channel++)
            input[frame*2+channel]=Peer::signal(frame,44100,channel);
        for(unsigned block=0;block<3;block++){ @autoreleasepool { compact.process(input.data(),output.data()); }
            double energy=0;
            for(unsigned frame=rightContext;frame<hop;frame++)for(unsigned channel=0;channel<2;channel++){
                float sum=0;for(unsigned stem=0;stem<5;stem++){
                    const float value=output[(stem*hop+frame)*2+channel];assert(std::isfinite(value));sum+=value;
                    if(stem<4)energy+=value*value;
                }
                assert(std::abs(sum-input[(frame-rightContext)*2+channel])<1e-6);
            }
            assert(energy>1e-8);
        }
        std::cout<<"CATSTEM_COREML_LOW_MEMORY_CPU_FIVE_SOURCES_UNITY_OK\n";
    } }
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
    std::thread offline([model] { @autoreleasepool {
        for(unsigned frames : {1u,67u,8193u,19473u,33075u,33076u,100001u}) {
            NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
            NSURL *directory=[NSURL fileURLWithPath:folder];NSURL *input=[directory URLByAppendingPathComponent:@"input.wav"];
            auto format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];NSError *error=nil;
            @autoreleasepool {
                auto writer=[[AVAudioFile alloc] initForWriting:input settings:format.settings error:&error];assert(writer);
                auto pcm=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];pcm.frameLength=frames;
                for(unsigned channel=0;channel<2;channel++)for(unsigned frame=0;frame<frames;frame++)pcm.floatChannelData[channel][frame]=Peer::signal(frame,44100,channel);
                assert([writer writeFromBuffer:pcm error:&error]);
            }
            double latest=0;unsigned updates=0;
            @autoreleasepool { separateCoreMLFile(input,directory,model,[]{return false;},[&](double fraction){assert(fraction>=latest);latest=fraction;updates++;}); }
            assert(latest==1&&updates==(frames+33074)/33075);
            std::vector<float> sums(frames*2,0);
            for(NSString *name in @[@"Vocal",@"Drum",@"Bass",@"Guitar",@"Other"]) {
                auto file=[[AVAudioFile alloc] initForReading:[directory URLByAppendingPathComponent:[name stringByAppendingString:@".wav"]] error:&error];
                assert(file&&file.length==frames&&file.processingFormat.sampleRate==44100&&file.processingFormat.channelCount==2);
                auto pcm=[[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:frames];assert([file readIntoBuffer:pcm error:&error]);assert(pcm.frameLength==frames);
                for(unsigned channel=0;channel<2;channel++)for(unsigned frame=0;frame<frames;frame++){float value=pcm.floatChannelData[channel][frame];assert(std::isfinite(value));sums[frame*2+channel]+=value;}
            }
            for(unsigned frame=0;frame<frames;frame++)for(unsigned channel=0;channel<2;channel++)assert(std::abs(sums[frame*2+channel]-Peer::signal(frame,44100,channel))<1e-6);
            // Independent full-timeline overlap/add reference checks each named
            // source and the seam (unity alone could hide a wrong residual).
            if(frames==33076) { @autoreleasepool {
                constexpr unsigned window=44100,stride=33075;
                MobileModel reference(model);
                std::vector<float> audio(window*2),prediction(window*8),expected(frames*8),weight(frames);
                for(unsigned offset=0;offset<frames;offset+=stride) {
                    std::fill(audio.begin(),audio.end(),0);
                    const unsigned count=std::min(window,frames-offset);
                    for(unsigned channel=0;channel<2;channel++)for(unsigned f=0;f<count;f++)audio[channel*window+f]=Peer::signal(offset+f,44100,channel);
                    @autoreleasepool { reference.predictWindow(audio.data(),prediction.data()); }
                    for(unsigned f=0;f<count;f++){
                        const float w=float(std::min(f+1,window-f))/(window/2);weight[offset+f]+=w;
                        for(unsigned plane=0;plane<8;plane++)expected[plane*frames+offset+f]+=w*prediction[plane*window+f];
                    }
                }
                NSArray<NSString *> *names=@[@"Vocal",@"Drum",@"Bass",@"Guitar"];
                for(unsigned stem=0;stem<4;stem++){
                    auto file=[[AVAudioFile alloc] initForReading:[directory URLByAppendingPathComponent:[names[stem] stringByAppendingString:@".wav"]] error:&error];
                    auto pcm=[[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:frames];assert([file readIntoBuffer:pcm error:&error]);
                    for(unsigned ch=0;ch<2;ch++)for(unsigned f=0;f<frames;f++)assert(std::abs(pcm.floatChannelData[ch][f]-expected[(stem*2+ch)*frames+f]/weight[f])<2e-5);
                }
                std::cout<<"CATSTEM_COREML_OFFLINE_NAMED_SOURCES_TRIANGULAR_SEAM_REFERENCE_OK\n";
            } }
            if(frames==100001){
                unsigned completed=0;bool stopped=false;
                try{separateCoreMLFile(input,directory,model,[&]{return completed>0;},[&](double){completed++;});}catch(const std::exception &){stopped=true;}
                assert(stopped&&completed==1);
            }
            bool cancelled=false;try { separateCoreMLFile(input,directory,model,[]{return true;},[](double){}); }catch(const std::exception &){cancelled=true;}assert(cancelled);
            [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
            std::cout<<"CATSTEM_COREML_OFFLINE_"<<frames<<"_FIVE_FILES_EXACT_DURATION_UNITY_CANCEL_OK\n";
        }
    } });offline.join();
    std::cout<<"CATSTEM_COREML_WORKER_OK\n";
}}
