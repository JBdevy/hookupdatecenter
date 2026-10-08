#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ustring.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include <atomic>
#include <cstring>
#include <algorithm>
using namespace Steinberg;using namespace Steinberg::Vst;
static const TUID cid=INLINE_UID(0x12341234,0x56785678,0xABCDEF00,0x12345678);
class Editor final: public IPlugView {
    uint32 refs = 1; IPlugFrame *frame = nullptr; ViewRect size{0,0,32,32};
public:
    tresult PLUGIN_API queryInterface(const TUID id, void **out) override {
        *out = nullptr;
        if (FUnknownPrivate::iidEqual(id, FUnknown_iid) || FUnknownPrivate::iidEqual(id, IPlugView_iid)) { *out = this; addRef(); return kResultOk; }
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return ++refs; }
    uint32 PLUGIN_API release() override { auto count = --refs; if (!count) delete this; return count; }
    tresult PLUGIN_API isPlatformTypeSupported(FIDString type) override { return strcmp(type,kPlatformTypeNSView) == 0 ? kResultOk : kResultFalse; }
    tresult PLUGIN_API attached(void *, FIDString) override { ViewRect full{0,0,980,660}; return frame ? frame->resizeView(this,&full) : kResultFalse; }
    tresult PLUGIN_API removed() override { return kResultOk; }
    tresult PLUGIN_API onWheel(float) override { return kResultFalse; }
    tresult PLUGIN_API onKeyDown(char16,int16,int16) override { return kResultFalse; }
    tresult PLUGIN_API onKeyUp(char16,int16,int16) override { return kResultFalse; }
    tresult PLUGIN_API getSize(ViewRect *rect) override { *rect = size; return kResultOk; }
    tresult PLUGIN_API onSize(ViewRect *rect) override { size = *rect; return kResultOk; }
    tresult PLUGIN_API onFocus(TBool) override { return kResultOk; }
    tresult PLUGIN_API setFrame(IPlugFrame *value) override { frame = value; return kResultOk; }
    tresult PLUGIN_API canResize() override { return kResultTrue; }
    tresult PLUGIN_API checkSizeConstraint(ViewRect *rect) override { rect->right = rect->left + std::max(320,rect->getWidth()); rect->bottom = rect->top + std::max(200,rect->getHeight()); return kResultOk; }
};
class Gain final: public IComponent,public IAudioProcessor,public IEditController,public IMidiMapping {
    std::atomic<uint32> refs{1};std::atomic<float> gain{0.5f};std::atomic<uint64> inputSilence{0};bool note=false,held=false,pedal=false;
public:
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override{*out=nullptr; if(FUnknownPrivate::iidEqual(id,FUnknown_iid)||FUnknownPrivate::iidEqual(id,IComponent_iid))*out=static_cast<IComponent*>(this);else if(FUnknownPrivate::iidEqual(id,IAudioProcessor_iid))*out=static_cast<IAudioProcessor*>(this);else if(FUnknownPrivate::iidEqual(id,IEditController_iid))*out=static_cast<IEditController*>(this);if(FUnknownPrivate::iidEqual(id,IMidiMapping_iid))*out=static_cast<IMidiMapping*>(this);if(*out){addRef();return kResultOk;}return kNoInterface;}
    uint32 PLUGIN_API addRef() override{return ++refs;}uint32 PLUGIN_API release() override{auto n=--refs;if(!n)delete this;return n;}
    tresult PLUGIN_API initialize(FUnknown*) override{return kResultOk;}tresult PLUGIN_API terminate() override{return kResultOk;}
    tresult PLUGIN_API getControllerClassId(TUID) override{return kResultFalse;}
    tresult PLUGIN_API setIoMode(IoMode) override{return kResultOk;}
    int32 PLUGIN_API getBusCount(MediaType type,BusDirection dir) override{return type==kAudio?1:dir==kInput?1:0;}
    tresult PLUGIN_API getBusInfo(MediaType type,BusDirection dir,int32 index,BusInfo &info) override{if(index)return kInvalidArgument;info.mediaType=type;info.direction=dir;info.channelCount=type==kAudio?2:16;info.busType=kMain;info.flags=BusInfo::kDefaultActive;return kResultOk;}
    tresult PLUGIN_API getRoutingInfo(RoutingInfo&,RoutingInfo&) override{return kNotImplemented;}
    tresult PLUGIN_API activateBus(MediaType,BusDirection,int32,TBool) override{return kResultOk;}
    tresult PLUGIN_API setActive(TBool) override{return kResultOk;}
    tresult PLUGIN_API setState(IBStream *stream) override{float v;int32 n=0;if(stream->read(&v,4,&n)!=kResultOk||n!=4)return kResultFalse;gain=v;return kResultOk;}
    tresult PLUGIN_API getState(IBStream *stream) override{float v=gain.load();auto mask=inputSilence.load();auto result=stream->write(&v,4,nullptr);return result==kResultOk?stream->write(&mask,8,nullptr):result;}
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement*,int32 in,SpeakerArrangement*,int32 out) override{return in==1&&out==1?kResultOk:kResultFalse;}
    tresult PLUGIN_API getBusArrangement(BusDirection,int32,SpeakerArrangement &arr) override{arr=3;return kResultOk;}
    tresult PLUGIN_API canProcessSampleSize(int32 size) override{return size==kSample32?kResultOk:kResultFalse;}
    uint32 PLUGIN_API getLatencySamples() override{return 0;}
    tresult PLUGIN_API setupProcessing(ProcessSetup&) override{return kResultOk;}
    tresult PLUGIN_API setProcessing(TBool) override{return kResultOk;}
    tresult PLUGIN_API process(ProcessData &data) override{
        inputSilence.store(data.inputs[0].silenceFlags);

        if(data.inputParameterChanges)for(int i=0;i<data.inputParameterChanges->getParameterCount();i++){auto q=data.inputParameterChanges->getParameterData(i);int32 offset;double value;if(q->getPoint(0,offset,value)==kResultOk){if(q->getParameterId()==1){pedal=value>=0.5;if(!pedal&&!held)note=false;}else gain=value;}}
        int nextEvent=0;
        for(int f=0;f<data.numSamples;f++) {
            while(data.inputEvents && nextEvent<data.inputEvents->getEventCount()) {
                Event e{};data.inputEvents->getEvent(nextEvent,e);if(e.sampleOffset>f)break;++nextEvent;
                if(e.type==Event::kNoteOnEvent){held=true;note=true;}if(e.type==Event::kNoteOffEvent){held=false;note=pedal;}
            }
            for(int c=0;c<2;c++)data.outputs[0].channelBuffers32[c][f]=data.inputs[0].channelBuffers32[c][f]*gain.load()+(note?0.125f:0);
        }
        return kResultOk;
    }
    uint32 PLUGIN_API getTailSamples() override{return 0;}
    tresult PLUGIN_API setComponentState(IBStream *stream) override{return setState(stream);}
    int32 PLUGIN_API getParameterCount() override{return 2;}
    tresult PLUGIN_API getParameterInfo(int32 index,ParameterInfo &info) override{info.id=index;UString(info.title,128).fromAscii(index==0?"Gain":"Sustain");info.defaultNormalizedValue=index==0?0.5:0;info.flags=ParameterInfo::kCanAutomate;return kResultOk;}
    tresult PLUGIN_API getParamStringByValue(ParamID,ParamValue value,String128 text) override{UString(text,128).printFloat(value,3);return kResultOk;}
    tresult PLUGIN_API getParamValueByString(ParamID,TChar*,ParamValue&) override{return kResultFalse;}
    ParamValue PLUGIN_API normalizedParamToPlain(ParamID,ParamValue value) override{return value;}
    ParamValue PLUGIN_API plainParamToNormalized(ParamID,ParamValue value) override{return value;}
    ParamValue PLUGIN_API getParamNormalized(ParamID id) override{return id==0?gain.load():0;}
    tresult PLUGIN_API setParamNormalized(ParamID id,ParamValue value) override{if(id==0)gain=value;return kResultOk;}
    tresult PLUGIN_API getMidiControllerAssignment(int32,int16,CtrlNumber cc,ParamID &id) override{if(cc==64){id=1;return kResultOk;}return kResultFalse;}
    tresult PLUGIN_API setComponentHandler(IComponentHandler*) override{return kResultOk;}
    IPlugView *PLUGIN_API createView(FIDString) override{return new Editor;}
};
class Factory final: public IPluginFactory {
public:
    tresult PLUGIN_API queryInterface(const TUID id,void **out) override{*out=nullptr;if(FUnknownPrivate::iidEqual(id,FUnknown_iid)||FUnknownPrivate::iidEqual(id,IPluginFactory_iid)){*out=this;return kResultOk;}return kNoInterface;}
    uint32 PLUGIN_API addRef() override{return 1;}uint32 PLUGIN_API release() override{return 1;}
    tresult PLUGIN_API getFactoryInfo(PFactoryInfo *info) override{*info=PFactoryInfo("CatLive test fixture","","",0);return kResultOk;}
    int32 PLUGIN_API countClasses() override{return 1;}
    tresult PLUGIN_API getClassInfo(int32,PClassInfo *info) override{*info=PClassInfo(cid,PClassInfo::kManyInstances,kVstAudioEffectClass,"Gain fixture");return kResultOk;}
    tresult PLUGIN_API createInstance(FIDString uid,FIDString iid,void **out) override{if(!FUnknownPrivate::iidEqual(uid,cid))return kResultFalse;auto gain=new Gain;auto result=gain->queryInterface(iid,out);gain->release();return result;}
};
extern "C" __attribute__((visibility("default"))) IPluginFactory *GetPluginFactory(){static Factory factory;return &factory;}
extern "C" __attribute__((visibility("default"))) bool bundleEntry(void*){return true;}
extern "C" __attribute__((visibility("default"))) bool bundleExit(){return true;}
