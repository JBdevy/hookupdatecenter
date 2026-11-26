// Explicit hardware integration test (not CI): captures an ordinary Windows
// playback session, with CatLive output silent, then checks silence and restart.
#include <juce_audio_devices/juce_audio_devices.h>
#include <juce_audio_formats/juce_audio_formats.h>
#include <windows.h>
#include <mmsystem.h>
#include <atomic>
#include <iostream>
using namespace juce;
struct Capture final : AudioIODeviceCallback {
    std::atomic<int> callbacks{0};
    std::atomic<float> peak{0};
    std::atomic<double> energy{0};
    std::atomic<long long> frames{0};
    void audioDeviceAboutToStart(AudioIODevice*) override {}
    void audioDeviceStopped() override {}
    void audioDeviceIOCallbackWithContext(const float* const* input,int inputs,float* const* output,int outputs,int count,const AudioIODeviceCallbackContext&) override {
        for(int ch=0;ch<outputs;++ch) if(output[ch]) FloatVectorOperations::clear(output[ch],count);
        double sum=0;float maximum=peak.load();
        if(inputs>0&&input[0]) for(int i=0;i<count;++i) { const float value=input[0][i];sum+=value*value;maximum=std::max(maximum,std::abs(value)); }
        peak=maximum;energy=energy.load()+sum;frames=frames.load()+count;++callbacks;
    }
    void reset() { peak=0;energy=0;frames=0;callbacks=0; }
};
static void pump(int ms) { const auto end=Time::getMillisecondCounter()+uint32(ms);while(Time::getMillisecondCounter()<end)MessageManager::getInstance()->runDispatchLoopUntil(10); }
int main(int argc,char** argv) {
    ScopedJuceInitialiser_GUI gui;
    if(argc!=2||String(argv[1])!="--capture") {std::cerr<<"Use --capture on a Windows PC with a default audio output.\n";return 2;}
    AudioDeviceManager manager;
    AudioIODeviceType* loopback=nullptr;AudioIODeviceType* shared=nullptr;
    for(auto* type:manager.getAvailableDeviceTypes()) {
        if(type->getTypeName()=="Windows Audio (Loopback)")loopback=type;
        if(type->getTypeName()=="Windows Audio")shared=type;
    }
    if(!loopback||!shared) {std::cerr<<"Loopback driver missing\n";return 1;}
    loopback->scanForDevices();shared->scanForDevices();
    const auto inputs=loopback->getDeviceNames(true), outputs=loopback->getDeviceNames(false);
    if(inputs.isEmpty()||inputs!=outputs||outputs!=shared->getDeviceNames(false)) {std::cerr<<"Invalid loopback endpoint catalog\n";return 1;}
    std::cout<<"Endpoint: "<<outputs[0]<<std::endl;
    const auto wav=File::getSpecialLocation(File::tempDirectory).getNonexistentChildFile("catlive-loopback-test",".wav");
    {
        WavAudioFormat format;auto stream=wav.createOutputStream();
        std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(),48000,2,16,{},0));
        if(!writer)return 1;stream.release();
        AudioBuffer<float> samples(2,96000);
        for(int n=0;n<samples.getNumSamples();++n)for(int ch=0;ch<2;++ch)samples.setSample(ch,n,0.08f*std::sin(float(n)*MathConstants<float>::twoPi*440/48000));
        writer->writeFromAudioSampleBuffer(samples,0,samples.getNumSamples());
    }
    int failures=0;
    for(bool outputEnabled:{true,false}) for(double requestedRate:{48000.,44100.}) {
        std::unique_ptr<AudioIODevice> device(loopback->createDevice(outputEnabled?outputs[0]:String{},inputs[0]));
        if(!device) {++failures;continue;}
        BigInteger stereo;stereo.setRange(0,2,true);
        const auto error=device->open(stereo,outputEnabled?stereo:BigInteger{},requestedRate,0);
        if(error.isNotEmpty()) {std::cerr<<"Open: "<<error<<std::endl;++failures;continue;}
        Capture capture;device->start(&capture);pump(1500);
        if(!device->isPlaying()||capture.callbacks<10) {std::cerr<<"Silent endpoint stopped callbacks\n";++failures;}
        // Stop before resetting counters: never race the callback accumulators.
        device->stop();capture.reset();device->start(&capture);
        const auto played=PlaySoundW(wav.getFullPathName().toWideCharPointer(),nullptr,SND_FILENAME|SND_ASYNC|SND_NODEFAULT);
        const auto captureStart = Time::getMillisecondCounterHiRes();
        pump(2300);device->stop();
        const auto duration = (Time::getMillisecondCounterHiRes() - captureStart) / 1000.;
        const auto recordedDuration = capture.frames.load() / device->getCurrentSampleRate();
        if (std::abs(recordedDuration - duration) > .15) { std::cerr << "Capture clock drift: " << recordedDuration << " vs " << duration << std::endl; ++failures; }
        const auto rms=std::sqrt(capture.energy/std::max(1LL,capture.frames.load()));
        std::cout<<"output="<<outputEnabled<<" rate="<<device->getCurrentSampleRate()<<" callbacks="<<capture.callbacks<<" peak="<<capture.peak<<" rms="<<rms<<std::endl;
        if(!played||capture.callbacks<10||capture.peak<0.001f||!std::isfinite(rms))++failures;
        capture.reset();device->start(&capture);pump(1600);device->stop();
        if(capture.callbacks<10||!device->isOpen()) {std::cerr<<"Capture did not survive playback stopping\n";++failures;}
        device->close();
    }
    // Persist/restore the same deviceType and endpoint names used by Settings.
    XmlElement saved("DEVICESETUP");
    saved.setAttribute("deviceType", "Windows Audio (Loopback)");
    saved.setAttribute("audioInputDeviceName", inputs[0]);
    saved.setAttribute("audioOutputDeviceName", outputs[0]);
    saved.setAttribute("audioDeviceRate", 48000.);
    saved.setAttribute("audioDeviceInChans", "11");
    saved.setAttribute("audioDeviceOutChans", "11");
    auto error = manager.initialise(2, 2, &saved, false);
    if (error.isNotEmpty()) { std::cerr << "Restore: " << error << std::endl; ++failures; }
    else {
        auto roundtrip = manager.createStateXml();
        manager.closeAudioDevice();
        if (!roundtrip || manager.initialise(2, 2, roundtrip.get(), false).isNotEmpty()
            || manager.getCurrentAudioDeviceType() != "Windows Audio (Loopback)"
            || manager.getCurrentAudioDevice()->getActiveInputChannels().countNumberOfSetBits() != 2) {
            std::cerr << "Loopback selection did not survive settings restore" << std::endl; ++failures;
        }
        manager.closeAudioDevice();
    }
    // Ordinary WASAPI output still opens after leaving loopback.
    std::unique_ptr<AudioIODevice> normal(shared->createDevice(outputs[0], {}));
    BigInteger stereo; stereo.setRange(0, 2, true);
    if (!normal || normal->open({}, stereo, 48000, 0).isNotEmpty()) ++failures;
    else { Capture capture; normal->start(&capture); pump(500); normal->stop(); if(capture.callbacks < 10)++failures; normal->close(); }
    PlaySoundW(nullptr,nullptr,0);wav.deleteFile();
    std::cout<<"failures="<<failures<<std::endl;return failures?1:0;
}
