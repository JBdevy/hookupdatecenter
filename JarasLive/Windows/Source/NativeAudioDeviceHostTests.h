#pragma once
#include "NativeAudioDeviceHost.h"
#include "FloatingControlTests.h"
namespace catlive::nativeAudioDeviceHostTests {
template<class Test> void run(Test& test) {
#if CATLIVE_NATIVE_DEVICE_HOST
    // Opt-in only: this opens a real endpoint, outputs silence and never changes
    // the user's saved device XML. Offline CI must not require audio hardware.
    if(SystemStats::getEnvironmentVariable("CATLIVE_TEST_NATIVE_DEVICE",{})!="1")return;
    test("Native device host bypasses manager lock and retires project callbacks safely",[&] {
        auto host=makeAudioDeviceHost();
        auto error=host->initialise(0,2,nullptr,true);
        if(error.isNotEmpty())throw std::runtime_error(utf8(error));
        auto check=[](bool value,const char* message){if(!value)throw std::runtime_error(message);};
        check(usesNativeAudioDeviceHost(*host),"Native backend was not selected");
        check(host->getCurrentAudioDeviceType()=="Windows Audio","Silent fixture must use shared WASAPI");
        struct Client final:AudioIODeviceCallback {
            std::atomic<unsigned> calls{0},starts{0},stops{0};
            std::atomic<bool> valid{true};
            std::atomic<DWORD> thread{0};
            void audioDeviceAboutToStart(AudioIODevice* device) override {valid= device->getCurrentSampleRate()>0; ++starts;}
            void audioDeviceStopped() override {++stops;}
            void audioDeviceIOCallbackWithContext(const float* const*,int,float* const* outputs,int channels,int frames,const AudioIODeviceCallbackContext&) override {
                thread=GetCurrentThreadId();
                if(frames<=0||channels!=2)valid=false;
                for(int channel=0;channel<channels;++channel)for(int frame=0;frame<frames;++frame)outputs[channel][frame]=0;
                ++calls;
            }
        } first,second;
        struct Registration {
            AudioDeviceManager& host;AudioIODeviceCallback& callback;
            Registration(AudioDeviceManager& h,AudioIODeviceCallback& c):host(h),callback(c){addRealtimeAudioCallback(host,&callback);}
            ~Registration(){removeRealtimeAudioCallback(host,&callback);}
        } registration(*host,first);
        auto pump=[&](unsigned milliseconds){const auto deadline=Time::getMillisecondCounter()+milliseconds;while(Time::getMillisecondCounter()<deadline)floatingControlTests::pump();};
        pump(300);check(first.calls.load()>2&&first.valid,"Native callback never started");
        check(first.thread.load()!=GetCurrentThreadId(),"Audio ran on the control/UI thread");
        const auto before=first.calls.load();
        {const ScopedLock lock(host->getAudioCallbackLock());Thread::sleep(150);}
        check(first.calls.load()>before+2,"Audio still waits for AudioDeviceManager's lock");
        {
            Registration another(*host,second);pump(200);
            check(second.calls.load()>2&&second.valid&&second.starts==1,"Second project was not prepared/admitted");
        }
        const auto retiredCalls=second.calls.load(),remainingCalls=first.calls.load();pump(150);
        check(second.calls.load()==retiredCalls&&first.calls.load()>remainingCalls,"Retired project callback still used or remaining playback stopped");
        check(first.starts==1,"Adding/removing a project restarted the device");
        auto setup=host->getAudioDeviceSetup();host->closeAudioDevice();
        const auto stopped=first.calls.load();pump(60);check(first.calls.load()==stopped,"Device callback continued after close");
        error=host->setAudioDeviceSetup(setup,false);if(error.isNotEmpty())throw std::runtime_error(utf8(error));
        pump(200);check(first.calls.load()>stopped&&first.starts==2,"Native restart did not restore project callbacks");
    });
    test("Native device host clocks duplex capture without feeding input back to speakers",[&] {
        auto host=makeAudioDeviceHost();
        auto error=host->initialise(2,2,nullptr,true);
        if(error.isNotEmpty())throw std::runtime_error(utf8(error));
        auto* device=host->getCurrentAudioDevice();
        if(!device||device->getActiveInputChannels().isZero()||device->getInputLatencyInSamples()<=0)
            throw std::runtime_error("Native duplex capture/latency is missing");
        struct Client final:AudioIODeviceCallback {
            std::atomic<unsigned> blocks{0};std::atomic<bool> valid{true};
            void audioDeviceAboutToStart(AudioIODevice*) override {}
            void audioDeviceStopped() override {}
            void audioDeviceIOCallbackWithContext(const float* const* input,int inputs,float* const* output,int outputs,int frames,const AudioIODeviceCallbackContext&) override {
                if(inputs<1||outputs!=2||frames<1)valid=false;
                for(int channel=0;channel<inputs;++channel)for(int frame=0;frame<frames;++frame)if(!std::isfinite(input[channel][frame]))valid=false;
                for(int channel=0;channel<outputs;++channel)std::fill_n(output[channel],frames,0.f);
                ++blocks;
            }
        } client;
        struct Registration {
            AudioDeviceManager& host;AudioIODeviceCallback& callback;
            Registration(AudioDeviceManager& h,AudioIODeviceCallback& c):host(h),callback(c){addRealtimeAudioCallback(host,&callback);}
            ~Registration(){removeRealtimeAudioCallback(host,&callback);}
        } registration(*host,client);
        const auto deadline=Time::getMillisecondCounter()+600;
        while(Time::getMillisecondCounter()<deadline)floatingControlTests::pump();
        if(client.blocks.load()<10||!client.valid||!device->isPlaying())throw std::runtime_error("Native duplex stopped or supplied invalid capture");
    });
    test("Native device host drives real AudioEngine Stop Play and graph replacement",[&] {
        auto host=makeAudioDeviceHost();
        auto error=host->initialise(0,2,nullptr,true);
        if(error.isNotEmpty())throw std::runtime_error(utf8(error));
        std::vector<std::unique_ptr<AudioEngine>> engines;
        jaras::Song song;song.id=uuid();song.name="Silent native graph qualification";song.duration=60;
        // No microphone monitoring or generated audio in a hardware test.
        for(int i=0;i<3;++i){
            auto engine=std::make_unique<AudioEngine>(48000,false,host);
            engine->liveInputEnabled=false;engine->prepareSong(song,{});
            error=engine->openDevice();if(error.isNotEmpty())throw std::runtime_error(utf8(error));
            engines.push_back(std::move(engine));
        }
        auto pump=[](unsigned ms){const auto end=Time::getMillisecondCounter()+ms;while(Time::getMillisecondCounter()<end)floatingControlTests::pump();};
        for(int pass=0;pass<6;++pass){
            auto& engine=*engines[size_t(pass)%engines.size()];
            AudioEngine::State playing;playing.playing=true;playing.position=double(pass);
            engine.transport(playing);pump(100);
            if(!engine.state().playing||engine.state().position<pass+.02)throw std::runtime_error("Native graph did not advance after Play");
            auto replacement=song;replacement.name="Prepared replacement";
            engine.prepareSong(replacement,{});engine.transport(playing);pump(80);
            if(!engine.state().playing||engine.state().position<pass+.01)throw std::runtime_error("Prepared graph lost native callback ownership");
            playing.playing=false;engine.transport(playing);pump(40);
            if(engine.state().playing)throw std::runtime_error("Native graph did not stop");
        }
        engines.erase(engines.begin()+1);
        AudioEngine::State playing;playing.playing=true;engines.front()->transport(playing);pump(100);
        if(!engines.front()->state().playing||engines.front()->state().position<.02)
            throw std::runtime_error("Destroying another project stopped the remaining native engine");
    });
#else
    (void)test;
#endif
}
}
