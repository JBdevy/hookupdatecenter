#pragma once
#include "SystemAudioDefaults.h"
#include "FloatingControlTests.h"
namespace catlive::systemAudioDefaultsTests {
class Device final : public AudioIODevice {
  public:
    String inputName, outputName;
    Device(String output, String input, String driver = "Windows Audio (Default test)") : AudioIODevice(output.isEmpty() ? input : output, driver), inputName(input), outputName(output) {}
    StringArray getOutputChannelNames() override { return outputName.isEmpty() ? StringArray{} : StringArray{"1","2","3","4","5","6","7","8"}; }
    StringArray getInputChannelNames() override { return inputName.isEmpty() ? StringArray{} : StringArray{"1","2","3","4"}; }
    Array<double> getAvailableSampleRates() override { return {44100.,48000.}; }
    Array<int> getAvailableBufferSizes() override { return {256,512}; }
    int getDefaultBufferSize() override { return 512; }
    String open(const BigInteger &in, const BigInteger &out, double hz, int frames) override { inputs=in;outputs=out;rate=hz;buffer=frames;opened=true;return {}; }
    void close() override { stop(); opened=false; }
    bool isOpen() override { return opened; }
    void start(AudioIODeviceCallback *next) override { callback=next;if(callback)callback->audioDeviceAboutToStart(this); }
    void stop() override { if(callback){auto *old=callback;callback=nullptr;old->audioDeviceStopped();} }
    bool isPlaying() override { return callback!=nullptr; }
    String getLastError() override { return {}; }
    int getCurrentBufferSizeSamples() override { return buffer; }
    double getCurrentSampleRate() override { return rate; }
    int getCurrentBitDepth() override { return 24; }
    BigInteger getActiveOutputChannels() const override { return outputs; }
    BigInteger getActiveInputChannels() const override { return inputs; }
    int getOutputLatencyInSamples() override { return 0; }
    int getInputLatencyInSamples() override { return 0; }
  private:
    BigInteger inputs,outputs;double rate=48000;int buffer=512;bool opened=false;AudioIODeviceCallback *callback=nullptr;
};
class Type final : public AudioIODeviceType {
  public:
    int defaultInput=0,defaultOutput=0;
    Type() : AudioIODeviceType("Windows Audio (Default test)") {}
    void scanForDevices() override {}
    StringArray getDeviceNames(bool input=false) const override { return input ? StringArray{"Mic A","Mic B"} : StringArray{"Speaker A","Speaker B"}; }
    int getDefaultDeviceIndex(bool input) const override { return input ? defaultInput : defaultOutput; }
    int getIndexOfDevice(AudioIODevice *raw, bool input) const override { auto *d=dynamic_cast<Device*>(raw);return d?getDeviceNames(input).indexOf(input?d->inputName:d->outputName):-1; }
    bool hasSeparateInputsAndOutputs() const override { return true; }
    AudioIODevice *createDevice(const String &output,const String &input) override { return new Device(output,input); }
    void changed() { callDeviceChangeListeners(); }
};
inline void run() {
    auto require=[](bool okay,const char *why){if(!okay)throw std::runtime_error(why);};
    AudioDeviceManager manager;auto *type=new Type;manager.addAudioDeviceType(std::unique_ptr<AudioIODeviceType>(type));
    manager.setCurrentAudioDeviceType(type->getTypeName(),true);
    auto setup=manager.getAudioDeviceSetup();setup.inputDeviceName="Mic A";setup.outputDeviceName="Speaker A";
    setup.useDefaultInputChannels=setup.useDefaultOutputChannels=false;setup.inputChannels.setRange(0,2,true);setup.outputChannels.setRange(0,2,true);
    require(manager.setAudioDeviceSetup(setup,true).isEmpty(),"Cannot open fake endpoint");
    bool recording=false;
    SystemAudioDefaults first(manager,[&]{return !recording;}),second(manager,[]{return true;});
    XmlElement saved("DEVICESETUP");saved.setAttribute("catliveFollowSystemInput",true);saved.setAttribute("catliveFollowSystemOutput",true);
    require(first.start(&saved).isEmpty()&&second.start(nullptr).isEmpty(),"Cannot restore system default policy");
    require(first.input&&second.input&&first.output&&second.output,"Project tabs did not share routing policy");
    type->defaultInput=type->defaultOutput=1;type->changed();floatingControlTests::pump();
    require(first.apply().isEmpty(),"Default device switch failed");
    setup=manager.getAudioDeviceSetup();require(setup.inputDeviceName=="Mic B"&&setup.outputDeviceName=="Speaker B","System default names were not followed");
    require(setup.outputChannels.countNumberOfSetBits()==8&&setup.inputChannels.countNumberOfSetBits()==4,"Default switch lost physical channels");
    first.output=false;type->defaultInput=type->defaultOutput=0;
    recording=true;type->changed();second.apply();
    require(manager.getAudioDeviceSetup().inputDeviceName=="Mic B","Another project changed the recording input");
    recording=false;require(first.apply().isEmpty(),"Deferred route did not apply");
    setup=manager.getAudioDeviceSetup();require(setup.inputDeviceName=="Mic A"&&setup.outputDeviceName=="Speaker B","Explicit output changed when only input follows system");
    XmlElement restored("DEVICESETUP");second.write(restored);
    require(restored.getBoolAttribute("catliveFollowSystemInput")&&!restored.getBoolAttribute("catliveFollowSystemOutput"),"Routing policy was not preserved for restart");
}
}
