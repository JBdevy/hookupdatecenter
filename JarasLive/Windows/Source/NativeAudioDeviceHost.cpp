#include "NativeAudioDeviceHost.h"
#if CATLIVE_NATIVE_DEVICE_HOST
#include "../NativeAudio/WasapiDevice.h"
#include "../NativeAudio/AsioDevice.h"
#include "../NativeAudio/ClockedDuplexDevice.h"
#include "../NativeAudio/CallbackHub.h"
#include <chrono>
#include <numeric>
#include <thread>

namespace catlive {
namespace {
using namespace juce;
namespace io = native::audio;
class Device;
class Host final : public AudioDeviceManager, private Timer {
public:
    struct Client {
        AudioIODeviceCallback* callback;
        std::uint64_t id;
        std::atomic<bool>* failed;
        static void process(void* context, const io::AudioBlock& block) noexcept {
            auto& self = *static_cast<Client*>(context);
            const std::uint64_t time = block.qpcTime100ns * 100;
            AudioIODeviceCallbackContext timing;
            timing.hostTimeNs = (block.flags & io::timestampValid) ? &time : nullptr;
            try {
                self.callback->audioDeviceIOCallbackWithContext(block.inputs, int(block.inputChannels),
                    block.outputs, int(block.outputChannels), int(block.frames), timing);
            } catch (...) {
                for(unsigned channel=0;channel<block.outputChannels;++channel)
                    if(block.outputs[channel])std::fill_n(block.outputs[channel],block.frames,0.f);
                self.failed->store(true,std::memory_order_relaxed);
            }
        }
    };
    Host() = default;
    ~Host() override { stopTimer(); closeAudioDevice(); }
    void createAudioDeviceTypes(OwnedArray<AudioIODeviceType>&) override;
    void add(AudioIODeviceCallback*);
    void remove(AudioIODeviceCallback*);
    std::vector<io::CallbackHub::Client> snapshot() const {
        std::vector<io::CallbackHub::Client> result;
        for (const auto& client : clients) result.push_back({client->id, &Client::process, client.get(), client});
        return result;
    }
    double cpu() const noexcept { return load.load(std::memory_order_relaxed); }
    std::atomic<double> load{0};
    std::atomic<bool> clientFailed{false};
private:
    std::vector<std::shared_ptr<Client>> clients;
    std::uint64_t nextID = 1;
    void timerCallback() override;
};
String modeName(io::DeviceMode mode) {
    switch(mode) {
        case io::DeviceMode::exclusive: return "Windows Audio (Exclusive Mode)";
        case io::DeviceMode::sharedLowLatency: return "Windows Audio (Low Latency Mode)";
        case io::DeviceMode::loopback: return "Windows Audio (Loopback)";
        case io::DeviceMode::asio: return "ASIO";
        default: return "Windows Audio";
    }
}
std::vector<std::uint32_t> indices(const BigInteger& bits) {
    std::vector<std::uint32_t> result;
    for (int i=bits.findNextSetBit(0);i>=0;i=bits.findNextSetBit(i+1)) {
        if(i>=128)throw io::AudioDeviceError("CatLive supports up to 128 physical audio channels.");
        result.push_back(unsigned(i));
    }
    return result;
}
std::optional<io::SampleFormat> exclusiveFormat(const std::wstring& id,unsigned rate) {
    auto format=io::WasapiDevice::inspect(id).mixFormat;format.sampleRate=rate;
    if(io::WasapiDevice::probeFormat(id,io::DeviceMode::exclusive,format).exact)return format;
    format.encoding=io::SampleEncoding::signedPCM;
    for(const auto bits: {std::pair<unsigned,unsigned>{32,24},{32,32},{24,24},{16,16}}) {
        format.containerBits=std::uint16_t(bits.first);format.validBits=std::uint16_t(bits.second);
        if(io::WasapiDevice::probeFormat(id,io::DeviceMode::exclusive,format).exact)return format;
    }
    return {};
}
class Device final : public AudioIODevice {
public:
    Host& owner;
    const String outputName, inputName;
    const std::wstring outputID, inputID;
    const io::DeviceMode mode;
    Device(Host& host, io::DeviceMode selectedMode, String out, String in, std::wstring outID, std::wstring inID)
        : AudioIODevice(out.isEmpty()?in:out,modeName(selectedMode)), owner(host),
          outputName(std::move(out)),inputName(std::move(in)),outputID(std::move(outID)),inputID(std::move(inID)),mode(selectedMode) {
        try { inspect(); } catch(const std::exception& error) { lastError=String::fromUTF8(error.what()); }
    }
    ~Device() override { close(); }
    StringArray getOutputChannelNames() override { return outputNames; }
    StringArray getInputChannelNames() override { return inputNames; }
    Array<double> getAvailableSampleRates() override { return rates; }
    Array<int> getAvailableBufferSizes() override { return buffers; }
    int getDefaultBufferSize() override { return defaultBuffer; }
    String open(const BigInteger& inputs,const BigInteger& outputs,double rate,int frames) override {
        close(); lastError.clear();
        try {
            io::StreamRequest request;
            request.direction=inputs.isZero()?io::Direction::render:outputs.isZero()?io::Direction::capture:io::Direction::duplex;
            request.mode=mode;request.endpointId=outputs.isZero()?inputID:outputID;
            request.sampleRate=unsigned(std::llround(rate));request.requestedBufferFrames=unsigned(std::max(0,frames));
            request.inputChannelIndices=indices(inputs);request.outputChannelIndices=indices(outputs);
            if(inputs.isZero()&&outputs.isZero())throw io::AudioDeviceError("Select an audio input or output.");
            if(mode==io::DeviceMode::loopback&&request.direction==io::Direction::render)request.mode=io::DeviceMode::shared;
            if(mode==io::DeviceMode::exclusive) {
                request.format=exclusiveFormat(request.endpointId,request.sampleRate);
                if(!request.format)throw io::AudioDeviceError("The endpoint does not support this exclusive sample rate.");
                if(request.direction==io::Direction::duplex) {
                    request.inputFormat=exclusiveFormat(inputID,request.sampleRate);
                    if(!request.inputFormat)throw io::AudioDeviceError("The input does not support this exclusive sample rate.");
                    request.inputRequestedBufferFrames=request.requestedBufferFrames;
                }
            }
            if(mode==io::DeviceMode::asio) native=std::make_unique<io::AsioDevice>();
            else if(request.direction==io::Direction::duplex) {
                native=std::make_unique<io::ClockedDuplexDevice>(std::make_unique<io::WasapiDevice>(),std::make_unique<io::WasapiDevice>());
                request.inputEndpointId=inputID;
                // Shared endpoints use their own mix rates; the prepared bridge
                // follows the output clock. Exclusive input uses the chosen rate.
                if(mode==io::DeviceMode::exclusive)request.inputSampleRate=request.sampleRate;
            } else native=std::make_unique<io::WasapiDevice>();
            native->open(request);
            activeInputs=inputs;activeOutputs=outputs;
            const auto& info=native->info();currentRate=info.sampleRate;currentBuffer=int(info.periodFrames);
            maximumBlock=info.maximumCallbackFrames;depth=info.deviceFormat.validBits?info.deviceFormat.validBits:32;
            outputLatency=int(std::ceil(info.latency100ns*currentRate/10000000.));
            inputLatency=int(std::ceil(info.inputLatency100ns*currentRate/10000000.));
            if(outputs.isZero())inputLatency=outputLatency;
            io::CallbackHub::Configuration config;
            config.sampleRate=currentRate;config.maximumBlockFrames=maximumBlock;
            // AudioEngine already expands enabled packed channels to physical
            // buses. Keep the hub's domain packed so it does not map them twice.
            config.physicalInputChannels=info.inputChannels;config.physicalOutputChannels=info.outputChannels;
            config.inputPhysicalIndices.resize(info.inputChannels);config.outputPhysicalIndices.resize(info.outputChannels);
            std::iota(config.inputPhysicalIndices.begin(),config.inputPhysicalIndices.end(),0u);
            std::iota(config.outputPhysicalIndices.begin(),config.outputPhysicalIndices.end(),0u);
            hub=std::make_unique<io::CallbackHub>(std::move(config));
            opened=true;
        } catch(const std::exception& error) { close();lastError=String::fromUTF8(error.what()); }
        return lastError;
    }
    void close() override { stop();if(native)native->close();native.reset();hub.reset();opened=false;activeInputs.clear();activeOutputs.clear(); }
    bool isOpen() override { return opened; }
    void start(AudioIODeviceCallback* callback) override {
        stop();if(!opened||!callback)return;control=callback;
        try {
            // Only lifecycle notification goes through DeviceManager. Its IO
            // callback is deliberately never called by the native audio thread.
            control->audioDeviceAboutToStart(this);
            hub->publish(owner.snapshot());
            native->start(&process,this);started=true;lastError.clear();
        }catch(const std::exception& error){lastError=String::fromUTF8(error.what());stop();}
    }
    void stop() override {
        if(native)native->stop();
        started=false;
        if(hub)hub->resetAfterStop();
        if(auto* previous=std::exchange(control,nullptr))previous->audioDeviceStopped();
        owner.load.store(0,std::memory_order_relaxed);
    }
    bool isPlaying() override { return started&&native&&native->status().state==io::DeviceState::running; }
    String getLastError() override { return lastError; }
    int getCurrentBufferSizeSamples() override { return currentBuffer; }
    double getCurrentSampleRate() override { return currentRate; }
    int getCurrentBitDepth() override { return depth; }
    BigInteger getActiveOutputChannels() const override { return activeOutputs; }
    BigInteger getActiveInputChannels() const override { return activeInputs; }
    int getOutputLatencyInSamples() override { return outputLatency; }
    int getInputLatencyInSamples() override { return inputLatency; }
    int getXRunCount() const noexcept override { return native?int(std::min<std::uint64_t>(native->status().discontinuities,INT_MAX)):0; }
    bool hasControlPanel() const override { return mode==io::DeviceMode::asio; }
    bool showControlPanel() override {
        if(auto* asio=dynamic_cast<io::AsioDevice*>(native.get())) {
            const auto inputs=activeInputs,outputs=activeOutputs;auto* previous=control;
            stop();try{
                asio->controlPanel();native->close();inspect();
                if(open(inputs,outputs,currentRate,defaultBuffer).isEmpty())start(previous);
                return lastError.isEmpty();
            }catch(const std::exception& error){lastError=String::fromUTF8(error.what());}
        }
        return false;
    }
    void publish(bool waitForAdoption) {
        if(!hub||!started)return;
        hub->collectRetired();const auto generation=hub->publish(owner.snapshot());
        if(!waitForAdoption)return;
        // Removing a client may wait only on this control thread. Never free a
        // client while an old block can still call it. A lost driver is joined.
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
        while(hub->statistics().adoptedGeneration<generation) {
            hub->collectRetired();
            if(!isPlaying()||std::chrono::steady_clock::now()>=deadline){stop();return;}
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        hub->collectRetired();
    }
    std::uint32_t service() {
        if(hub)hub->collectRetired();
        if(!native||!started)return 0;
        const auto status=native->status();
        const auto flags=native->consumeDeviceChanges();
        if(status.state==io::DeviceState::invalidated||status.state==io::DeviceState::failed||
           (flags&(io::resetRequired|io::sampleRateChanged|io::formatChanged))) {
            lastError="The audio device changed or stopped. Reopen it in Audio settings.";
            if(control)control->audioDeviceError(lastError);
            stop();owner.sendChangeMessage();
        }
        return flags;
    }
private:
    std::unique_ptr<io::AudioDevice> native;
    std::unique_ptr<io::CallbackHub> hub;
    AudioIODeviceCallback* control=nullptr;
    StringArray inputNames,outputNames;Array<double> rates;Array<int> buffers;
    BigInteger activeInputs,activeOutputs;
    String lastError;
    double currentRate=48000;
    int currentBuffer=512,defaultBuffer=512,depth=32,inputLatency=0,outputLatency=0;
    unsigned maximumBlock=0;
    bool opened=false,started=false;
    static void process(void* context,const io::AudioBlock& block) noexcept {
        auto& self=*static_cast<Device*>(context);
        const auto begin=std::chrono::steady_clock::now();
        self.hub->render(block);
        if(block.frames) {
            const double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count();
            const auto old=self.owner.load.load(std::memory_order_relaxed);
            self.owner.load.store(old*.95+.05*elapsed*block.sampleRate/block.frames,std::memory_order_relaxed);
        }
    }
    void inspect() {
        inputNames.clear();outputNames.clear();rates.clear();buffers.clear();
        if(mode==io::DeviceMode::asio) {
            io::AsioDevice probe;
            io::StreamRequest request;request.endpointId=outputID.empty()?inputID:outputID;request.mode=mode;
            // Inspect output first; input-only interfaces use capture instead.
            request.direction=outputName.isEmpty()?io::Direction::capture:io::Direction::render;
            probe.open(request);
            const auto& caps=probe.capabilities();
            for(const auto& channel:caps.inputs)inputNames.add(String::fromUTF8(channel.name.c_str()));
            for(const auto& channel:caps.outputs)outputNames.add(String::fromUTF8(channel.name.c_str()));
            currentRate=probe.info().sampleRate;currentBuffer=defaultBuffer=int(caps.preferredBufferFrames);
            for(auto rate:caps.sampleRates)rates.add(rate);
            if(rates.isEmpty())rates.add(currentRate);
            if(caps.bufferGranularity<0) {
                for(unsigned size=1;size<=caps.maximumBufferFrames&&size<=65536;size*=2)if(size>=caps.minimumBufferFrames)buffers.add(int(size));
            }else if(caps.bufferGranularity>0) {
                for(unsigned size=caps.minimumBufferFrames;size<=caps.maximumBufferFrames&&size<=65536;size+=unsigned(caps.bufferGranularity))buffers.add(int(size));
            }
            buffers.addIfNotAlreadyThere(defaultBuffer);probe.close();return;
        }
        std::optional<io::WasapiCapabilities> output,input;
        if(outputName.isNotEmpty())output=io::WasapiDevice::inspect(outputID);
        if(inputName.isNotEmpty())input=io::WasapiDevice::inspect(inputID);
        if(!output&&!input)throw io::AudioDeviceError("No audio endpoint selected");
        if(output)for(unsigned i=0;i<output->mixFormat.channels;++i)outputNames.add("Output "+String(i+1));
        if(input)for(unsigned i=0;i<input->mixFormat.channels;++i)inputNames.add("Input "+String(i+1));
        const auto& caps=output?*output:*input;currentRate=caps.mixFormat.sampleRate;
        defaultBuffer=std::max(1,int(std::llround(caps.defaultPeriod100ns*currentRate/10000000.)));currentBuffer=defaultBuffer;
        rates.add(currentRate);
        if(mode==io::DeviceMode::exclusive) {
            for(double rate:{44100.,48000.,88200.,96000.,176400.,192000.}) {
                if(exclusiveFormat(caps.endpoint.id,unsigned(rate)))rates.addIfNotAlreadyThere(rate);
            }
            for(int frames:{64,128,256,512,1024,2048}) {
                if(frames*10000000./currentRate>=caps.minimumPeriod100ns)buffers.add(frames);
            }
        }else if(mode==io::DeviceMode::sharedLowLatency&&caps.sharedLowLatency) {
            const auto step=caps.fundamentalSharedPeriodFrames;
            if(step)for(unsigned frames=caps.minimumSharedPeriodFrames;frames<=caps.maximumSharedPeriodFrames&&frames<=65536;frames+=step)buffers.add(int(frames));
            defaultBuffer=int(caps.defaultSharedPeriodFrames);currentBuffer=defaultBuffer;
        }
        buffers.addIfNotAlreadyThere(defaultBuffer);
    }
};
class Type final : public AudioIODeviceType {
public:
    Type(Host& h,io::DeviceMode m):AudioIODeviceType(modeName(m)),host(h),mode(m){}
    void scanForDevices() override {
        outputs.clear();inputs.clear();outIDs.clear();inIDs.clear();defaultIn=defaultOut=-1;
        if(mode==io::DeviceMode::asio) {
            for(const auto& driver:io::AsioDevice::enumerate()){
                outputs.add(String(driver.name.c_str()));inputs.add(String(driver.name.c_str()));outIDs.push_back(driver.id);inIDs.push_back(driver.id);
            }
        }else for(const auto& endpoint:io::WasapiDevice::enumerate()) {
            if(endpoint.direction==io::Direction::render) {
                if(endpoint.defaultMultimedia)defaultOut=outputs.size();
                outputs.add(String(endpoint.name.c_str()));outIDs.push_back(endpoint.id);
                if(mode==io::DeviceMode::loopback){if(endpoint.defaultMultimedia)defaultIn=inputs.size();inputs.add(String(endpoint.name.c_str()));inIDs.push_back(endpoint.id);}
            }else if(mode!=io::DeviceMode::loopback) {
                if(endpoint.defaultMultimedia)defaultIn=inputs.size();
                inputs.add(String(endpoint.name.c_str()));inIDs.push_back(endpoint.id);
            }
        }
        outputs.appendNumbersToDuplicates(false,false);inputs.appendNumbersToDuplicates(false,false);
    }
    StringArray getDeviceNames(bool input) const override { return input?inputs:outputs; }
    int getDefaultDeviceIndex(bool input) const override { return std::max(0,input?defaultIn:defaultOut); }
    int getIndexOfDevice(AudioIODevice* value,bool input) const override {
        if(auto* device=dynamic_cast<Device*>(value))return (input?inputs:outputs).indexOf(input?device->inputName:device->outputName);
        return -1;
    }
    bool hasSeparateInputsAndOutputs() const override { return mode!=io::DeviceMode::asio; }
    AudioIODevice* createDevice(const String& out,const String& in) override {
        const int o=outputs.indexOf(out),i=inputs.indexOf(in);
        if((out.isNotEmpty()&&o<0)||(in.isNotEmpty()&&i<0))return nullptr;
        return new Device(host,mode,out,in,o<0?std::wstring{}:outIDs[size_t(o)],i<0?std::wstring{}:inIDs[size_t(i)]);
    }
private:
    Host& host;io::DeviceMode mode;StringArray outputs,inputs;
    std::vector<std::wstring> outIDs,inIDs;int defaultIn=-1,defaultOut=-1;
};
void Host::createAudioDeviceTypes(OwnedArray<AudioIODeviceType>& types) {
    startTimerHz(30);
    for(auto mode:{io::DeviceMode::shared,io::DeviceMode::exclusive,io::DeviceMode::sharedLowLatency,io::DeviceMode::loopback,io::DeviceMode::asio})types.add(new Type(*this,mode));
}
void Host::add(AudioIODeviceCallback* callback) {
    if(!callback||std::any_of(clients.begin(),clients.end(),[&](const auto& c){return c->callback==callback;}))return;
    auto client=std::make_shared<Client>(Client{callback,nextID++,&clientFailed});
    // Reserve control storage before registering a callback with the manager.
    clients.reserve(clients.size()+1);
    AudioDeviceManager::addAudioCallback(callback);clients.push_back(std::move(client));
    if(auto* device=dynamic_cast<Device*>(getCurrentAudioDevice())) {
        try { device->publish(false); }
        catch (...) { device->stop();clients.pop_back();AudioDeviceManager::removeAudioCallback(callback);throw; }
    }
}
void Host::remove(AudioIODeviceCallback* callback) {
    const auto found=std::find_if(clients.begin(),clients.end(),[&](const auto& c){return c->callback==callback;});
    if(found==clients.end())return;
    const auto hold=*found;clients.erase(found);
    if(auto* device=dynamic_cast<Device*>(getCurrentAudioDevice())) {
        try { device->publish(true); } catch (...) { device->stop(); }
    }
    AudioDeviceManager::removeAudioCallback(callback);
}
void Host::timerCallback() {
    if(auto* device=dynamic_cast<Device*>(getCurrentAudioDevice())) {
        if(clientFailed.exchange(false,std::memory_order_acq_rel))device->stop();
        const auto flags=device->service();
        if(flags&(io::devicesChanged|io::defaultDeviceChanged)) {
            if(auto* type=getCurrentDeviceTypeObject())type->scanForDevices();
            // Existing SystemAudioDefaults applies the user's follow policy
            // and shared recording guards on the message thread.
            sendChangeMessage();
        }
    }
}
}
std::shared_ptr<juce::AudioDeviceManager> makeAudioDeviceHost(){return std::make_shared<Host>();}
void addRealtimeAudioCallback(juce::AudioDeviceManager& manager,juce::AudioIODeviceCallback* callback){
    if(auto* host=dynamic_cast<Host*>(&manager))host->add(callback);else manager.addAudioCallback(callback);
}
void removeRealtimeAudioCallback(juce::AudioDeviceManager& manager,juce::AudioIODeviceCallback* callback){
    if(auto* host=dynamic_cast<Host*>(&manager))host->remove(callback);else manager.removeAudioCallback(callback);
}
double audioDeviceCpuUsage(const juce::AudioDeviceManager& manager){
    if(const auto* host=dynamic_cast<const Host*>(&manager))return host->cpu();return manager.getCpuUsage();
}
bool usesNativeAudioDeviceHost(const juce::AudioDeviceManager& manager) noexcept{return dynamic_cast<const Host*>(&manager)!=nullptr;}
}
#else
namespace catlive {
std::shared_ptr<juce::AudioDeviceManager> makeAudioDeviceHost(){return std::make_shared<juce::AudioDeviceManager>();}
void addRealtimeAudioCallback(juce::AudioDeviceManager& manager,juce::AudioIODeviceCallback* callback){manager.addAudioCallback(callback);}
void removeRealtimeAudioCallback(juce::AudioDeviceManager& manager,juce::AudioIODeviceCallback* callback){manager.removeAudioCallback(callback);}
double audioDeviceCpuUsage(const juce::AudioDeviceManager& manager){return manager.getCpuUsage();}
bool usesNativeAudioDeviceHost(const juce::AudioDeviceManager&) noexcept{return false;}
}
#endif
