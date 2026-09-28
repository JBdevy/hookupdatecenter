#import "JarasVST3.h"
#if TARGET_OS_OSX
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
#include <algorithm>
#include <cstring>
#include <cmath>
#include <stdexcept>
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
namespace {
template<class T> bool iidIs(const TUID id) { return FUnknownPrivate::iidEqual(id,T::iid); }
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
NSString *text(const TChar *value) { return [NSString stringWithCharacters:(const unichar *)value length:std::char_traits<char16_t>::length((const char16_t *)value)]; }
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
    tresult PLUGIN_API getName(String128 name) override { UString(name,128).fromAscii("Jaras Live");return kResultOk; }
    tresult PLUGIN_API createInstance(TUID cid,TUID iid,void **out) override {
        *out=nullptr;
        if(iidIs<IMessage>(cid)&&iidIs<IMessage>(iid)) *out=new Message;
        else if(iidIs<IAttributeList>(cid)&&iidIs<IAttributeList>(iid)) *out=new Attributes;
        return *out?kResultOk:kNoInterface;
    }
};
class Stream final: public IBStream {
public:
    std::vector<uint8> bytes; int64 position=0; FIXED_REF
    Stream()=default;
    explicit Stream(NSData *data) { if(data.length) bytes.assign((const uint8 *)data.bytes,(const uint8 *)data.bytes+data.length); }
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override { *out=nullptr;if(iidIs<FUnknown>(id)||iidIs<IBStream>(id)){*out=this;return kResultOk;}return kNoInterface; }
    tresult PLUGIN_API read(void *data,int32 n,int32 *count) override { if(n<0)return kInvalidArgument;auto c=std::min<int64>(n,std::max<int64>(0,bytes.size()-position));if(c)memcpy(data,bytes.data()+position,c);position+=c;if(count)*count=(int32)c;return c==n?kResultOk:kResultFalse; }
    tresult PLUGIN_API write(void *data,int32 n,int32 *count) override { if(n<0||position+n>256*1024*1024)return kInvalidArgument;if(position+n>(int64)bytes.size())bytes.resize(position+n);if(n)memcpy(bytes.data()+position,data,n);position+=n;if(count)*count=n;return kResultOk; }
    tresult PLUGIN_API seek(int64 p,int32 mode,int64 *result) override { auto next=mode==kIBSeekSet?p:mode==kIBSeekCur?position+p:(int64)bytes.size()+p;if(next<0||next>256*1024*1024)return kInvalidArgument;position=next;if(result)*result=next;return kResultOk; }
    tresult PLUGIN_API tell(int64 *p) override { if(!p)return kInvalidArgument;*p=position;return kResultOk; }
    NSString *base64() { return [[NSData dataWithBytes:bytes.data() length:bytes.size()] base64EncodedStringWithOptions:0]; }
};
struct Module {
    CFBundleRef bundle=nullptr; IPluginFactory *factory=nullptr; bool entered=false;
    explicit Module(NSString *path) { try {
        bundle=CFBundleCreate(kCFAllocatorDefault,(__bridge CFURLRef)[NSURL fileURLWithPath:path]);
        if(!bundle||!CFBundleLoadExecutable(bundle))throw std::runtime_error("Could not load this VST3 module.");
        auto entry=(bool (*)(CFBundleRef))CFBundleGetFunctionPointerForName(bundle,CFSTR("bundleEntry"));
        if(entry){if(!entry(bundle))throw std::runtime_error("VST3 module initialization failed.");entered=true;}
        auto get=(IPluginFactory *(*)())CFBundleGetFunctionPointerForName(bundle,CFSTR("GetPluginFactory"));
        if(!get||!(factory=get()))throw std::runtime_error("This module does not provide a VST3 factory.");
        static Host applicationHost;
        if(auto f3=query<IPluginFactory3>(factory)){f3->setHostContext(&applicationHost);f3->release();}
    } catch (...) { close(); throw; } }
    ~Module(){close();}
    void close(){if(factory)factory->release();if(bundle){if(entered){auto exit=(bool (*)())CFBundleGetFunctionPointerForName(bundle,CFSTR("bundleExit"));if(exit)exit();}CFBundleUnloadExecutable(bundle);CFRelease(bundle);}}
};
std::shared_ptr<Module> loadModule(NSString *path) {
    static std::mutex mutex;static std::map<std::string,std::weak_ptr<Module>> cache;
    std::lock_guard<std::mutex> lock(mutex);auto key=std::string(path.UTF8String);
    if(auto existing=cache[key].lock())return existing;
    auto loaded=std::make_shared<Module>(path);cache[key]=loaded;return loaded;
}
struct Param { ParamID id=0; std::atomic<double> pending{0}; std::atomic<bool> dirty{false}; };
class Queue final: public IParamValueQueue {
public:
    ParamID id=0; double value=0; FIXED_REF
    tresult PLUGIN_API queryInterface(const TUID uid,void **out) override {*out=nullptr;if(iidIs<FUnknown>(uid)||iidIs<IParamValueQueue>(uid)){*out=this;return kResultOk;}return kNoInterface;}
    ParamID PLUGIN_API getParameterId() override { return id; }
    int32 PLUGIN_API getPointCount() override {return 1;}
    tresult PLUGIN_API getPoint(int32 index,int32 &offset,ParamValue &v) override {if(index)return kInvalidArgument;offset=0;v=value;return kResultOk;}
    tresult PLUGIN_API addPoint(int32,ParamValue v,int32 &index) override {value=v;index=0;return kResultOk;}
};
class Changes final: public IParameterChanges {
public:
    std::unique_ptr<Queue[]> queues; int32 capacity=0,count=0; FIXED_REF
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override {*out=nullptr;if(iidIs<FUnknown>(id)||iidIs<IParameterChanges>(id)){*out=this;return kResultOk;}return kNoInterface;}
    int32 PLUGIN_API getParameterCount() override {return count;}
    IParamValueQueue *PLUGIN_API getParameterData(int32 index) override {return index>=0&&index<count?&queues[index]:nullptr;}
    IParamValueQueue *PLUGIN_API addParameterData(const ParamID &id,int32 &index) override {for(int i=0;i<count;i++)if(queues[i].id==id){index=i;return &queues[i];}if(count==capacity)return nullptr;index=count++;queues[index].id=id;return &queues[index];}
};
class EventList final: public IEventList {
public:
    Event events[256];int count=0;FIXED_REF
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override {*out=nullptr;if(iidIs<FUnknown>(id)||iidIs<IEventList>(id)){*out=this;return kResultOk;}return kNoInterface;}
    int32 PLUGIN_API getEventCount() override{return count;}
    tresult PLUGIN_API getEvent(int32 index,Event &event) override{if(index<0||index>=count)return kInvalidArgument;event=events[index];return kResultOk;}
    tresult PLUGIN_API addEvent(Event &event) override{if(count==256)return kResultFalse;events[count++]=event;return kResultOk;}
};
struct MIDI {uint8 status,data1,data2;};
class Instance final: public IComponentHandler, public IComponentHandler2 {
public:
    std::shared_ptr<Module> module; Host host; IComponent *component=nullptr; IAudioProcessor *processor=nullptr; IEditController *controller=nullptr;
    IConnectionPoint *source=nullptr,*destination=nullptr; bool initialized=false,controllerInitialized=false,active=false,processing=false;
    bool instrument=false;
    NSString *identifier; std::atomic<bool> bypass{false},hasChanges{false}; std::unique_ptr<Param[]> params; int paramCount=0; Changes changes;
    std::vector<AudioBusBuffers> inputs,outputs; std::vector<std::vector<float>> storage; std::vector<std::vector<float *>> pointers;
    EventList events;
    std::array<MIDI,1024> midi; std::atomic<unsigned> midiRead{0},midiWrite{0}; std::atomic<bool> panic{false};
    bool held[16][128]{}; ParamID midiParameters[16][130];
    void (^edited)(void)=nil;
    double rate=48000; static constexpr int frames=4096; int mainIn=-1,mainOut=-1; int64 sampleTime=0; int processMode=kRealtime; NSString *appliedComponent=nil,*appliedController=nil;
    FIXED_REF
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override {*out=nullptr;if(iidIs<FUnknown>(id)||iidIs<IComponentHandler>(id)){*out=static_cast<IComponentHandler*>(this);return kResultOk;}if(iidIs<IComponentHandler2>(id)){*out=static_cast<IComponentHandler2*>(this);return kResultOk;}return kNoInterface;}
    tresult PLUGIN_API setDirty(TBool dirty) override{if(dirty&&edited)dispatch_async(dispatch_get_main_queue(),edited);return kResultOk;}
    tresult PLUGIN_API requestOpenEditor(FIDString) override{return kResultFalse;}
    tresult PLUGIN_API startGroupEdit() override{return kResultOk;}
    tresult PLUGIN_API finishGroupEdit() override{if(edited)dispatch_async(dispatch_get_main_queue(),edited);return kResultOk;}
    tresult PLUGIN_API beginEdit(ParamID) override{return kResultOk;}
    tresult PLUGIN_API performEdit(ParamID id,ParamValue value) override {for(int i=0;i<paramCount;i++)if(params[i].id==id){params[i].pending.store(value);params[i].dirty.store(true,std::memory_order_release);hasChanges.store(true,std::memory_order_release);return kResultOk;}return kInvalidArgument;}
    tresult PLUGIN_API endEdit(ParamID) override{if(edited)dispatch_async(dispatch_get_main_queue(),edited);return kResultOk;}
    tresult PLUGIN_API restartComponent(int32) override{return kResultFalse;}
    explicit Instance(NSDictionary *spec,double sampleRate,bool offline):rate(sampleRate),processMode(offline?kOffline:kRealtime) { try {
        identifier=spec[@"id"];instrument=[spec[@"category"] containsString:@"Instrument"]; module=loadModule(spec[@"path"]); FUID uid;
        if(!uid.fromString([spec[@"classID"] UTF8String])||module->factory->createInstance(uid,IComponent::iid,(void **)&component)!=kResultOk||!component)throw std::runtime_error("Could not create this VST3 processor.");
        if(component->initialize(&host)!=kResultOk)throw std::runtime_error("VST3 processor initialization failed."); initialized=true;
        processor=query<IAudioProcessor>(component);if(!processor||processor->canProcessSampleSize(kSample32)!=kResultOk)throw std::runtime_error("This VST3 processor does not support 32-bit audio.");
        controller=query<IEditController>(component);
        if(!controller){TUID cid{};if(component->getControllerClassId(cid)==kResultOk&&module->factory->createInstance(cid,IEditController::iid,(void **)&controller)==kResultOk&&controller){if(controller->initialize(&host)!=kResultOk)throw std::runtime_error("VST3 controller initialization failed.");controllerInitialized=true;}}
        if(controller){controller->setComponentHandler(this);source=query<IConnectionPoint>(component);destination=query<IConnectionPoint>(controller);if(source&&destination){source->connect(destination);destination->connect(source);}}
        auto restore=[&](NSString *key,auto target){NSData *data=[[NSData alloc] initWithBase64EncodedString:spec[key]?:@"" options:0];if(data.length){Stream stream(data);target(stream);}};
        restore(@"componentState",[&](Stream &stream){component->setState(&stream);});
        if(controller){Stream stream;if(component->getState(&stream)==kResultOk){stream.position=0;controller->setComponentState(&stream);}restore(@"controllerState",[&](Stream &stream){controller->setState(&stream);});}
        for(int bus=0;bus<component->getBusCount(kEvent,kInput);bus++)component->activateBus(kEvent,kInput,bus,bus==0);
        for(auto &channel:midiParameters)std::fill(std::begin(channel),std::end(channel),kNoParamId);
        if(auto mapping=query<IMidiMapping>(controller)){for(int channel=0;channel<16;channel++)for(int cc=0;cc<130;cc++)mapping->getMidiControllerAssignment(0,channel,cc,midiParameters[channel][cc]);mapping->release();}
        int inCount=component->getBusCount(kAudio,kInput),outCount=component->getBusCount(kAudio,kOutput);
        if(inCount>64||outCount<1||outCount>64)throw std::runtime_error("Unsupported VST3 audio bus layout.");
        std::vector<SpeakerArrangement> in(inCount),out(outCount);
        for(int dir=0;dir<2;dir++){auto &arr=dir?out:in;for(int i=0;i<(int)arr.size();i++){BusInfo info{};component->getBusInfo(kAudio,dir?kOutput:kInput,i,info);processor->getBusArrangement(dir?kOutput:kInput,i,arr[i]);if(info.busType==kMain&&(dir?mainOut:mainIn)==-1){(dir?mainOut:mainIn)=i;arr[i]=SpeakerArr::kStereo;}}}
        if(mainOut<0||processor->setBusArrangements(in.data(),inCount,out.data(),outCount)!=kResultOk)throw std::runtime_error("This VST3 processor does not support a stereo output.");
        inputs.resize(inCount);outputs.resize(outCount);
        storage.reserve((inCount+outCount)*2);pointers.resize(inCount+outCount);
        for(int dir=0;dir<2;dir++){auto &buses=dir?outputs:inputs;for(int i=0;i<(int)buses.size();i++){BusInfo info{};component->getBusInfo(kAudio,dir?kOutput:kInput,i,info);if(info.channelCount<0||info.channelCount>64||(dir&&i==mainOut&&info.channelCount<1))throw std::runtime_error("Unsupported VST3 bus width.");auto &p=pointers[(dir?inCount:0)+i];p.resize(info.channelCount);for(int c=0;c<info.channelCount;c++){storage.emplace_back(frames,0);p[c]=storage.back().data();}buses[i].numChannels=info.channelCount;buses[i].channelBuffers32=p.data();component->activateBus(kAudio,dir?kOutput:kInput,i,i==(dir?mainOut:mainIn));}}
        if(controller){paramCount=std::min(65536,std::max(0,controller->getParameterCount()));params=std::make_unique<Param[]>(paramCount);changes.capacity=paramCount;changes.queues=std::make_unique<Queue[]>(paramCount);for(int i=0;i<paramCount;i++){ParameterInfo info{};controller->getParameterInfo(i,info);params[i].id=info.id;params[i].pending=controller->getParamNormalized(info.id);}}
        ProcessSetup setup{processMode,kSample32,frames,rate};if(processor->setupProcessing(setup)!=kResultOk)throw std::runtime_error("VST3 audio setup failed.");
        if(component->setActive(true)!=kResultOk)throw std::runtime_error("Could not activate this VST3 processor.");active=true;
        if(processor->setProcessing(true)!=kResultOk)throw std::runtime_error("Could not start this VST3 processor.");processing=true;
        appliedComponent=spec[@"componentState"];appliedController=spec[@"controllerState"];
        bypass=[spec[@"bypassed"] boolValue];
    } catch (...) { close(); throw; } }
    ~Instance(){close();}
    void close(){if(processing)processor->setProcessing(false);if(active)component->setActive(false);if(source&&destination){source->disconnect(destination);destination->disconnect(source);}if(source)source->release();if(destination)destination->release();if(controller){controller->setComponentHandler(nullptr);if(controllerInitialized)controller->terminate();controller->release();}if(processor)processor->release();if(component){if(initialized)component->terminate();component->release();}}
    void enqueue(uint8 status,uint8 data1,uint8 data2){
        int kind=status&0xf0,channel=status&15;
        if(kind==0xb0||kind==0xe0){auto cc=kind==0xe0?129:data1;if(cc<130&&midiParameters[channel][cc]!=kNoParamId)performEdit(midiParameters[channel][cc],kind==0xe0?double(data1|(data2<<7))/16383.:double(data2)/127.);if(kind==0xb0&&data1>=120)panic=true;return;}
        if(kind!=0x80&&kind!=0x90)return;
        auto write=midiWrite.load(std::memory_order_relaxed),read=midiRead.load(std::memory_order_acquire);
        if(write-read>=midi.size()){panic=true;return;}
        midi[write%midi.size()]={status,data1,data2};midiWrite.store(write+1,std::memory_order_release);
    }
    void process(AudioBufferList *buffer,unsigned count,double position,double tempo,int beats,int unit,bool playing){
        if(bypass.load()||count>frames)return;
        for(auto &bus:inputs){bus.silenceFlags=0;for(int c=0;c<bus.numChannels;c++)memset(bus.channelBuffers32[c],0,count*sizeof(float));}
        if(mainIn>=0){auto &bus=inputs[mainIn];for(int c=0;c<std::min<int>(2,bus.numChannels);c++)if(c<(int)buffer->mNumberBuffers&&buffer->mBuffers[c].mData)memcpy(bus.channelBuffers32[c],buffer->mBuffers[c].mData,count*sizeof(float));}
        for(auto &bus:outputs){bus.silenceFlags=0;for(int c=0;c<bus.numChannels;c++)memset(bus.channelBuffers32[c],0,count*sizeof(float));}
        changes.count=0;if(hasChanges.exchange(false,std::memory_order_acq_rel))for(int i=0;i<paramCount;i++)if(params[i].dirty.exchange(false,std::memory_order_acq_rel)){int32 index;auto q=changes.addParameterData(params[i].id,index);q->addPoint(0,params[i].pending.load(),index);}
        events.count=0;
        if(panic.load()){bool remaining=false;for(int channel=0;channel<16;channel++)for(int note=0;note<128;note++)if(held[channel][note]){Event event{};event.type=Event::kNoteOffEvent;event.noteOff.channel=channel;event.noteOff.pitch=note;event.noteOff.noteId=-1;if(events.addEvent(event)==kResultOk)held[channel][note]=false;else remaining=true;}panic=remaining;}
        auto read=midiRead.load(std::memory_order_relaxed),write=midiWrite.load(std::memory_order_acquire);
        while(read!=write&&events.count<256){auto message=midi[read++%midi.size()];Event event{};int channel=message.status&15,note=message.data1&127;bool on=(message.status&0xf0)==0x90&&message.data2>0;event.type=on?Event::kNoteOnEvent:Event::kNoteOffEvent;if(on){event.noteOn.channel=channel;event.noteOn.pitch=note;event.noteOn.velocity=message.data2/127.f;event.noteOn.noteId=-1;}else{event.noteOff.channel=channel;event.noteOff.pitch=note;event.noteOff.velocity=message.data2/127.f;event.noteOff.noteId=-1;}events.addEvent(event);held[channel][note]=on;}
        midiRead.store(read,std::memory_order_release);
        ProcessContext context{};context.sampleRate=rate;context.projectTimeSamples=llround(position*rate);context.tempo=tempo;context.timeSigNumerator=beats;context.timeSigDenominator=unit;context.projectTimeMusic=position*tempo/60.;context.state=ProcessContext::kTempoValid|ProcessContext::kTimeSigValid|ProcessContext::kProjectTimeMusicValid|(playing?ProcessContext::kPlaying:0);
        ProcessData data;data.processMode=processMode;data.numSamples=count;data.numInputs=(int)inputs.size();data.numOutputs=(int)outputs.size();data.inputs=inputs.data();data.outputs=outputs.data();data.inputParameterChanges=&changes;data.inputEvents=&events;data.processContext=&context;
        if(processor->process(data)==kResultOk){auto &bus=outputs[mainOut];for(int c=0;c<(int)std::min(2u,buffer->mNumberBuffers);c++)if(buffer->mBuffers[c].mData){auto dest=(float *)buffer->mBuffers[c].mData;auto source=bus.channelBuffers32[std::min(c,bus.numChannels-1)];if(bus.silenceFlags&(1ull<<std::min(c,bus.numChannels-1)))memset(dest,0,count*sizeof(float));else for(unsigned f=0;f<count;f++)dest[f]=std::isfinite(source[f])?source[f]:0;}}
        sampleTime+=count;
    }
    void restore(NSDictionary *spec){
        NSString *c=spec[@"componentState"],*v=spec[@"controllerState"];
        if((c==appliedComponent||[c isEqualToString:appliedComponent])&&(v==appliedController||[v isEqualToString:appliedController]))return;
        auto current=state();
        if(c&&![c isEqualToString:current[@"componentState"]]){NSData *data=[[NSData alloc]initWithBase64EncodedString:c options:0];if(data.length){Stream stream(data);component->setState(&stream);if(controller){stream.position=0;controller->setComponentState(&stream);}}}
        if(v&&controller&&![v isEqualToString:current[@"controllerState"]]){NSData *data=[[NSData alloc]initWithBase64EncodedString:v options:0];if(data.length){Stream stream(data);controller->setState(&stream);}}
        if(controller)for(int n=0;n<paramCount;n++)performEdit(params[n].id,controller->getParamNormalized(params[n].id));
        appliedComponent=c;appliedController=v;
    }
    NSDictionary *state(){Stream componentData,controllerData;component->getState(&componentData);if(controller)controller->getState(&controllerData);return @{@"componentState":componentData.base64(),@"controllerState":controllerData.base64()};}
};
struct Chain {std::vector<std::shared_ptr<Instance>> instances;};
struct Kernel {
    std::atomic<bool> instrumentMIDIInput{false};
    std::atomic<double> position{0},tempo{120};std::atomic<int> beats{4},unit{4};std::atomic<bool> playing{false};
    std::atomic<uint64_t> clockGeneration{0}; uint64_t seenClock=0; int64 clockFrames=0; std::atomic<double> sampleRate{48000};
    std::atomic<Chain *> published{nullptr}; std::atomic<unsigned> readers{0}; std::unique_ptr<Chain> current;std::vector<std::unique_ptr<Chain>> retired;
    void process(AudioBufferList *b,unsigned n){
        if(!published.load())return;
        readers.fetch_add(1);auto chain=published.load();auto generation=clockGeneration.load(std::memory_order_acquire);
        if(generation!=seenClock){clockFrames=0;seenClock=generation;}
        double time=position.load()+clockFrames/sampleRate.load();
        if(chain)for(auto &i:chain->instances)i->process(b,n,time,tempo.load(),beats.load(),unit.load(),playing.load());
        clockFrames+=n;readers.fetch_sub(1);
    }
    void replace(std::unique_ptr<Chain> next){auto old=std::move(current);current=std::move(next);published.store(current.get());if(old)retired.push_back(std::move(old));if(readers.load()==0)retired.clear();}
    std::shared_ptr<Instance> find(NSString *id){if(current)for(auto &i:current->instances)if([i->identifier isEqualToString:id])return i;return nullptr;}
};
class Frame final: public IPlugFrame {
    __weak NSView *owner;
    bool resizing = false;
public:
    explicit Frame(NSView *view):owner(view){}
    FIXED_REF
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override{*out=nullptr;if(iidIs<FUnknown>(id)||iidIs<IPlugFrame>(id)){*out=this;return kResultOk;}return kNoInterface;}
    tresult PLUGIN_API resizeView(IPlugView *view,ViewRect *rect) override{
        if(!rect||!owner||![NSThread isMainThread]||resizing||rect->getWidth()<=0||rect->getHeight()<=0)return kResultFalse;
        resizing = true;
        NSSize extra = NSZeroSize;
        if(owner.window) {
            extra.width = std::max(0.0, owner.window.contentView.bounds.size.width-owner.frame.size.width);
            extra.height = std::max(0.0, owner.window.contentView.bounds.size.height-owner.frame.size.height);
        }
        [owner setFrameSize:NSMakeSize(rect->getWidth(),rect->getHeight())];
        [owner.window setContentSize:NSMakeSize(rect->getWidth()+extra.width,rect->getHeight()+extra.height)];
        resizing = false;
        return kResultOk;
    }
};
NSError *failure(const std::exception &e){return [NSError errorWithDomain:@"JarasVST3" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:e.what()]}];}
}
@interface JarasVSTAudioUnit: AUAudioUnit {
@public Kernel kernel; AUAudioUnitBus *_input,*_output;AUAudioUnitBusArray *_inputs,*_outputs;
}
@end
@implementation JarasVSTAudioUnit
- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {if((self=[super initWithComponentDescription:d options:o error:e])){auto f=[[AVAudioFormat alloc]initStandardFormatWithSampleRate:48000 channels:2];_input=[[AUAudioUnitBus alloc]initWithFormat:f error:e];_output=[[AUAudioUnitBus alloc]initWithFormat:f error:e];_inputs=[[AUAudioUnitBusArray alloc]initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_input]];_outputs=[[AUAudioUnitBusArray alloc]initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_output]];self.maximumFramesToRender=4096;}return self;}
- (AUAudioUnitBusArray *)inputBusses{return _inputs;}
- (AUAudioUnitBusArray *)outputBusses{return _outputs;}
- (NSTimeInterval)latency {double seconds=0;if(kernel.current)for(auto &i:kernel.current->instances)if(!i->bypass.load())seconds+=i->processor->getLatencySamples()/i->rate;return seconds;}
- (AUInternalRenderBlock)internalRenderBlock {Kernel *state=&kernel;return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *t,AVAudioFrameCount n,NSInteger bus,AudioBufferList *out,const AURenderEvent *events,AURenderPullInputBlock pull){if(!pull)return kAudioUnitErr_NoConnection;auto result=pull(flags,t,n,0,out);if(result==noErr)state->process(out,n);if(state->published.load())*flags&=~kAudioUnitRenderAction_OutputIsSilence;return result;};}
@end
@interface JarasVSTEditorView: NSView { @public std::shared_ptr<Instance> instance; IPlugView *plugView; std::unique_ptr<Frame> frame; BOOL attached; }
@end
@implementation JarasVSTEditorView
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if(!plugView) return;
    if(!self.window) { const BOOL wasAttached=attached; attached=NO; if(wasAttached) plugView->removed(); return; }
    if(attached) return;
    // Attach after the panel is ordered on screen; GPU-backed Cocoa editors
    // cannot initialize their surface while the parent window is still hidden.
    dispatch_async(dispatch_get_main_queue(), ^{ [self attachEditor]; });
}
- (void)attachEditor {
    if(!plugView || attached || !self.window || !self.window.visible) return;
    attached=YES; // Resize callbacks issued by attached() must reach onSize().
    attached=plugView->attached((__bridge void *)self,kPlatformTypeNSView)==kResultOk;
    if(!attached) return;
    ViewRect rect;
    if(plugView->getSize(&rect)==kResultOk && rect.getWidth()>0 && rect.getHeight()>0) frame->resizeView(plugView,&rect);
    self.needsDisplay=YES;
}
- (BOOL)isFlipped{return YES;}
- (void)setFrameSize:(NSSize)size {
    ViewRect rect(0,0,(int32)size.width,(int32)size.height);
    if(plugView)plugView->checkSizeConstraint(&rect);
    [super setFrameSize:NSMakeSize(rect.getWidth(),rect.getHeight())];
    if(plugView && attached)plugView->onSize(&rect);
}
- (void)dealloc {if(plugView){if(attached)plugView->removed();plugView->setFrame(nullptr);plugView->release();}}
@end
@implementation JarasVST3
+ (NSArray<NSDictionary *> *)scan:(NSString *)path error:(NSError **)error {
    try {
        Module module(path);
        auto f2 = query<IPluginFactory2>(module.factory);
        auto f3 = query<IPluginFactory3>(module.factory);
        PFactoryInfo factoryInfo{};
        module.factory->getFactoryInfo(&factoryInfo);
        NSMutableArray *result = [NSMutableArray array];
        for (int index = 0; index < module.factory->countClasses(); ++index) {
            PClassInfo info{};
            if (module.factory->getClassInfo(index, &info) != kResultOk ||
                strcmp(info.category, kVstAudioEffectClass)) continue;
            NSString *name = @(info.name);
            NSString *vendor = @(factoryInfo.vendor);
            NSString *category = @"";
            PClassInfo2 extra{};
            auto factory2 = f2 ? f2 : static_cast<IPluginFactory2 *>(f3);
            if (factory2 && factory2->getClassInfo2(index, &extra) == kResultOk) {
                if (extra.vendor[0]) vendor = @(extra.vendor);
                category = @(extra.subCategories);
            }
            PClassInfoW unicode{};
            if (f3 && f3->getClassInfoUnicode(index, &unicode) == kResultOk) {
                if (unicode.name[0]) name = text(unicode.name);
                if (unicode.vendor[0]) vendor = text(unicode.vendor);
                if (unicode.subCategories[0]) category = @(unicode.subCategories);
            }
            char uid[33]{};
            FUID(info.cid).toString(uid);
            [result addObject:@{@"classID": @(uid), @"name": name, @"path": path,
                                @"vendor": vendor, @"category": category}];
        }
        if (f2) f2->release();
        if (f3) f3->release();
        return result;
    } catch (const std::exception &exception) {
        if (error) *error = failure(exception);
        return @[];
    }
}
+ (AVAudioUnitEffect *)makeNode {static dispatch_once_t once;AudioComponentDescription d={kAudioUnitType_Effect,'JLV3','Jara',0,0};dispatch_once(&once,^{[AUAudioUnit registerSubclass:JarasVSTAudioUnit.class asComponentDescription:d name:@"Jaras VST3" version:1];});return [[AVAudioUnitEffect alloc]initWithAudioComponentDescription:d];}
+ (BOOL)configure:(AVAudioUnitEffect *)node plugins:(NSArray<NSDictionary *> *)plugins error:(NSError **)error {auto &k=((JarasVSTAudioUnit *)node.AUAudioUnit)->kernel;try{if(plugins.count==0){k.replace(nullptr);return YES;}auto next=std::make_unique<Chain>();double rate=[node outputFormatForBus:0].sampleRate;k.sampleRate=rate;for(NSDictionary *spec in plugins){auto i=k.find(spec[@"id"]);if(!i||fabs(i->rate-rate)>0.01)i=std::make_shared<Instance>(spec,rate,node.AUAudioUnit.isRenderingOffline);i->restore(spec);bool bypass=[spec[@"bypassed"]boolValue];if(bypass!=i->bypass.load())i->panic=true;i->bypass=bypass;next->instances.push_back(i);}k.replace(std::move(next));return YES;}catch(const std::exception &e){if(error)*error=failure(e);return NO;}}
+ (void)sendMIDI:(AVAudioUnitEffect *)node status:(unsigned char)status data1:(unsigned char)data1 data2:(unsigned char)data2 {auto &k=((JarasVSTAudioUnit *)node.AUAudioUnit)->kernel;if(k.current)for(auto &i:k.current->instances)if(!i->instrument||k.instrumentMIDIInput.load()||(status&0xf0)!=0x90||data2==0)i->enqueue(status,data1,data2);}
+ (void)instrumentMIDIInput:(AVAudioUnitEffect *)node enabled:(BOOL)enabled {auto &k=((JarasVSTAudioUnit *)node.AUAudioUnit)->kernel;k.instrumentMIDIInput.store(enabled);}
+ (void)silence:(AVAudioUnitEffect *)node {auto &k=((JarasVSTAudioUnit *)node.AUAudioUnit)->kernel;if(k.current)for(auto &i:k.current->instances)i->panic=true;}
+ (void)transport:(AVAudioUnitEffect *)node position:(double)position tempo:(double)tempo beats:(int)beats unit:(int)unit playing:(BOOL)playing {auto &k=((JarasVSTAudioUnit *)node.AUAudioUnit)->kernel;k.position=position;k.tempo=tempo;k.beats=beats;k.unit=unit;k.playing=playing;k.clockGeneration.fetch_add(1,std::memory_order_release);}
+ (void)onEdit:(AVAudioUnitEffect *)node identifier:(NSString *)id action:(void (^)(void))action {auto i=((JarasVSTAudioUnit *)node.AUAudioUnit)->kernel.find(id);if(i)i->edited=[action copy];}
+ (NSDictionary *)state:(AVAudioUnitEffect *)node identifier:(NSString *)id {auto i=((JarasVSTAudioUnit *)node.AUAudioUnit)->kernel.find(id);return i?i->state():nil;}
+ (NSArray<NSDictionary *> *)parameters:(AVAudioUnitEffect *)node identifier:(NSString *)id {auto i=((JarasVSTAudioUnit *)node.AUAudioUnit)->kernel.find(id);NSMutableArray *result=[NSMutableArray array];if(i&&i->controller)for(int n=0;n<i->paramCount;n++){ParameterInfo p{};i->controller->getParameterInfo(n,p);if(p.flags&ParameterInfo::kIsReadOnly)continue;[result addObject:@{@"id":@(p.id),@"name":text(p.title),@"value":@(i->controller->getParamNormalized(p.id))}];}return result;}
+ (void)setParameter:(AVAudioUnitEffect *)node identifier:(NSString *)id parameter:(unsigned int)param value:(double)value {auto i=((JarasVSTAudioUnit *)node.AUAudioUnit)->kernel.find(id);if(i&&i->controller){value=std::clamp(value,0.,1.);i->controller->setParamNormalized(param,value);i->performEdit(param,value);}}
+ (NSView *)editor:(AVAudioUnitEffect *)node identifier:(NSString *)identifier {
    auto instance = ((JarasVSTAudioUnit *)node.AUAudioUnit)->kernel.find(identifier);
    if (!instance || !instance->controller) return nil;
    auto plugin = instance->controller->createView(ViewType::kEditor);
    if (!plugin) return nil;
    if (plugin->isPlatformTypeSupported(kPlatformTypeNSView) != kResultOk) { plugin->release(); return nil; }
    ViewRect rect{};
    plugin->getSize(&rect);
    NSSize size = NSMakeSize(rect.getWidth() > 0 ? rect.getWidth() : 740, rect.getHeight() > 0 ? rect.getHeight() : 560);
    auto view = [[JarasVSTEditorView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    view->instance = instance; view->plugView = plugin; view->frame = std::make_unique<Frame>(view);
    plugin->setFrame(view->frame.get());
    return view;
}
@end
// Scan in an isolated process before SwiftUI, login or an audio device exists.
__attribute__((constructor)) static void scanEntry(){@autoreleasepool{auto args=NSProcessInfo.processInfo.arguments;if(args.count==4&&[args[1]isEqualToString:@"--scan-vst3"]){NSError *error=nil;auto result=[JarasVST3 scan:args[2] error:&error];auto data=[NSJSONSerialization dataWithJSONObject:@{@"plugins":result,@"error":error.localizedDescription?:@""} options:0 error:nil];[data writeToFile:args[3] atomically:YES];exit(error?1:0);}}}
#endif
