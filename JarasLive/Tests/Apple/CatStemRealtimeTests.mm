#import "../../Apple/Bridge/JarasStemSeparator.mm"
#include <cassert>
#include <iostream>
#include <cstdlib>

thread_local bool forbidRenderAllocation=false;
void *operator new(std::size_t count){assert(!forbidRenderAllocation);if(auto value=std::malloc(count))return value;throw std::bad_alloc();}
void operator delete(void *value) noexcept{std::free(value);}
void *operator new[](std::size_t count){return ::operator new(count);}
void operator delete[](void *value) noexcept{std::free(value);}

using namespace CatStemRealtime;
struct Peer {
    std::shared_ptr<State> state=std::make_shared<State>();
    std::shared_ptr<Runtime> runtime;
    std::thread process;
    NSString *folder;uint64_t sampleClock=0;
    Peer(unsigned rate,NSString *python,NSString *worker,NSString *mode=@"identity"){
        folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        [mode writeToFile:[folder stringByAppendingPathComponent:@"mode"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        state->prepare(rate);state->admitted.store(true);state->offline.store(true);
        runtime=std::make_shared<Runtime>(state);
        NSURL *executable=[NSURL fileURLWithPath:python],*script=[NSURL fileURLWithPath:worker],*model=[NSURL fileURLWithPath:folder];
        process=std::thread([run=runtime,executable,script,model]{run->run(executable,script,model);});
    }
    ~Peer(){runtime->cancelled.store(true);state->admitted.store(false);if(process.joinable())process.join();[NSFileManager.defaultManager removeItemAtPath:folder error:nil];}
    std::vector<float> render(unsigned frames,int impulse=-1,float constant=0){
        std::vector<float> result(frames);std::array<float,512> l{},r{},ol{},orr{};
        for(unsigned start=0;start<frames;start+=512){
            const unsigned count=std::min(512u,frames-start);
            for(unsigned f=0;f<count;f++){l[f]=int(start+f)==impulse?1:constant;r[f]=l[f]*-.5f;}
            AudioTimeStamp stamp{};stamp.mFlags=kAudioTimeStampSampleTimeValid;stamp.mSampleTime=double(sampleClock);
            state->process(l.data(),r.data(),ol.data(),orr.data(),count,&stamp);sampleClock+=count;
            std::copy_n(ol.data(),count,result.data()+start);
            for(unsigned f=0;f<count;f++)assert(std::abs(orr[f]+ol[f]*.5f)<1e-5f);
            if(state->fault.load()!=none)break;
        }
        return result;
    }
};
void assertHealthy(const Peer &peer){if(peer.state->fault.load()){std::cerr<<"FAULT "<<peer.state->fault.load()<<" "<<peer.runtime->message<<"\n";}assert(peer.state->fault.load()==none);}

int main(int argc,const char *argv[]){@autoreleasepool{
    assert(argc==3);NSString *python=@(argv[1]),*worker=@(argv[2]);
    for(unsigned rate:{44100u,48000u}){
        Peer peer(rate,python,worker);const auto delay=peer.state->latencyFrames.load();
        const auto rendered=peer.render(delay+rate,5000);
        assertHealthy(peer);
        const auto peak=std::max_element(rendered.begin(),rendered.end(),[](float a,float b){return std::abs(a)<std::abs(b);})-rendered.begin();
        assert(std::abs(int64_t(peak)-int64_t(delay+5000))<=1);assert(rendered[peak]>.7f);
        for(unsigned i=0;i<rendered.size();i++)assert(rendered[i]==(i==delay+5000?1.f:0.f));
        peer.state->requestedEpoch.fetch_add(1);
        const auto next=peer.render(delay+rate,-1,-.25f);assertHealthy(peer);
        for(unsigned i=0;i<delay;i++)assert(next[i]==0);
        assert(std::abs(next.back()+.25f)<1e-4f);
        std::cout<<"CATSTEM_SRC_"<<rate<<"_LATENCY_"<<delay<<"_EPOCH_OK\n";
    }
    {
        Peer peer(44100,python,worker);peer.state->soloMask.store(1u<<2);peer.state->gains[2].store(2);
        auto mixed=peer.render(modelDelay+44100,-1,.5f);assertHealthy(peer);assert(std::abs(mixed.back()-.3f)<1e-4f);
        peer.state->muteMask.store(1u<<2);auto muted=peer.render(hop,-1,.5f);assertHealthy(peer);assert(std::abs(muted.back())<1e-5f);
        peer.state->enabled.store(false);auto bypass=peer.render(hop,-1,.5f);assertHealthy(peer);assert(std::abs(bypass.back()-.5f)<1e-4f);
        std::cout<<"CATSTEM_GAIN_MUTE_SOLO_DELAYED_BYPASS_OK\n";
    }
    for(NSString *mode in @[@"oversized",@"wrong_clock",@"bad_json_types",@"fractional_metadata"]){
        Peer peer(44100,python,worker,mode);peer.render(modelDelay+hop);
        assert(peer.state->fault.load()==protocolFailure);assert(peer.runtime->cancelled.load());
        std::cout<<"CATSTEM_PROTOCOL_REJECT_"<<mode.UTF8String<<"_OK\n";
    }
    {
        Peer peer(44100,python,worker,@"stalled");
        for(unsigned i=0;i<1000&&!peer.state->warmReady.load();i++)std::this_thread::sleep_for(std::chrono::milliseconds(1));
        assert(peer.state->warmReady.load());peer.render(hop);
        for(unsigned i=0;i<1000&&peer.runtime->sent.load()==0;i++)std::this_thread::sleep_for(std::chrono::milliseconds(1));
        assert(peer.runtime->sent.load()>0);std::this_thread::sleep_for(std::chrono::milliseconds(20));
        auto began=std::chrono::steady_clock::now();peer.runtime->cancelled.store(true);peer.state->admitted.store(false);peer.process.join();
        assert(std::chrono::steady_clock::now()-began<std::chrono::seconds(2));
        std::cout<<"CATSTEM_PARTIAL_PROTOCOL_CANCELLATION_OK\n";
    }
    {
        auto state=std::make_shared<State>();state->prepare(44100);state->admitted.store(true);state->warmReady.store(true);
        std::array<float,512> input{},left{},right{};
        for(unsigned offset=0;offset<modelDelay+512;offset+=512){
            forbidRenderAllocation=true;state->process(input.data(),input.data(),left.data(),right.data(),512,nullptr);forbidRenderAllocation=false;
            if(state->input.consumerSlot())state->input.consume();
            if(offset<modelDelay)assert(state->fault.load()==none);
        }
        assert(state->fault.load()==outputUnderrun);assert(state->underruns.load()==1);
        std::cout<<"CATSTEM_REALTIME_NO_ALLOC_PRIMING_UNDERRUN_OK\n";
    }
    {
        auto state=std::make_shared<State>();state->prepare(44100);state->admitted.store(true);state->warmReady.store(true);
        std::array<float,64> input{},left{},right{};
        for(unsigned i=0;i<=ringSlots;i++){forbidRenderAllocation=true;state->process(input.data(),input.data(),left.data(),right.data(),64,nullptr);forbidRenderAllocation=false;}
        assert(state->fault.load()==inputOverrun);assert(state->overruns.load()==1);
        assert(state->input.write.load()-state->input.read.load()==ringSlots);
        std::cout<<"CATSTEM_REALTIME_BOUNDED_OVERRUN_OK\n";
    }
    {
        auto first=[JarasStemSeparator makeNode],second=[JarasStemSeparator makeNode];
        NSError *error=nil;NSURL *directory=[NSURL fileURLWithPath:NSTemporaryDirectory()];
        assert([JarasStemSeparator start:first executable:[NSURL fileURLWithPath:python] worker:[NSURL fileURLWithPath:worker] modelCache:directory error:&error]);
        assert(![JarasStemSeparator start:second executable:[NSURL fileURLWithPath:python] worker:[NSURL fileURLWithPath:worker] modelCache:directory error:&error]);
        assert(second.AUAudioUnit.latency==0);assert(first.AUAudioUnit.latency>0);
        auto offline=[JarasStemSeparator makeNode];[JarasStemSeparator setOfflineRendering:offline enabled:YES];
        assert([JarasStemSeparator start:offline executable:[NSURL fileURLWithPath:python] worker:[NSURL fileURLWithPath:worker] modelCache:directory error:&error]);
        assert(offlineWorkerLease.load()&&workerLease.load());[JarasStemSeparator stop:offline];
        auto started=std::chrono::steady_clock::now();[JarasStemSeparator stop:first];assert(std::chrono::steady_clock::now()-started<std::chrono::milliseconds(50));
        for(unsigned i=0;i<500&&(workerLease.load()||offlineWorkerLease.load());i++)std::this_thread::sleep_for(std::chrono::milliseconds(5));
        assert(!workerLease.load()&&!offlineWorkerLease.load());std::cout<<"CATSTEM_ADMISSION_ASYNC_STOP_OK\n";
    }
    {
        Peer peer(44100,python,worker,@"jitter");
        for(unsigned i=0;i<2000&&!peer.state->warmReady.load();i++)std::this_thread::sleep_for(std::chrono::milliseconds(2));
        assert(peer.state->warmReady.load());peer.state->offline.store(false);
        const auto start=std::chrono::steady_clock::now();
        for(unsigned frame=0;frame<44100*3;frame+=512){
            std::this_thread::sleep_until(start+std::chrono::microseconds(uint64_t(frame)*1000000/44100));
            peer.render(512,-1,.25f);assertHealthy(peer);
        }
        assert(peer.state->underruns.load()==0);std::cout<<"CATSTEM_REALTIME_JITTER_160MS_OK\n";
    }
    for(double rate:{44100.,48000.}){
        auto engine=[AVAudioEngine new];auto player=[AVAudioPlayerNode new];auto effect=[JarasStemSeparator makeNode];
        auto format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];NSError *error=nil;
        assert([engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:format maximumFrameCount:512 error:&error]);
        [engine attachNode:player];[engine attachNode:effect];
        [engine connect:player to:effect format:format];[engine connect:effect to:engine.mainMixerNode format:format];
        [JarasStemSeparator setOfflineRendering:effect enabled:YES];
        assert([JarasStemSeparator start:effect executable:[NSURL fileURLWithPath:python] worker:[NSURL fileURLWithPath:worker] modelCache:[NSURL fileURLWithPath:NSTemporaryDirectory()] error:&error]);
        assert([engine startAndReturnError:&error]);
        for(unsigned i=0;i<2000&&![[JarasStemSeparator status:effect][@"ready"] boolValue];i++)std::this_thread::sleep_for(std::chrono::milliseconds(2));
        assert([[JarasStemSeparator status:effect][@"ready"] boolValue]);
        auto input=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:AVAudioFrameCount(rate*2)];input.frameLength=input.frameCapacity;
        for(unsigned ch=0;ch<2;ch++){std::fill(input.floatChannelData[ch],input.floatChannelData[ch]+input.frameLength,0.f);input.floatChannelData[ch][5000]=.5f;}
        [player scheduleBuffer:input completionHandler:nil];[player play];
        auto buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:512];std::vector<float> output;
        for(unsigned i=0;i<unsigned(rate*1.5)/512;i++){
            auto result=[engine renderOffline:512 toBuffer:buffer error:&error];assert(result==AVAudioEngineManualRenderingStatusSuccess);
            output.insert(output.end(),buffer.floatChannelData[0],buffer.floatChannelData[0]+buffer.frameLength);
        }
        const auto peak=std::max_element(output.begin(),output.end())-output.begin();
        const auto delay=unsigned(std::ceil(double(modelDelay)*rate/modelRate));
        assert(player.outputPresentationLatency >= effect.AUAudioUnit.latency - 1.0/rate);
        assert(std::abs(int64_t(peak)-int64_t(delay+5000))<=1);assert(output[peak]>.49f);
        assert(![[JarasStemSeparator status:effect][@"state"] isEqual:@"fault"]);
        [engine stop];std::thread cleanup([effect]{@autoreleasepool{NSError *failure=nil;assert([JarasStemSeparator stopAndWait:effect timeout:5 error:&failure]);}});cleanup.join();
        std::cout<<"CATSTEM_AVAUDIOENGINE_"<<rate<<"_LATENCY_OK\n";
    }
    std::cout<<"CATSTEM_REALTIME_NATIVE_OK\n";
}}
