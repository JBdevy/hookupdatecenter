#include "VST3Host.h"
#include <windows.h>
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ustring.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstattributes.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "pluginterfaces/gui/iplugview.h"
#include <atomic>
#include <array>
#include <vector>
#include <memory>
#include <map>
#include <mutex>
#include <condition_variable>
#include <algorithm>
#include <cstring>
#include <cmath>
#include <stdexcept>
#include <cctype>
using namespace Steinberg;
using namespace Steinberg::Vst;
namespace Steinberg {
DEF_CLASS_IID(IPlugView) DEF_CLASS_IID(IPlugFrame)
namespace Vst {
DEF_CLASS_IID(IComponent) DEF_CLASS_IID(IAudioProcessor) DEF_CLASS_IID(IEditController)
DEF_CLASS_IID(IHostApplication) DEF_CLASS_IID(IComponentHandler) DEF_CLASS_IID(IComponentHandler2) DEF_CLASS_IID(IConnectionPoint)
DEF_CLASS_IID(IMessage) DEF_CLASS_IID(IAttributeList) DEF_CLASS_IID(IParameterChanges) DEF_CLASS_IID(IParamValueQueue)
DEF_CLASS_IID(IEventList) DEF_CLASS_IID(IMidiMapping)
}}
namespace catlive::native::vst3 {
namespace {
template<class T> bool iidIs(const TUID id) { return FUnknownPrivate::iidEqual(id,T::iid); }
template<> bool iidIs<FUnknown>(const TUID id) { return FUnknownPrivate::iidEqual(id,FUnknown_iid); }
template<> bool iidIs<IBStream>(const TUID id) { return FUnknownPrivate::iidEqual(id,IBStream_iid); }
template<class T> T *query(FUnknown *object) { T *result=nullptr; if(object) object->queryInterface(T::iid,(void **)&result); return result; }
// The scanner enters before global FUID constructors run. Factory interface
// identifiers must therefore use their constant bytes in that early process.
template<> IPluginFactory2 *query<IPluginFactory2>(FUnknown *object) {
    IPluginFactory2 *result = nullptr;
    if (object) object->queryInterface(IPluginFactory2_iid, (void **)&result);
    return result;
}
template<> IPluginFactory3 *query<IPluginFactory3>(FUnknown *object) {
    IPluginFactory3 *result = nullptr;
    if (object) object->queryInterface(IPluginFactory3_iid, (void **)&result);
    return result;
}
#define FIXED_REF uint32 PLUGIN_API addRef() override { return 1; } uint32 PLUGIN_API release() override { return 1; }
std::string utf8(const TChar *value) {
    const auto count = WideCharToMultiByte(CP_UTF8, 0, reinterpret_cast<const wchar_t *>(value), -1, nullptr, 0, nullptr, nullptr);
    if (count <= 1) return {};
    std::string result(size_t(count), '\0');
    WideCharToMultiByte(CP_UTF8, 0, reinterpret_cast<const wchar_t *>(value), -1, result.data(), count, nullptr, nullptr);
    result.pop_back(); return result;
}
class Attributes final: public IAttributeList {
    std::atomic<uint32> refs{1}; std::map<std::string,int64> ints; std::map<std::string,double> floats;
    std::map<std::string,std::u16string> strings; std::map<std::string,std::vector<uint8>> binaries;
public:
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override { *out=nullptr; if(iidIs<FUnknown>(id)||iidIs<IAttributeList>(id)) { *out=this;addRef();return kResultOk; } return kNoInterface; }
    uint32 PLUGIN_API addRef() override { return ++refs; } uint32 PLUGIN_API release() override { auto n=--refs; if(!n) delete this; return n; }
    tresult PLUGIN_API setInt(AttrID id,int64 v) override { ints[id]=v;return kResultOk; }
    tresult PLUGIN_API getInt(AttrID id,int64 &v) override { auto i=ints.find(id);if(i==ints.end())return kResultFalse;v=i->second;return kResultOk; }
    tresult PLUGIN_API setFloat(AttrID id,double v) override { floats[id]=v;return kResultOk; }
    tresult PLUGIN_API getFloat(AttrID id,double &v) override { auto i=floats.find(id);if(i==floats.end())return kResultFalse;v=i->second;return kResultOk; }
    tresult PLUGIN_API setString(AttrID id,const TChar *v) override { strings[id]=(const char16_t *)v;return kResultOk; }
    tresult PLUGIN_API getString(AttrID id,TChar *v,uint32 bytes) override { auto i=strings.find(id);if(i==strings.end()||bytes<2)return kResultFalse; auto n=std::min<size_t>(bytes/2-1,i->second.size());memcpy(v,i->second.data(),n*2);v[n]=0;return kResultOk; }
    tresult PLUGIN_API setBinary(AttrID id,const void *v,uint32 n) override { binaries[id]=std::vector<uint8>((const uint8 *)v,(const uint8 *)v+n);return kResultOk; }
    tresult PLUGIN_API getBinary(AttrID id,const void *&v,uint32 &n) override { auto i=binaries.find(id);if(i==binaries.end())return kResultFalse;v=i->second.data();n=(uint32)i->second.size();return kResultOk; }
};
class Message final: public IMessage {
    std::atomic<uint32> refs{1}; std::string name; Attributes *attributes=new Attributes;
public:
    ~Message() { attributes->release(); }
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override { *out=nullptr;if(iidIs<FUnknown>(id)||iidIs<IMessage>(id)){*out=this;addRef();return kResultOk;}return kNoInterface; }
    uint32 PLUGIN_API addRef() override { return ++refs; } uint32 PLUGIN_API release() override { auto n=--refs;if(!n)delete this;return n; }
    FIDString PLUGIN_API getMessageID() override { return name.c_str(); }
    void PLUGIN_API setMessageID(FIDString id) override { name=id?id:""; }
    IAttributeList *PLUGIN_API getAttributes() override { return attributes; }
};
class Host final: public IHostApplication {
public:
    FIXED_REF
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override { *out=nullptr;if(iidIs<FUnknown>(id)||iidIs<IHostApplication>(id)){*out=this;return kResultOk;}return kNoInterface; }
    tresult PLUGIN_API getName(String128 name) override { UString(name,128).fromAscii("CatLive");return kResultOk; }
    tresult PLUGIN_API createInstance(TUID cid,TUID iid,void **out) override {
        *out=nullptr;
        if(iidIs<IMessage>(cid)&&iidIs<IMessage>(iid)) *out=new Message;
        else if(iidIs<IAttributeList>(cid)&&iidIs<IAttributeList>(iid)) *out=new Attributes;
        return *out?kResultOk:kNoInterface;
    }
};
class Stream final: public IBStream {
public:
    static constexpr int64 maximumSize=256*1024*1024;
    std::vector<uint8> bytes; int64 position=0; FIXED_REF
    Stream()=default;
    explicit Stream(const std::vector<std::uint8_t> &data): bytes(data) {
        if(data.size()>maximumSize)throw std::runtime_error("VST3 state exceeds the supported size.");
    }
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override { *out=nullptr;if(iidIs<FUnknown>(id)||iidIs<IBStream>(id)){*out=this;return kResultOk;}return kNoInterface; }
    tresult PLUGIN_API read(void *data,int32 n,int32 *count) override {
        if(count)*count=0;
        if(n<0||(!data&&n)||position<0||position>maximumSize)return kInvalidArgument;
        const auto available=position<int64(bytes.size())?int64(bytes.size())-position:0;
        const auto size=std::min<int64>(n,available);
        if(size)memcpy(data,bytes.data()+position,size);
        position+=size;if(count)*count=int32(size);
        return size==n?kResultOk:kResultFalse;
    }
    tresult PLUGIN_API write(void *data,int32 n,int32 *count) override {
        if(count)*count=0;
        if(n<0||(!data&&n)||position<0||position>maximumSize||n>maximumSize-position)return kInvalidArgument;
        if(position+n>int64(bytes.size()))bytes.resize(position+n);
        if(n)memcpy(bytes.data()+position,data,n);
        position+=n;if(count)*count=n;return kResultOk;
    }
    tresult PLUGIN_API seek(int64 offset,int32 mode,int64 *result) override {
        int64 base=0;
        switch(mode){case kIBSeekSet:break;case kIBSeekCur:base=position;break;case kIBSeekEnd:base=int64(bytes.size());break;default:return kInvalidArgument;}
        // Check before addition: a malformed plugin state can request an
        // extreme relative offset, which must not overflow signed int64.
        if(base<0||base>maximumSize||offset < -base||offset>maximumSize-base)return kInvalidArgument;
        position=base+offset;if(result)*result=position;return kResultOk;
    }
    tresult PLUGIN_API tell(int64 *p) override { if(!p)return kInvalidArgument;*p=position;return kResultOk; }
};
struct Module {
    HMODULE library = nullptr;
    IPluginFactory *factory = nullptr;
    bool entered = false;
    explicit Module(const std::filesystem::path &path) { try {
        auto binary = path;
        if (std::filesystem::is_directory(path))
            binary = path / L"Contents" / L"x86_64-win" / path.filename();
        if (!binary.is_absolute() || !std::filesystem::is_regular_file(binary))
            throw std::runtime_error("The VST3 Windows x64 module was not found.");
        library = LoadLibraryExW(binary.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!library) throw std::runtime_error("Could not load this Windows x64 VST3 module.");
        auto entry = reinterpret_cast<bool (*)()>(GetProcAddress(library, "InitDll"));
        if (entry) { if (!entry()) throw std::runtime_error("VST3 module initialization failed."); entered = true; }
        auto get = reinterpret_cast<IPluginFactory *(*)()>(GetProcAddress(library, "GetPluginFactory"));
        if (!get || !(factory = get())) throw std::runtime_error("The module has no VST3 factory.");
        static Host host;
        if (auto f3 = query<IPluginFactory3>(factory)) { f3->setHostContext(&host); f3->release(); }
    } catch (...) { close(); throw; } }
    ~Module() { close(); }
    void close() {
        if (factory) factory->release();
        if (library) {
            if (entered) if (auto exit = reinterpret_cast<bool (*)()>(GetProcAddress(library, "ExitDll"))) exit();
            FreeLibrary(library);
        }
    }
};
struct ModuleSlot {
    std::weak_ptr<Module> owner;
    std::atomic<bool> loaded{false};
};
struct ModuleRegistry {
    std::mutex mutex;
    std::condition_variable released;
    std::map<std::string,std::shared_ptr<ModuleSlot>> slots;
};
std::shared_ptr<Module> loadModule(const std::filesystem::path &path) {
    // The registry also belongs to each deleter, so process teardown cannot
    // destroy its mutex before the final editor/processor releases a bundle.
    static const auto registry=std::make_shared<ModuleRegistry>();
    const auto canonical=std::filesystem::weakly_canonical(path);
    std::unique_lock<std::mutex> lock(registry->mutex);auto key=canonical.u8string();
    std::transform(key.begin(), key.end(), key.begin(), [](unsigned char c){return char(std::tolower(c));});
    auto &entry=registry->slots[key];if(!entry)entry=std::make_shared<ModuleSlot>();
    const auto slot=entry;
    for(;;){
        if(auto existing=slot->owner.lock())return existing;
        if(!slot->loaded)break;
        // A weak_ptr expires before its destructor finishes. A new instance
        // must wait for bundleExit/unload, otherwise that old unload can tear
        // down the executable and factory of the new processor.
        registry->released.wait(lock);
    }
    const auto lifetime=registry;
    auto loaded=std::shared_ptr<Module>(new Module(canonical),[lifetime,slot](Module *module){
        // shared_ptr invokes its deleter if allocating the control block
        // fails, before publication and while the caller still owns the lock.
        if(!slot->loaded.load()){delete module;return;}
        // Keep this slot occupied but allow other modules to load/unload
        // while plugin-owned teardown code runs.
        delete module;
        std::lock_guard<std::mutex> lock(lifetime->mutex);
        slot->owner.reset();
        slot->loaded=false;
        lifetime->released.notify_all();
    });
    slot->owner=loaded;slot->loaded=true;return loaded;
}
struct Param { ParamID id=0; std::atomic<double> pending{0}; std::atomic<bool> dirty{false}; };
struct ParameterPoint {int32 offset=0,next=-1;double value=0;};
struct ParameterPointPool {
    std::unique_ptr<ParameterPoint[]> points;
    int capacity=0,used=0;
};
class Queue final: public IParamValueQueue {
public:
    ParamID id=0;ParameterPointPool *pool=nullptr;int first=-1,last=-1,count=0;FIXED_REF
    void clear(){first=last=-1;count=0;}
    tresult PLUGIN_API queryInterface(const TUID uid,void **out) override {*out=nullptr;if(iidIs<FUnknown>(uid)||iidIs<IParamValueQueue>(uid)){*out=this;return kResultOk;}return kNoInterface;}
    ParamID PLUGIN_API getParameterId() override {return id;}
    int32 PLUGIN_API getPointCount() override {return count;}
    tresult PLUGIN_API getPoint(int32 index,int32 &offset,ParamValue &value) override {
        if(index<0||index>=count||!pool)return kInvalidArgument;
        int current=first;for(int i=0;i<index;++i)current=pool->points[current].next;
        const auto &point=pool->points[current];offset=point.offset;value=point.value;return kResultOk;
    }
    tresult PLUGIN_API addPoint(int32 offset,ParamValue value,int32 &index) override {
        index=-1;
        if(!pool||offset<0||!std::isfinite(value))return kInvalidArgument;
        if(last>=0&&offset<pool->points[last].offset)return kInvalidArgument;
        if(last>=0&&offset==pool->points[last].offset){pool->points[last].value=value;index=count-1;return kResultOk;}
        if(pool->used>=pool->capacity)return kResultFalse;
        const int next=pool->used++;pool->points[next]={offset,-1,value};
        if(last>=0)pool->points[last].next=next;else first=next;
        last=next;index=count++;return kResultOk;
    }
};
class Changes final: public IParameterChanges {
public:
    std::unique_ptr<Queue[]> queues;ParameterPointPool pool;int32 capacity=0,count=0;FIXED_REF
    void prepare(int parameterCount){
        capacity=parameterCount+2048;queues=std::make_unique<Queue[]>(capacity);
        pool.capacity=parameterCount+18432;pool.points=std::make_unique<ParameterPoint[]>(pool.capacity);
        for(int i=0;i<capacity;++i)queues[i].pool=&pool;
    }
    void clear(){count=0;pool.used=0;}
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override {*out=nullptr;if(iidIs<FUnknown>(id)||iidIs<IParameterChanges>(id)){*out=this;return kResultOk;}return kNoInterface;}
    int32 PLUGIN_API getParameterCount() override {return count;}
    IParamValueQueue *PLUGIN_API getParameterData(int32 index) override {return index>=0&&index<count?&queues[index]:nullptr;}
    IParamValueQueue *PLUGIN_API addParameterData(const ParamID &id,int32 &index) override {
        for(int i=0;i<count;++i)if(queues[i].id==id){index=i;return &queues[i];}
        if(count==capacity){index=-1;return nullptr;}
        index=count++;queues[index].id=id;queues[index].clear();return &queues[index];
    }
};
class EventList final: public IEventList {
public:
    Event events[18432];int count=0;FIXED_REF
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override {*out=nullptr;if(iidIs<FUnknown>(id)||iidIs<IEventList>(id)){*out=this;return kResultOk;}return kNoInterface;}
    int32 PLUGIN_API getEventCount() override{return count;}
    tresult PLUGIN_API getEvent(int32 index,Event &event) override{if(index<0||index>=count)return kInvalidArgument;event=events[index];return kResultOk;}
    tresult PLUGIN_API addEvent(Event &event) override{if(count==18432)return kResultFalse;events[count++]=event;return kResultOk;}
};

} // namespace
struct Processor::Impl final: IComponentHandler, IComponentHandler2 {
    std::shared_ptr<Module> module;
    Host host;
    IComponent *component=nullptr;
    IAudioProcessor *processor=nullptr;
    IEditController *controller=nullptr;
    IConnectionPoint *source=nullptr,*destination=nullptr;
    bool initialized=false,controllerInitialized=false,active=false,processing=false,instrument=false;
    std::unique_ptr<Param[]> params;
    int paramCount=0, mainIn=-1, mainOut=-1, maximumFrames=4096;
    double rate=48000;
    Changes changes;
    EventList events;
    ParamID midiParameters[16][130];
    std::vector<AudioBusBuffers> inputs,outputs;
    std::vector<std::vector<float>> storage;
    std::vector<std::vector<float *>> pointers;
    std::atomic<bool> edited{false},parametersChanged{false};
    std::atomic<unsigned> latencySamples{0};
    std::atomic<int32> restartFlags{0};
    FIXED_REF
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override {
        if (!out) return kInvalidArgument;
        *out=nullptr;
        if(iidIs<FUnknown>(id)||iidIs<IComponentHandler>(id))*out=static_cast<IComponentHandler*>(this);
        else if(iidIs<IComponentHandler2>(id))*out=static_cast<IComponentHandler2*>(this);
        return *out?kResultOk:kNoInterface;
    }
    tresult PLUGIN_API setDirty(TBool value) override { if(value)edited=true;return kResultOk; }
    tresult PLUGIN_API requestOpenEditor(FIDString) override {return kResultFalse;}
    tresult PLUGIN_API startGroupEdit() override {return kResultOk;}
    tresult PLUGIN_API finishGroupEdit() override {edited=true;return kResultOk;}
    tresult PLUGIN_API beginEdit(ParamID) override {return kResultOk;}
    tresult PLUGIN_API performEdit(ParamID id,ParamValue value) override {
        if(!std::isfinite(value))return kInvalidArgument;
        for(int i=0;i<paramCount;++i)if(params[i].id==id){
            params[i].pending=std::clamp(value,0.,1.);
            params[i].dirty.store(true,std::memory_order_release);
            parametersChanged.store(true,std::memory_order_release);
            return kResultOk;
        }
        return kInvalidArgument;
    }
    tresult PLUGIN_API endEdit(ParamID) override {edited=true;return kResultOk;}
    tresult PLUGIN_API restartComponent(int32 flags) override {
        restartFlags.fetch_or(flags);
        // The caller observes edited on the UI thread. Audio callbacks never
        // rebuild a processor in response to a plug-in restart request.
        edited=true;
        return kResultOk;
    }
    Impl(const Description &description,const State &state,double sampleRate,int maxFrames)
        : maximumFrames(maxFrames),rate(sampleRate) {try {
        if(!std::isfinite(rate)||rate<8000||rate>384000||maxFrames<1||maxFrames>32768)
            throw std::runtime_error("Invalid VST3 audio format.");
        instrument=description.category.find("Instrument")!=std::string::npos;
        module=loadModule(description.path);
        FUID uid;
        if(!uid.fromString(description.classID.c_str())||module->factory->createInstance(uid,IComponent::iid,(void **)&component)!=kResultOk||!component)
            throw std::runtime_error("Could not create this VST3 processor.");
        if(component->initialize(&host)!=kResultOk)throw std::runtime_error("VST3 processor initialization failed.");
        initialized=true;
        processor=query<IAudioProcessor>(component);
        if(!processor||processor->canProcessSampleSize(kSample32)!=kResultOk)
            throw std::runtime_error("This VST3 processor does not support 32-bit audio.");
        controller=query<IEditController>(component);
        if(!controller){
            TUID cid{};
            if(component->getControllerClassId(cid)==kResultOk && module->factory->createInstance(cid,IEditController::iid,(void **)&controller)==kResultOk && controller){
                if(controller->initialize(&host)!=kResultOk)throw std::runtime_error("VST3 controller initialization failed.");
                controllerInitialized=true;
            }
        }
        if(controller){
            controller->setComponentHandler(this);
            source=query<IConnectionPoint>(component);destination=query<IConnectionPoint>(controller);
            if(source&&destination){source->connect(destination);destination->connect(source);}
        }
        if(!state.component.empty()){
            Stream stream(state.component);
            if(component->setState(&stream)!=kResultOk)throw std::runtime_error("The VST3 processor rejected its saved state.");
        }
        if(controller){
            Stream stream;
            if(component->getState(&stream)==kResultOk){stream.position=0;controller->setComponentState(&stream);}
            if(!state.controller.empty()){
                Stream saved(state.controller);
                if(controller->setState(&saved)!=kResultOk)throw std::runtime_error("The VST3 controller rejected its saved state.");
            }
        }
        for(int b=0;b<component->getBusCount(kEvent,kInput);++b)component->activateBus(kEvent,kInput,b,b==0);
        for(auto &channel:midiParameters)std::fill(std::begin(channel),std::end(channel),kNoParamId);
        if(auto mapping=query<IMidiMapping>(controller)){
            for(int c=0;c<16;++c)for(int cc=0;cc<130;++cc)mapping->getMidiControllerAssignment(0,c,cc,midiParameters[c][cc]);
            mapping->release();
        }
        const int inCount=component->getBusCount(kAudio,kInput),outCount=component->getBusCount(kAudio,kOutput);
        if(inCount<0||inCount>64||outCount<1||outCount>64)throw std::runtime_error("Unsupported VST3 audio bus layout.");
        std::vector<SpeakerArrangement> in(inCount),out(outCount);
        for(int dir=0;dir<2;++dir){
            auto &arr=dir?out:in;
            for(int i=0;i<int(arr.size());++i){
                BusInfo info{};component->getBusInfo(kAudio,dir?kOutput:kInput,i,info);
                processor->getBusArrangement(dir?kOutput:kInput,i,arr[i]);
                if(info.busType==kMain&&(dir?mainOut:mainIn)==-1){(dir?mainOut:mainIn)=i;arr[i]=SpeakerArr::kStereo;}
            }
        }
        if(mainOut<0||processor->setBusArrangements(in.data(),inCount,out.data(),outCount)!=kResultOk)
            throw std::runtime_error("This VST3 processor does not support a stereo output.");
        inputs.resize(inCount);outputs.resize(outCount);pointers.resize(inCount+outCount);
        for(int dir=0;dir<2;++dir){
            auto &buses=dir?outputs:inputs;
            for(int i=0;i<int(buses.size());++i){
                BusInfo info{};component->getBusInfo(kAudio,dir?kOutput:kInput,i,info);
                if(info.channelCount<0||info.channelCount>64||(dir&&i==mainOut&&info.channelCount<1))throw std::runtime_error("Unsupported VST3 bus width.");
                auto &p=pointers[(dir?inCount:0)+i];p.resize(info.channelCount);
                for(int c=0;c<info.channelCount;++c){storage.emplace_back(maxFrames,0);p[c]=storage.back().data();}
                buses[i].numChannels=info.channelCount;buses[i].channelBuffers32=p.data();
                component->activateBus(kAudio,dir?kOutput:kInput,i,i==(dir?mainOut:mainIn));
            }
        }
        if(controller){
            paramCount=std::clamp(controller->getParameterCount(),0,65536);
            params=std::make_unique<Param[]>(paramCount);changes.prepare(paramCount);
            for(int i=0;i<paramCount;++i){
                ParameterInfo p{};controller->getParameterInfo(i,p);params[i].id=p.id;
                params[i].pending=controller->getParamNormalized(p.id);params[i].dirty=true;
            }
            parametersChanged=paramCount>0;
        }
        ProcessSetup setup{kRealtime,kSample32,maxFrames,rate};
        if(processor->setupProcessing(setup)!=kResultOk)throw std::runtime_error("VST3 audio setup failed.");
        if(component->setActive(true)!=kResultOk)throw std::runtime_error("Could not activate this VST3 processor.");active=true;
        if(processor->setProcessing(true)!=kResultOk)throw std::runtime_error("Could not start this VST3 processor.");processing=true;
        latencySamples=processor->getLatencySamples();
    }catch(...){close();throw;}}
    ~Impl(){close();}
    void close(){
        if(processing)processor->setProcessing(false);
        if(active)component->setActive(false);
        if(source&&destination){source->disconnect(destination);destination->disconnect(source);}
        if(source)source->release();if(destination)destination->release();
        if(controller){controller->setComponentHandler(nullptr);if(controllerInitialized)controller->terminate();controller->release();}
        if(processor)processor->release();if(component){if(initialized)component->terminate();component->release();}
    }
    bool render(float *left,float *right,int count,const Transport &transport,const MIDIEvent *midi,int midiCount) {
        if(!left||!right||count<0||count>maximumFrames||midiCount<0||midiCount>18432||(!midi&&midiCount))return false;
        for(unsigned index=0;index<inputs.size();++index){
            auto &input=inputs[index];input.silenceFlags=0;
            for(int c=0;c<input.numChannels;++c){
                auto destination=input.channelBuffers32[c];
                const float *original=int(index)==mainIn&&c<2?(c?right:left):nullptr;
                bool silent=true;
                if(original){std::copy_n(original,count,destination);for(int f=0;f<count;++f)if(original[f]!=0){silent=false;break;}}
                else std::fill_n(destination,count,0.f);
                if(silent)input.silenceFlags|=uint64(1)<<c;
            }
        }
        for(auto &bus:outputs){bus.silenceFlags=0;for(int c=0;c<bus.numChannels;++c)std::fill_n(bus.channelBuffers32[c],count,0.f);}
        changes.clear();
        if(parametersChanged.exchange(false,std::memory_order_acq_rel))for(int i=0;i<paramCount;++i)if(params[i].dirty.exchange(false,std::memory_order_acq_rel)){
            int32 index;auto q=changes.addParameterData(params[i].id,index);if(q)q->addPoint(0,params[i].pending.load(),index);
        }
        events.count=0;
        for(int i=0;i<midiCount;++i){
            const auto &message=midi[i];
            if(message.offset<0||message.offset>=count)continue;
            const int kind=message.status&0xf0,channel=message.status&15;
            if(kind==0xb0||kind==0xe0){
                const int cc=kind==0xe0?129:message.data1;
                if(cc<130&&midiParameters[channel][cc]!=kNoParamId){
                    int32 index;auto q=changes.addParameterData(midiParameters[channel][cc],index);
                    if(q)q->addPoint(message.offset,kind==0xe0?double(message.data1|(message.data2<<7))/16383.:message.data2/127.,index);
                }
                continue;
            }
            if(kind!=0x90&&kind!=0x80)continue;
            Event event{};event.sampleOffset=message.offset;
            const bool on=kind==0x90&&message.data2>0;
            event.type=on?Event::kNoteOnEvent:Event::kNoteOffEvent;
            if(on){event.noteOn.channel=int16(channel);event.noteOn.pitch=message.data1;event.noteOn.velocity=message.data2/127.f;event.noteOn.noteId=-1;}
            else{event.noteOff.channel=int16(channel);event.noteOff.pitch=message.data1;event.noteOff.velocity=message.data2/127.f;event.noteOff.noteId=-1;}
            events.addEvent(event);
        }
        ProcessContext context{};
        context.sampleRate=rate;context.projectTimeSamples=int64(std::llround(transport.seconds*rate));
        context.projectTimeMusic=transport.quarterNotes;context.tempo=transport.tempo;
        context.timeSigNumerator=transport.numerator;context.timeSigDenominator=transport.denominator;
        context.state=ProcessContext::kTempoValid|ProcessContext::kTimeSigValid|ProcessContext::kProjectTimeMusicValid|(transport.playing?ProcessContext::kPlaying:0);
        ProcessData data{};data.processMode=kRealtime;data.symbolicSampleSize=kSample32;data.numSamples=count;
        data.numInputs=int(inputs.size());data.numOutputs=int(outputs.size());data.inputs=inputs.data();data.outputs=outputs.data();
        data.inputParameterChanges=&changes;data.inputEvents=&events;data.processContext=&context;
        if(processor->process(data)!=kResultOk)return false;
        auto &output=outputs[mainOut];
        for(int c=0;c<2;++c){
            float *destination=c?right:left;int channel=std::min(c,output.numChannels-1);
            const bool silent=(output.silenceFlags&(uint64(1)<<channel))!=0;
            const float *result=output.channelBuffers32[channel];
            for(int f=0;f<count;++f){const float value=silent||!std::isfinite(result[f])?0.f:result[f];destination[f]=(instrument?destination[f]:0.f)+value;}
        }
        return true;
    }
};
Processor::Processor(const Description &d,const State &s,double rate,int frames):impl(std::make_unique<Impl>(d,s,rate,frames)){}
Processor::~Processor()=default;
bool Processor::process(float *l,float *r,int n,const Transport &t,const MIDIEvent *events,int count)noexcept {
    try{return impl->render(l,r,n,t,events,count);}catch(...){return false;}
}
State Processor::state()const {
    Stream component,controller;
    if(impl->component->getState(&component)!=kResultOk)throw std::runtime_error("VST3 could not save its processor state.");
    if(impl->controller&&impl->controller->getState(&controller)!=kResultOk)throw std::runtime_error("VST3 could not save its controller state.");
    return {std::move(component.bytes),std::move(controller.bytes)};
}
bool Processor::consumeEdited()noexcept {
    const auto flags=impl->restartFlags.exchange(0);
    if(flags&kLatencyChanged)impl->latencySamples=impl->processor->getLatencySamples();
    if(flags&kParamValuesChanged)if(impl->controller)for(int i=0;i<impl->paramCount;++i)
        impl->performEdit(impl->params[i].id,impl->controller->getParamNormalized(impl->params[i].id));
    return impl->edited.exchange(false);
}
unsigned Processor::latency()const noexcept{return impl->latencySamples.load();}
bool Processor::isInstrument()const noexcept{return impl->instrument;}

struct Editor::Impl final: IPlugFrame {
    IPlugView *view=nullptr;
    std::function<void(int,int)> resizeOwner;
    int w=0,h=0;bool attached=false,resizing=false;
    FIXED_REF
    tresult PLUGIN_API queryInterface(const TUID id,void **out)override{
        if(!out)return kInvalidArgument;*out=nullptr;
        if(iidIs<FUnknown>(id)||iidIs<IPlugFrame>(id)){*out=this;return kResultOk;}return kNoInterface;
    }
    tresult PLUGIN_API resizeView(IPlugView *request,ViewRect *rect)override{
        if(request!=view||!rect||rect->getWidth()<=0||rect->getHeight()<=0||resizing)return kResultFalse;
        resizing=true;w=rect->getWidth();h=rect->getHeight();resizeOwner(w,h);view->onSize(rect);resizing=false;return kResultOk;
    }
    ~Impl(){if(view){if(attached)view->removed();view->setFrame(nullptr);view->release();}}
};
Editor::Editor(std::unique_ptr<Impl> value):impl(std::move(value)){}
Editor::~Editor()=default;
int Editor::width()const noexcept{return impl->w;}
int Editor::height()const noexcept{return impl->h;}
void Editor::resize(int w,int h){
    if(w<=0||h<=0||impl->resizing)return;
    ViewRect bounds{0,0,w,h};impl->view->checkSizeConstraint(&bounds);
    impl->w=bounds.getWidth();impl->h=bounds.getHeight();impl->view->onSize(&bounds);
}
std::unique_ptr<Editor> Processor::openEditor(void *parent,std::function<void(int,int)> resize){
    if(!impl->controller||!parent)throw std::runtime_error("This VST3 does not provide a native editor.");
    auto editor=std::make_unique<Editor::Impl>();editor->resizeOwner=std::move(resize);
    editor->view=impl->controller->createView(ViewType::kEditor);
    if(!editor->view||editor->view->isPlatformTypeSupported(kPlatformTypeHWND)!=kResultOk)
        throw std::runtime_error("This VST3 does not provide a Windows editor.");
    ViewRect rect{};
    // Kontakt reports its actual bounds only after attached(), just as in
    // the macOS host. Establish a provisional client area, then ask again.
    if(editor->view->getSize(&rect)!=kResultOk||rect.getWidth()<=0||rect.getHeight()<=0)
        rect=ViewRect{0,0,740,560};
    editor->w=rect.getWidth();editor->h=rect.getHeight();editor->view->setFrame(editor.get());
    if(editor->view->attached(parent,kPlatformTypeHWND)!=kResultOk)throw std::runtime_error("Could not attach the VST3 editor.");
    editor->attached=true;
    if(editor->view->getSize(&rect)==kResultOk&&rect.getWidth()>0&&rect.getHeight()>0){editor->w=rect.getWidth();editor->h=rect.getHeight();}
    editor->resizeOwner(editor->w,editor->h);
    return std::unique_ptr<Editor>(new Editor(std::move(editor)));
}
std::vector<Description> scan(const std::filesystem::path &path){
    auto module=loadModule(path);
    auto *f2=query<IPluginFactory2>(module->factory);auto *f3=query<IPluginFactory3>(module->factory);
    struct Refs {IPluginFactory2 *a;IPluginFactory3 *b;~Refs(){if(a)a->release();if(b)b->release();}} refs{f2,f3};
    PFactoryInfo factory{};module->factory->getFactoryInfo(&factory);
    std::vector<Description> result;
    const auto count=module->factory->countClasses();
    if(count<0||count>65536)throw std::runtime_error("Invalid VST3 factory class count.");
    for(int index=0;index<count;++index){
        PClassInfo info{};
        if(module->factory->getClassInfo(index,&info)!=kResultOk||std::strcmp(info.category,kVstAudioEffectClass))continue;
        Description d;d.path=path;d.name=info.name;d.vendor=factory.vendor;
        PClassInfo2 extra{};auto extended=f2?f2:static_cast<IPluginFactory2*>(f3);
        if(extended&&extended->getClassInfo2(index,&extra)==kResultOk){if(extra.vendor[0])d.vendor=extra.vendor;d.category=extra.subCategories;}
        PClassInfoW unicode{};
        if(f3&&f3->getClassInfoUnicode(index,&unicode)==kResultOk){if(unicode.name[0])d.name=utf8(unicode.name);if(unicode.vendor[0])d.vendor=utf8(unicode.vendor);if(unicode.subCategories[0])d.category=unicode.subCategories;}
        char uid[33]{};FUID(info.cid).toString(uid);d.classID=uid;result.push_back(std::move(d));
    }
    return result;
}
#undef FIXED_REF
} // namespace catlive::native::vst3
