// Exercise the production IBStream used by VST3 setState/getState without
// opening a window, loading a third-party plugin, or starting an audio device.
#include "../../../Apple/Bridge/JarasVST3.mm"
#include <cassert>
#include <limits>
#include <random>
#include <cstdio>
#include <thread>
#include <chrono>
#include <dlfcn.h>

static std::atomic<bool> exitEntered{false},exitMayFinish{false};
static void pauseModuleExit(){
    exitEntered.store(true,std::memory_order_release);
    while(!exitMayFinish.load(std::memory_order_acquire))std::this_thread::yield();
}

int main(int argc,char **argv) { @autoreleasepool {
    Stream stream;
    uint8 original[]{1,2,3,4};int32 count=-1;
    assert(stream.write(original,4,&count)==kResultOk&&count==4);
    int64 position=-1;
    assert(stream.seek(-2,IBStream::kIBSeekEnd,&position)==kResultOk&&position==2);
    uint8 output[]{9,9,9,9};
    assert(stream.read(output,4,&count)==kResultFalse&&count==2);
    assert(output[0]==3&&output[1]==4&&output[2]==9&&output[3]==9);
    assert(stream.read(output,1,&count)==kResultFalse&&count==0);
    assert(stream.tell(&position)==kResultOk&&position==4);

    // Legal sparse seek/write round-trips plugin state, including zero fill.
    assert(stream.seek(8,IBStream::kIBSeekSet,nullptr)==kResultOk);
    assert(stream.read(output,1,&count)==kResultFalse&&count==0&&stream.position==8);
    assert(stream.write(original,2,&count)==kResultOk&&count==2);
    assert(stream.bytes.size()==10&&stream.bytes[4]==0&&stream.bytes[7]==0);
    assert(stream.seek(-2,IBStream::kIBSeekCur,nullptr)==kResultOk);
    assert(stream.read(output,2,&count)==kResultOk&&count==2&&output[0]==1&&output[1]==2);
    Stream decoded([[NSData alloc]initWithBase64EncodedString:stream.base64() options:0]);
    assert(decoded.bytes==stream.bytes&&decoded.position==0);

    // A corrupted length/offset is rejected before any pointer arithmetic,
    // allocation, or signed addition. Failure leaves the valid cursor intact.
    for(const int64 cursor:{int64(0),int64(1),int64(10),Stream::maximumSize}) {
        assert(stream.seek(cursor,IBStream::kIBSeekSet,nullptr)==kResultOk);
        for(const int64 offset:{std::numeric_limits<int64>::max(),std::numeric_limits<int64>::min()}) {
            for(const auto mode:{IBStream::kIBSeekSet,IBStream::kIBSeekCur,IBStream::kIBSeekEnd}) {
                position=-7;
                assert(stream.seek(offset,mode,&position)==kInvalidArgument);
                assert(stream.position==cursor&&position==-7);
            }
        }
    }
    count=-1;
    assert(stream.write(original,1,&count)==kInvalidArgument&&count==0);
    assert(stream.bytes.size()==10);
    assert(stream.seek(0,3,nullptr)==kInvalidArgument);
    assert(stream.seek(0,IBStream::kIBSeekSet,nullptr)==kResultOk);
    for(int32 size:{int32(-1),std::numeric_limits<int32>::min(),int32(1)}) {
        count=-1;assert(stream.read(nullptr,size,&count)==kInvalidArgument&&count==0);
        count=-1;assert(stream.write(nullptr,size,&count)==kInvalidArgument&&count==0);
    }
    assert(stream.read(nullptr,0,&count)==kResultOk&&count==0);
    assert(stream.write(nullptr,0,&count)==kResultOk&&count==0);
    assert(stream.tell(nullptr)==kInvalidArgument);

    // Every truncation returns only initialized bytes; the remaining caller
    // buffer is untouched, so plugins can detect an incomplete state reliably.
    for(size_t length=0;length<4;++length) {
        Stream truncated([NSData dataWithBytes:original length:length]);
        std::fill(std::begin(output),std::end(output),uint8(99));
        assert(truncated.read(output,4,&count)==kResultFalse&&count==length);
        for(size_t i=0;i<4;++i)assert(output[i]==(i<length?original[i]:99));
    }

    // Fuzz signed offsets and origins against an overflow-free wide oracle.
    std::mt19937_64 random(0xCA711FE);
    for(int i=0;i<20000;++i) {
        const int64 origin=random()%(Stream::maximumSize+1);
        assert(stream.seek(origin,IBStream::kIBSeekSet,nullptr)==kResultOk);
        int64 offset=int64(random());const int mode=int(random()%5)-1;
        if(i%3==0)offset=int64(random()%1024)-512;
        const __int128 base=mode==IBStream::kIBSeekCur?origin:mode==IBStream::kIBSeekEnd?stream.bytes.size():0;
        const __int128 next=base+offset;
        const bool valid=mode>=0&&mode<=2&&next>=0&&next<=Stream::maximumSize;
        const auto result=stream.seek(offset,mode,nullptr);
        assert((result==kResultOk)==valid);
        assert(stream.position==(valid?int64(next):origin));
    }
    std::puts("VST3_STATE_STREAM_BOUNDS_TRUNCATION_OVERFLOW_AND_ROUNDTRIP_OK");

    // Retire and recreate real fixture processors while an audio thread reads
    // the published chain. ASan verifies that a replaced chain/module remains
    // alive until the in-flight render callback releases its reader lease.
    assert(argc==2);
    NSDictionary *spec=@{@"id":@"lifetime",@"path":@(argv[1]),
        @"classID":@"1234123456785678ABCDEF0012345678",@"bypassed":@NO};
    Kernel kernel;
    std::atomic<bool> running{true};std::atomic<unsigned> renders{0};
    auto first=std::make_unique<Chain>();
    first->instances.push_back(std::make_shared<Instance>(spec,48000,false));
    kernel.replace(std::move(first));
    std::thread audio([&] {
        std::array<float,64> left{},right{};
        struct Buffers { AudioBufferList list;AudioBuffer second; } buffers{};
        buffers.list.mNumberBuffers=2;
        buffers.list.mBuffers[0]={1,sizeof(left),left.data()};
        buffers.second={1,sizeof(right),right.data()};
        AudioTimeStamp clock{};clock.mFlags=kAudioTimeStampSampleTimeValid;
        while(running.load(std::memory_order_acquire)) {
            left.fill(.2f);right.fill(.2f);
            kernel.process(&buffers.list,64,&clock);clock.mSampleTime+=64;
            for(auto sample:left)assert(std::isfinite(sample)&&sample>=0&&sample<=.2f);
            renders.fetch_add(1,std::memory_order_release);
        }
    });
    while(renders.load(std::memory_order_acquire)<100)std::this_thread::yield();
    for(int i=0;i<128;++i) {
        auto next=std::make_unique<Chain>();
        next->instances.push_back(std::make_shared<Instance>(spec,48000,false));
        kernel.replace(std::move(next));
        if(i%4==0)kernel.replace(nullptr);
        std::this_thread::yield();
    }
    running.store(false,std::memory_order_release);audio.join();
    kernel.replace(nullptr);
    assert(kernel.retired.empty()&&kernel.readers.load()==0);
    std::puts("VST3_RENDER_CONCURRENT_REPLACEMENT_REMOVAL_AND_MODULE_LIFETIME_OK");

    // Keep code mapped only for this diagnostic: duplicate bundleEntry is
    // itself the failure. A baseline implementation can otherwise unmap the
    // old thread while it is paused inside bundleExit and obscure the race.
    NSString *executable=[@(argv[1]) stringByAppendingPathComponent:@"Contents/MacOS/GainFixture"];
    void *diagnostics=dlopen(executable.UTF8String,RTLD_NOW|RTLD_LOCAL);assert(diagnostics);
    auto setExitCallback=(void (*)(void (*)()))dlsym(diagnostics,"catliveSetModuleExitCallback");
    auto overlaps=(unsigned (*)())dlsym(diagnostics,"catliveOverlappingModuleEntries");
    assert(setExitCallback&&overlaps);
    auto module=loadModule(@(argv[1]));
    setExitCallback(pauseModuleExit);
    std::thread release([owned=std::move(module)]()mutable{owned.reset();});
    while(!exitEntered.load(std::memory_order_acquire))std::this_thread::yield();
    std::shared_ptr<Module> reloaded;
    std::atomic<bool> reloadStarted{false},reloadFinished{false};
    std::thread reload([&]{@autoreleasepool{
        reloadStarted=true;reloaded=loadModule(@(argv[1]));reloadFinished=true;
    }});
    while(!reloadStarted.load())std::this_thread::yield();
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    const bool completedDuringExit=reloadFinished.load();
    setExitCallback(nullptr);exitMayFinish=true;
    release.join();reload.join();
    assert(!completedDuringExit&&overlaps()==0);
    assert(reloaded&&reloaded->factory->countClasses()==1);
    reloaded.reset();dlclose(diagnostics);
    std::puts("VST3_MODULE_RELOAD_WAITS_FOR_PREVIOUS_BUNDLE_EXIT_AND_UNLOAD_OK");

    // CoreAudio may query AU latency on a different thread while inserts are
    // removed/replaced. The chain must stay alive through the whole query.
    setenv("CATLIVE_TEST_VST3_LATENCY_FRAMES","777",1);
    auto unit=(JarasVSTAudioUnit *)[JarasVST3 makeNode].AUAudioUnit;
    std::atomic<bool> querying{true};std::atomic<unsigned> queries{0};
    std::thread queryLatency([&]{
        while(querying.load()){
            const double value=unit.latency;
            assert(value==0||std::abs(value-777.0/48000)<1e-12);
            ++queries;
        }
    });
    for(int i=0;i<256;++i){
        auto next=std::make_unique<Chain>();
        auto instance=std::make_shared<Instance>(spec,48000,false);
        instance->bypass=(i%3==0);next->instances.push_back(instance);
        unit->kernel.replace(std::move(next));
        unit->kernel.replace(nullptr);
    }
    querying=false;queryLatency.join();unsetenv("CATLIVE_TEST_VST3_LATENCY_FRAMES");
    assert(queries.load()>0&&unit.latency==0);
    std::puts("VST3_LATENCY_QUERY_CONCURRENT_REPLACEMENT_BYPASS_AND_REMOVAL_OK");

    // Some processors change latency when a parameter selects a processing
    // mode. Protecting chain ownership must not freeze the setup-time value.
    setenv("CATLIVE_TEST_VST3_DYNAMIC_LATENCY","1",1);
    auto dynamicNode=[JarasVST3 makeNode];NSError *error=nil;
    assert([JarasVST3 configure:dynamicNode plugins:@[spec] error:&error]);
    assert(std::abs(dynamicNode.AUAudioUnit.latency-2048.0/48000)<1e-12);
    for(const double value:{0.25,0.75,0.0,1.0}){
        [JarasVST3 setParameter:dynamicNode identifier:@"lifetime" parameter:0 value:value];
        assert(std::abs(dynamicNode.AUAudioUnit.latency-value*4096/48000)<1e-12);
    }
    assert([JarasVST3 configure:dynamicNode plugins:@[] error:&error]);
    unsetenv("CATLIVE_TEST_VST3_DYNAMIC_LATENCY");
    assert(dynamicNode.AUAudioUnit.latency==0);
    std::puts("VST3_PARAMETER_DEPENDENT_LATENCY_REMAINS_CURRENT_WITHOUT_RECONFIGURE_OK");
} }
