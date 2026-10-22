#pragma once
#include "NativeFX.h"
#include "FXSchema.h"
#include "TrackCapture.h"
namespace catlive::nativePreviewTests {
template<class Test, class Require>
void run(Test test, Require require, const File &directory) {
    auto make = [](const String &kind) {
        auto settings=fxschema::defaults(true); put(settings,"inserted",Array<var>{kind});
        const auto enabled=kind=="EQ"?"eqEnabled":kind=="Compressor"?"compressorEnabled":kind=="Delay"?"delayEnabled":kind=="Reverb"?"reverbEnabled":kind=="Limiter"?"limiterEnabled":"pitchEnabled";
        put(settings,enabled,true); if(kind=="Limiter") {auto limiter=object();put(limiter,"inputGain",0.);put(limiter,"ceiling",-.1);put(limiter,"release",.1);put(settings,"limiter",limiter);} return settings;
    };
    auto tone=[](AudioBuffer<float> &buffer,double rate,int64 start,float level=.1f) {
        for(int ch=0;ch<buffer.getNumChannels();++ch) for(int n=0;n<buffer.getNumSamples();++n)
            buffer.setSample(ch,n,level*std::sin(float((start+n)*MathConstants<double>::twoPi*1000/rate)));
    };
    test("Native EQ drag changes the live response before committing",[&] {
        for(double rate:{44100.,48000.}) {
            auto settings=make("EQ"), band=object();
            put(band,"frequency",1000.);put(band,"gain",0.);put(band,"q",.707);put(band,"type","bell");put(band,"enabled",true);
            put(settings,"bands",Array<var>{band}); NativeFX fx;fx.prepare(settings,rate);
            AudioBuffer<float> input(2,2048);tone(input,rate,0);fx.process(input,2048);
            const auto before=input.getRMSLevel(0,1024,1024);
            auto edited=settings.clone();put(list(get(edited,"bands")).getReference(0),"gain",6.020599913);
            fx.previewParameters("EQ",NativeFX::parameterPreview("EQ",edited,rate));
            tone(input,rate,2048);fx.process(input,2048);
            const auto after=input.getRMSLevel(0,1024,1024);
            require(after/before>1.97f && after/before<2.03f,"EQ gain waited for mouse-up or targeted another instance");
            for(int ch=0;ch<2;++ch)for(int n=0;n<2048;++n)require(std::isfinite(input.getSample(ch,n)),"EQ preview produced nonfinite PCM");
        }
    });
    test("Compressor limiter reverb and pitch parameters are audible before commit",[&] {
        for(const String kind:{"Compressor","Limiter","Reverb"}) {
            auto settings=make(kind);put(settings,"ratio",1.);put(settings,"threshold",0.);
            if(kind=="Reverb")put(settings,"reverbMix",0.);
            NativeFX fx;fx.prepare(settings,48000);AudioBuffer<float> warmup(2,2048);warmup.clear();fx.process(warmup,2048);auto edited=settings.clone();
            if(kind=="Compressor")put(edited,"makeup",-6.020599913);
            else if(kind=="Limiter") {auto p=get(edited,"limiter");put(p,"inputGain",-6.020599913);}
            else put(edited,"reverbMix",100.);
            fx.previewParameters(kind,NativeFX::parameterPreview(kind,edited,48000));
            AudioBuffer<float> data(2,128);for(int ch=0;ch<2;++ch)for(int n=0;n<128;++n)data.setSample(ch,n,.25f);
            fx.process(data,128);
            require(kind=="Reverb" ? data.getMagnitude(0,0,128)<.001f : std::abs(data.getSample(0,64)-.125f)<1.e-5f,
                kind+" preview sample="+String(data.getSample(0,64),8)+" magnitude="+String(data.getMagnitude(0,0,128),8));
        }
        auto settings=make("Pitch");put(settings,"pitchSemitones",0.);NativeFX fx;fx.prepare(settings,48000);
        auto edited=settings.clone();put(edited,"pitchSemitones",12.);fx.previewParameters("Pitch",NativeFX::parameterPreview("Pitch",edited,48000));
        AudioBuffer<float> data(2,1024);int crossings=0;float previous=0;
        for(int block=0;block<64;++block) {tone(data,48000,block*1024);fx.process(data,1024);
            if(block>=32)for(int n=0;n<1024;++n) {const float value=data.getSample(0,n);if(previous<=0 && value>0)++crossings;previous=value;}}
        const double frequency=crossings*48000./(32*1024);
        require(frequency>1900 && frequency<2100,"Pitch preview did not change the running processor from zero semitones");
    });
    test("Native delay preview changes time without erasing the pending echo",[&] {
        for(double rate:{44100.,48000.}) {
            auto settings=make("Delay");put(settings,"delayTime",.1);put(settings,"delayMix",100.);put(settings,"feedback",0.);
            NativeFX fx;fx.prepare(settings,rate);AudioBuffer<float> input(2,512);input.clear();input.setSample(0,0,1);input.setSample(1,0,.5f);fx.process(input,512);
            auto edited=settings.clone();put(edited,"delayTime",.02);
            fx.previewParameters("Delay",NativeFX::parameterPreview("Delay",edited,rate));
            NativeFX committed;committed.prepare(edited,rate,&fx);committed.adoptDynamicsState(fx);
            input.clear();committed.process(input,512);const int at=(int)std::round(rate*.02)-512;
            require(std::abs(input.getSample(0,at)-1)<1.e-6f && std::abs(input.getSample(1,at)-.5f)<1.e-6f,"Delay commit reset echo history or preview did not change delay time");
        }
    });
    test("Native parameter commits preserve the DSP state heard during the drag",[&] {
        for(const String kind:{"EQ","Compressor","Reverb","Limiter","Pitch"}) {
            auto settings=make(kind);
            if(kind=="Pitch")put(settings,"pitchSemitones",3.);
            NativeFX live, reference;live.prepare(settings,48000);reference.prepare(settings,48000);
            AudioBuffer<float> a(2,1024), b(2,1024);
            for(int block=0;block<8;++block) {tone(a,48000,block*1024,.3f);b.makeCopyOf(a);live.process(a,1024);reference.process(b,1024);}
            auto edited=settings.clone();
            if(kind=="EQ") {auto bands=list(get(edited,"bands"));if(!bands.isEmpty())put(bands.getReference(0),"frequency",80.);}
            else if(kind=="Compressor")put(edited,"makeup",-6.);
            else if(kind=="Reverb")put(edited,"reverbMix",70.);
            else if(kind=="Limiter") {auto values=get(edited,"limiter");put(values,"ceiling",-12.);}
            else put(edited,"pitchSemitones",-3.);
            const auto parameters=NativeFX::parameterPreview(kind,edited,48000);
            live.previewParameters(kind,parameters);reference.previewParameters(kind,parameters);
            NativeFX committed;committed.prepare(edited,48000,&live);committed.adoptDynamicsState(live);
            for(int block=8;block<12;++block) {
                tone(a,48000,block*1024,.3f);b.makeCopyOf(a);committed.process(a,1024);reference.process(b,1024);
                for(int ch=0;ch<2;++ch)for(int n=0;n<1024;++n)
                    require(std::isfinite(a.getSample(ch,n)) && std::abs(a.getSample(ch,n)-b.getSample(ch,n))<2.e-6f,"Native FX history changed when releasing its parameter control");
            }
        }
    });
    test("Native FX drag preview reaches post-FX recording before mouse-up",[&] {
        auto settings=make("Compressor");put(settings,"ratio",1.);put(settings,"threshold",0.);put(settings,"makeup",0.);
        TrackCapture::Target target;target.track=uuid();target.file=directory.getChildFile("native-preview-record.wav");target.effects=settings;target.channels=2;target.postFX=true;
        TrackCapture capture({target},48000,24,120);
        auto edited=settings.clone();put(edited,"makeup",-6.020599913);
        capture.previewNativeParameters(target.track,"Compressor",NativeFX::parameterPreview("Compressor",edited,48000));
        std::array<int,128> mapping;mapping.fill(-1);mapping[0]=0;mapping[1]=1;
        AudioBuffer<float> input(2,512);for(int ch=0;ch<2;++ch)for(int n=0;n<512;++n)input.setSample(ch,n,.25f);
        capture.input(input.getArrayOfReadPointers(),2,512,mapping);capture.advance(512);
        const auto takes=capture.finish();require(takes.size()==1,"Recording did not finish");
        AudioFormatManager formats;registerAudioFormats(formats);std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(takes[0].file));
        require(reader!=nullptr,"Cannot read preview recording");AudioBuffer<float> output(2,512);reader->read(&output,0,512,0,true,true);
        require(std::abs(output.getSample(0,256)-.125f)<1.e-5f,"Recording used committed settings instead of live preview");
    });
}
}
