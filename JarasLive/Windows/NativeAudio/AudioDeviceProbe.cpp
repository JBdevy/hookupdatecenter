#include "WasapiDevice.h"
#include "CallbackHub.h"
#include "CallbackHubTests/AllocationAudit.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <iostream>
#include <thread>
#include <string>
#if CATLIVE_DIRECT_ASIO
#include "AsioDevice.h"
#endif
using namespace catlive::native::audio;
namespace {
struct Observation {
    std::atomic<std::uint32_t> callbacks{0}, frames{0}, invalid{0};
};
static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
void silence(void *context,const AudioBlock &block) noexcept {
    auto &o=*static_cast<Observation*>(context);
    if(!block.outputs||!block.outputChannels||!block.frames||block.sampleRate<=0) {
        o.invalid.fetch_add(1,std::memory_order_relaxed);return;
    }
    for(std::uint32_t channel=0;channel<block.outputChannels;++channel)
        for(std::uint32_t frame=0;frame<block.frames;++frame)
            if(block.outputs[channel][frame]!=0) {o.invalid.fetch_add(1,std::memory_order_relaxed);break;}
    o.frames.fetch_add(block.frames,std::memory_order_relaxed);
    o.callbacks.fetch_add(1,std::memory_order_relaxed);
}
struct HubObservation {
    std::atomic<std::uint32_t> created{0},destroyed{0},wrongThread{0},invalid{0};
    std::atomic<std::uint64_t> clientCalls{0};
    std::thread::id controlThread=std::this_thread::get_id();
};
struct SilentClient {
    HubObservation &observation;
    ~SilentClient() {
        if(std::this_thread::get_id()!=observation.controlThread)
            observation.wrongThread.fetch_add(1,std::memory_order_relaxed);
        observation.destroyed.fetch_add(1,std::memory_order_relaxed);
    }
    static void render(void *context,const AudioBlock &block) noexcept {
        auto &o=static_cast<SilentClient*>(context)->observation;
        if(!block.outputs||!block.outputChannels||!block.frames)
            o.invalid.fetch_add(1,std::memory_order_relaxed);
        for(std::uint32_t channel=0;channel<block.outputChannels;++channel)
            for(std::uint32_t frame=0;frame<block.frames;++frame)
                if(block.outputs[channel][frame]!=0) {
                    o.invalid.fetch_add(1,std::memory_order_relaxed);break;
                }
        // No audio is generated: scratch starts at zero and stays zero.
        o.clientCalls.fetch_add(1,std::memory_order_relaxed);
    }
};
struct HubCallback {
    CallbackHub &hub;
    Observation &observation;
    static void render(void *context,const AudioBlock &block) noexcept {
        auto &self=*static_cast<HubCallback*>(context);
        testing::AllocationAuditScope audit;
        self.hub.render(block);
        silence(&self.observation,block);
    }
};
void hubSmoke(WasapiDevice &device) {
    const auto &info=device.info();
    CallbackHub::Configuration configuration;
    configuration.sampleRate=info.sampleRate;
    configuration.maximumBlockFrames=info.maximumCallbackFrames;
    configuration.inputPhysicalIndices=info.inputChannelIndices;
    configuration.outputPhysicalIndices=info.outputChannelIndices;
    for(auto channel:configuration.inputPhysicalIndices)
        configuration.physicalInputChannels=std::max(configuration.physicalInputChannels,channel+1);
    for(auto channel:configuration.outputPhysicalIndices)
        configuration.physicalOutputChannels=std::max(configuration.physicalOutputChannels,channel+1);
    Observation observation;HubObservation owners;
    // Owners outlive the hub even if a hardware check throws before reset.
    CallbackHub hub(std::move(configuration));HubCallback callback{hub,observation};
    const auto publish=[&](unsigned count) {
        std::vector<CallbackHub::Client> clients;
        clients.reserve(count);
        for(unsigned i=0;i<count;++i) {
            auto owner=std::shared_ptr<SilentClient>(new SilentClient{owners});
            owners.created.fetch_add(1,std::memory_order_relaxed);
            clients.push_back({i+1,SilentClient::render,owner.get(),owner});
        }
        return hub.publish(clients);
    };
    publish(2);
    // Stop the device before hub/context destruction even on a failed check.
    struct StopGuard {
        WasapiDevice &device;
        ~StopGuard() {device.stop();}
    } stopGuard{device};
    device.start(HubCallback::render,&callback);
    std::uint64_t latest=0;
    for(unsigned update=0;update<40;++update) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        // Adds, removes and replaces independently owned silent clients while
        // the hardware callback is active. Every publication remains nonempty.
        latest=publish(1+update%3);
        hub.collectRetired();
    }
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
    while(hub.statistics().adoptedGeneration!=latest&&std::chrono::steady_clock::now()<deadline) {
        hub.collectRetired();std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    const auto status=device.status();device.stop();
    const auto count=observation.callbacks.load();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    if(!count||observation.invalid.load()||count!=observation.callbacks.load()
       ||status.state!=DeviceState::running||hub.statistics().adoptedGeneration!=latest)
        throw std::runtime_error("Native callback hub hardware/lifetime check failed");
    device.start(HubCallback::render,&callback);
    std::this_thread::sleep_for(std::chrono::milliseconds(250));device.stop();
    const auto stats=hub.statistics();hub.resetAfterStop();
    if(observation.callbacks.load()<=count||stats.invalidBlocks||stats.overlappingCallbacks
       ||owners.invalid.load()||owners.wrongThread.load()||owners.created.load()!=owners.destroyed.load()
       ||owners.clientCalls.load()==0||testing::callbackAllocations.load()||testing::callbackDeallocations.load())
        throw std::runtime_error("Native callback hub allocation, mapping, restart or reclamation check failed");
    std::cout<<"NATIVE_CALLBACK_HUB_SHARED_SILENCE_OK callbacks="<<observation.callbacks.load()
        <<" clients_created="<<owners.created.load()<<" clients_destroyed="<<owners.destroyed.load()
        <<" client_calls="<<owners.clientCalls.load()<<" allocations="<<testing::callbackAllocations.load()
        <<" deallocations="<<testing::callbackDeallocations.load()<<" mmcss="<<status.mmcssActive<<"\n";
}
}
int main(int argc,char **argv) {
    try {
        const std::string mode=argc>1?argv[1]:"--enumerate";
#if CATLIVE_DIRECT_ASIO
        if(mode=="--enumerate-asio") {
            for(const auto &endpoint:AsioDevice::enumerate())std::wcout<<endpoint.name<<L" "<<endpoint.id<<L"\n";
            return 0;
        }
#endif
        if(mode=="--enumerate") {
            for(const auto &endpoint:WasapiDevice::enumerate()) {
                const auto capabilities=WasapiDevice::inspect(endpoint.id);
                std::wcout<<(endpoint.direction==Direction::render?L"OUTPUT ":L"INPUT ")<<endpoint.name
                    <<L" channels="<<capabilities.mixFormat.channels<<L" rate="<<capabilities.mixFormat.sampleRate
                    <<L" default="<<endpoint.defaultConsole<<L"\n";
            }
            return 0;
        }
        const bool shared=mode=="--smoke-shared", exclusive=mode=="--smoke-exclusive", lowLatency=mode=="--smoke-low-latency", hub=mode=="--smoke-hub-shared";
        if(!shared&&!exclusive&&!lowLatency&&!hub) {
            std::cerr<<"Use --enumerate, --enumerate-asio, --smoke-shared, --smoke-low-latency, --smoke-exclusive or --smoke-hub-shared\n";
            return 2;
        }
        WasapiDevice device;Observation observation;StreamRequest request;
        request.mode=exclusive?DeviceMode::exclusive:lowLatency?DeviceMode::sharedLowLatency:DeviceMode::shared;
        request.direction=Direction::render;
        if(argc>2) {
            if(std::string(argv[2])!="pcm16")throw std::runtime_error("The optional wire format must be pcm16");
            for(const auto &endpoint:WasapiDevice::enumerate())if(endpoint.direction==Direction::render&&endpoint.defaultMultimedia) {
                request.endpointId=endpoint.id;
                auto format=WasapiDevice::inspect(endpoint.id).mixFormat;
                format.encoding=SampleEncoding::signedPCM;format.containerBits=format.validBits=16;
                if(!WasapiDevice::probeFormat(endpoint.id,request.mode,format).exact)
                    throw std::runtime_error("The default endpoint rejected the explicitly requested PCM16 format");
                request.format=format;break;
            }
            if(!request.format)throw std::runtime_error("No default render endpoint available");
        }
        device.open(request);const auto rate=device.info().sampleRate;const auto channels=device.info().outputChannels;
        if(hub) {hubSmoke(device);device.close();return 0;}
        device.start(silence,&observation);
        std::this_thread::sleep_for(std::chrono::seconds(2));
        const auto status=device.status();device.stop();
        const auto count=observation.callbacks.load();
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        if(count==0||observation.invalid.load()!=0||count!=observation.callbacks.load()||status.state!=DeviceState::running)
            throw std::runtime_error("Render callback/lifetime check failed");
        device.start(silence,&observation);std::this_thread::sleep_for(std::chrono::milliseconds(250));device.close();
        if(observation.callbacks.load()<=count)throw std::runtime_error("Restart failed to deliver callbacks");
        std::cout<<"NATIVE_WASAPI_"<<(exclusive?"EXCLUSIVE":lowLatency?"LOW_LATENCY":"SHARED")<<"_SILENCE_STOP_RESTART_OK callbacks="<<observation.callbacks.load()
            <<" frames="<<observation.frames.load()<<" rate="<<rate<<" channels="<<channels<<" mmcss="<<status.mmcssActive<<"\n";
        return 0;
    }catch(const std::exception &error){std::cerr<<error.what()<<'\n';return 1;}
}
