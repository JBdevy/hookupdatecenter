#include "../ClockedDuplexDevice.h"
#include "../CallbackHubTests/AllocationAudit.h"
#include <array>
#include <cstdio>
#include <cstdlib>
using namespace catlive::native::audio;
using namespace catlive::native::audio::testing;
namespace {
void check(bool value, const char* message) { if (!value) { std::fprintf(stderr,"FAIL: %s\n",message); std::abort(); } }
class FakeDevice final : public AudioDevice {
public:
    StreamInfo stream; StreamRequest request; DeviceStatus current;
    ProcessCallback callback = nullptr; void* user = nullptr;
    bool failOpen = false, failStart = false, callbackDuringStart = false;
    unsigned stops = 0, closes = 0, changes = 0;
    std::array<float,128> left{}, right{};
    FakeDevice(bool input) {
        stream.endpointId = input ? L"capture" : L"render";
        stream.sampleRate = input ? 44100 : 48000;
        stream.inputChannels = input ? 2 : 0; stream.outputChannels = input ? 0 : 2;
        if (input) stream.inputChannelIndices = {3,1}; else stream.outputChannelIndices = {2,0};
        stream.maximumCallbackFrames = stream.bufferFrames = stream.periodFrames = 128;
    }
    void open(const StreamRequest& value) override { request=value; if(failOpen)throw AudioDeviceError("open");current.state=DeviceState::prepared; }
    void start(ProcessCallback value, void* context) override {
        callback=value; user=context;current.state=DeviceState::running;
        if(callbackDuringStart) tick();
        if(failStart)throw AudioDeviceError("start");
    }
    void stop() noexcept override { ++stops;callback=nullptr;user=nullptr;current.state=DeviceState::stopped; }
    void close() noexcept override { stop();++closes;current.state=DeviceState::closed; }
    const StreamInfo& info() const noexcept override { return stream; }
    DeviceStatus status() const noexcept override { return current; }
    std::uint32_t consumeDeviceChanges() noexcept override { return std::exchange(changes,0); }
    void tick(unsigned flags=0) {
        if(!callback)return;
        left.fill(stream.inputChannels?.25f:0);right.fill(stream.inputChannels?-.75f:0);
        const float* inputs[]{left.data(),right.data()}; float* outputs[]{left.data(),right.data()};
        AudioBlock block{stream.inputChannels?inputs:nullptr,stream.outputChannels?outputs:nullptr,
            stream.inputChannels,stream.outputChannels,128,stream.sampleRate,current.frames,1234,0,flags|timestampValid};
        {AllocationAuditScope audit;callback(user,block);}
        ++current.callbacks;current.frames+=128;
    }
};
struct Client {
    unsigned calls=0,audible=0; bool valid=true;
    static void process(void* user,const AudioBlock& block) noexcept {
        auto& c=*static_cast<Client*>(user);++c.calls;
        c.valid &= block.sampleRate==48000 && block.inputChannels==2 && block.outputChannels==2 && block.qpcTime100ns==1234;
        for(unsigned frame=0;frame<block.frames;++frame) {
            const auto a=block.inputs[0][frame],b=block.inputs[1][frame];
            if(a!=0){++c.audible;c.valid &= std::abs(a-.25f)<1.e-6 && std::abs(b+.75f)<1.e-6;}
            block.outputs[0][frame]=.5f;block.outputs[1][frame]=-.5f;
        }
    }
};
void lifecycle() {
    auto output=std::make_unique<FakeDevice>(false),input=std::make_unique<FakeDevice>(true);
    auto* out=output.get();auto* in=input.get();
    ClockedDuplexDevice device(std::move(output),std::move(input));
    StreamRequest request;request.direction=Direction::duplex;request.endpointId=L"out";request.inputEndpointId=L"in";
    request.inputChannelIndices={3,1};request.outputChannelIndices={2,0};
    device.open(request);
    check(out->request.direction==Direction::render && in->request.direction==Direction::capture,"directions split");
    check(out->request.endpointId==L"out" && in->request.endpointId==L"in","independent endpoint selection");
    check(device.info().sampleRate==48000 && device.info().inputChannelIndices==request.inputChannelIndices,"output graph clock and physical input map");
    check(device.info().inputLatency100ns>0,"capture bridge latency reported");
    Client client;out->callbackDuringStart=true;device.start(Client::process,&client);
    check(client.calls==1 && client.audible==0,"render start callback is safe before capture arrives");
    for(int i=0;i<5;++i)in->tick();
    check(client.calls==1,"capture must never advance the graph");
    out->tick();check(client.calls==2 && client.audible==128 && client.valid,"capture reaches graph on output clock");
    check(out->left[0]==.5f && out->right[0]==-.5f,"render is preserved");
    for(int i=0;i<20;++i)out->tick();
    check(out->left[0]==.5f && device.status().discontinuities>0,"capture starvation cannot stop output");
    in->current.state=DeviceState::invalidated;in->current.nativeError=123;in->changes=endpointInvalidated;
    check(device.status().state==DeviceState::invalidated && device.status().nativeError==123,"capture invalidation reported");
    check(device.consumeDeviceChanges()&endpointInvalidated,"capture device changes forwarded");
    const auto calls=client.calls,audible=client.audible;device.stop();out->tick();in->tick();check(client.calls==calls,"no callbacks after stop");
    device.start(Client::process,&client);check(client.calls==calls+1 && client.audible==audible,"restart has no stale input");
    device.close();check(device.status().state==DeviceState::closed,"close joins both endpoints");
    std::puts("CLOCKED_DUPLEX_SINGLE_GRAPH_CLOCK_CAPTURE_STARVATION_AND_RESTART_OK");
}
void failures() {
    for(int failure=0;failure<4;++failure) {
        auto output=std::make_unique<FakeDevice>(false),input=std::make_unique<FakeDevice>(true);
        auto* out=output.get();auto* in=input.get();
        out->failOpen=failure==0;in->failOpen=failure==1;out->failStart=failure==2;in->failStart=failure==3;
        out->callbackDuringStart=in->callbackDuringStart=true;
        ClockedDuplexDevice device(std::move(output),std::move(input));
        StreamRequest request;request.direction=Direction::duplex;Client client;
        bool threw=false;try{device.open(request);device.start(Client::process,&client);}catch(const AudioDeviceError&){threw=true;}
        check(threw && !out->callback && !in->callback,"failed open/start joins all partially started callbacks");
        check(out->stops>0 && in->stops>0,"both endpoints stopped on rollback");
    }
    std::puts("CLOCKED_DUPLEX_PARTIAL_OPEN_START_ROLLBACK_OK");
}
}
int main(){lifecycle();failures();check(callbackAllocations.load()==0 && callbackDeallocations.load()==0,"callback allocated/freed memory");std::puts("CLOCKED_DUPLEX_CALLBACK_NO_HEAP_OK");}
