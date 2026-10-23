#pragma once
#include "NativeFX.h"
#include "MP3Writer.h"
#include "TrackCapture.h"
#include "EffectsPanel.h"
#include "MediaCleanup.h"
#include "ProjectMediaRecovery.h"
namespace catlive::dynamicsTests {
template<class Test, class Require>
void run(Test test, Require require, const File &directory) {
    test("CatLive Trigger decodes WAV and renders at exact attack frames across sample rates", [&] {
        const auto folder = directory.getChildFile("trigger-audio"); folder.createDirectory();
        const auto sample = folder.getChildFile("source.wav");
        {
            WavAudioFormat wav; auto stream = sample.createOutputStream();
            std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(), 44100, 2, 24, {}, 0));
            require(writer != nullptr, "Cannot create trigger sample"); stream.release();
            AudioBuffer<float> data(2, 4410);
            for (int n = 0; n < data.getNumSamples(); ++n) { data.setSample(0, n, .25f); data.setSample(1, n, .125f); }
            require(writer->writeFromAudioSampleBuffer(data, 0, data.getNumSamples()), "Cannot write trigger sample");
        }
        const auto path = dynamicsAssets::importSample(sample, folder);
        auto settings = object(); fxui::defaults(settings);
        put(settings, "inserted", Array<var>{"CatLive Trigger"}); put(settings, "triggerEnabled", true);
        auto parameters = get(settings, "trigger"); put(parameters, "samplePath", path); put(parameters, "gain", -6.020599913);
        for (const double rate : {44100., 48000.}) {
            NativeFX fx; fx.prepare(settings, rate, nullptr, false, true, {}, folder);
            require(fx.unsupported.isEmpty(), "Trigger sample was not loaded");
            AudioBuffer<float> input(2, 4096); input.clear(); input.setSample(0, 97, .5f);
            fx.process(input, input.getNumSamples());
            require(input.getMagnitude(0, 0, 97) == 0, "Trigger sounded before the detected attack");
            require(std::abs(input.getSample(0, 97) - .125f) < .001f, "Trigger did not start exactly at the input attack");
            require(std::abs(input.getSample(1, 100) - .0625f) < .001f, "Trigger stereo sample or gain changed");
            require(input.getMagnitude(0, 100, 2000) > .12f, "Trigger did not play its loaded one-shot");
        }
        // Replacing parameters keeps voices and detector phase at the swap boundary.
        NativeFX live; live.prepare(settings, 44100, nullptr, false, true, {}, folder);
        AudioBuffer<float> sustained(2, 4096); sustained.clear();
        for (int n = 0; n < 1000; ++n) sustained.setSample(0,n,.5f);
        live.process(sustained,1000);
        auto updated=settings.clone(); auto updatedParameters=get(updated,"trigger"); put(updatedParameters,"gain",0);
        live.previewDynamics("CatLive Trigger", NativeFX::dynamicsPreview(updated));
        sustained.clear(); sustained.setSample(0,0,.5f); live.process(sustained,1);
        require(std::abs(sustained.getSample(0,0)-.25f)<.001f,"Live preview did not change gain before commit");
        NativeFX prepared; prepared.prepare(updated,44100,&live,false,true,{},folder);
        prepared.adoptDynamicsState(live); live.swap(prepared);
        sustained.clear();for(int n=0;n<4096;++n)sustained.setSample(0,n,.5f);
        live.process(sustained,4096);
        require(std::abs(sustained.getSample(0,0)-.25f)<.001f,"Parameter update lost active sample voice");
        require(sustained.getMagnitude(0,3500,500)<1.e-6f,"Parameter update restarted sample or retriggered sustained input");
        const auto mp3=folder.getChildFile("source.mp3");
        {
            MP3Writer writer(mp3,44100,1,320); AudioBuffer<float> tone(1,4410);
            for(int n=0;n<4410;++n)tone.setSample(0,n,.5f*std::sin(float(n*MathConstants<double>::twoPi*1000/44100)));
            writer.write(tone,4410);writer.finish();
        }
        const auto mp3Path=dynamicsAssets::importSample(mp3,folder); auto mp3Settings=settings.clone();auto mp3Parameters=get(mp3Settings,"trigger");put(mp3Parameters,"samplePath",mp3Path);
        NativeFX mp3FX;mp3FX.prepare(mp3Settings,48000,nullptr,false,true,{},folder);
        sustained.clear();sustained.setSample(0,37,.5f);mp3FX.process(sustained,4096);
        require(mp3FX.unsupported.isEmpty()&&sustained.getMagnitude(0,37,2000)>.2f,"MP3 trigger sample did not decode and play");
        put(settings, "triggerEnabled", false); NativeFX bypass; bypass.prepare(settings, 48000, nullptr, false, true, {}, folder);
        AudioBuffer<float> data(2, 100); data.clear(); data.setSample(0, 2, .7f); bypass.process(data, 100);
        require(std::abs(data.getSample(0, 2) - .7f) < 1.e-6f, "Trigger bypass changed input");
        put(settings, "triggerEnabled", true); parameters = get(settings, "trigger"); put(parameters, "samplePath", "Stems/missing.wav");
        NativeFX missing; missing.prepare(settings, 48000, nullptr, false, true, {}, folder); missing.process(data, 100);
        require(!missing.unsupported.isEmpty() && data.getMagnitude(0, 100) == 0, "Missing sample leaked trigger detector input");
    });
    test("Cat Gate suppresses quiet input and links stereo on loud input", [&] {
        for (const double rate : {44100., 48000.}) {
            auto settings = object(); fxui::defaults(settings); put(settings, "inserted", Array<var>{"Cat Gate"}); put(settings, "gateEnabled", true);
            auto p = get(settings, "gate"); put(p, "threshold", -20); put(p, "attack", 0); put(p, "hold", .01); put(p, "release", .01);
            NativeFX gate; gate.prepare(settings, rate);
            AudioBuffer<float> input(2, 4096);
            for (int n = 0; n < 4096; ++n) { input.setSample(0, n, .001f); input.setSample(1, n, .0005f); }
            gate.process(input, 4096); require(input.getMagnitude(0, 0, 4096) < 1.e-5f, "Gate passed audio below threshold");
            for (int n = 0; n < 4096; ++n) { auto x = .5f * std::sin(float(n * MathConstants<double>::twoPi * 1000 / rate)); input.setSample(0,n,x); input.setSample(1,n,x*.3f); }
            gate.process(input,4096); require(input.getMagnitude(0,0,4096) > .45f, "Gate did not open on loud input");
            for(int n=0;n<4096;++n)require(std::abs(input.getSample(1,n)-input.getSample(0,n)*.3f)<1.e-6f,"Gate changed linked stereo balance");
        }
    });
    test("Dynamics parameter previews reach post-FX recording before release", [&] {
        const auto folder=directory.getChildFile("trigger-audio");
        for(const String kind:{"CatLive Trigger","Cat Gate"}) {
            auto settings=object();fxui::defaults(settings);put(settings,"inserted",Array<var>{kind});fxui::enable(kind,settings,true);
            auto parameters=get(settings,kind=="Cat Gate"?"gate":"trigger");
            if(kind=="CatLive Trigger")put(parameters,"samplePath","Stems/source.wav");
            TrackCapture::Target target;target.track=uuid();target.file=folder.getChildFile(kind=="Cat Gate"?"gate-preview.wav":"trigger-preview.wav");
            target.mediaDirectory=folder;target.effects=settings;target.channels=2;target.postFX=true;
            TrackCapture capture({target},48000,24,120);
            auto preview=settings.clone();auto values=get(preview,kind=="Cat Gate"?"gate":"trigger");
            if(kind=="Cat Gate")put(values,"threshold",0);else put(values,"gain",-6.020599913);
            capture.previewDynamics(target.track,kind,NativeFX::dynamicsPreview(preview));
            std::array<int,128> mapping;mapping.fill(-1);mapping[0]=0;mapping[1]=1;
            AudioBuffer<float> input(2,512);input.clear();input.setSample(0,97,.5f);
            capture.input(input.getArrayOfReadPointers(),2,512,mapping);capture.advance(512);
            const auto takes=capture.finish();require(takes.size()==1,"Recording did not produce take");
            AudioFormatManager formats;registerAudioFormats(formats);std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(takes[0].file));
            require(reader!=nullptr,"Cannot read dynamics take");AudioBuffer<float> recorded(2,512);reader->read(&recorded,0,512,0,true,true);
            if(kind=="Cat Gate")require(recorded.getMagnitude(0,0,512)<1.e-6f,"Recorded gate ignored live threshold preview");
            else require(std::abs(recorded.getSample(0,100)-.125f)<.001f,"Recorded Trigger ignored live gain preview");
        }
    });
    test("Trigger samples remain project media through instances packaging and recovery", [&] {
        auto settings=object();fxui::defaults(settings);put(settings,"inserted",Array<var>{"CatLive Trigger"});put(settings,"triggerEnabled",true);
        auto triggerParameters = get(settings,"trigger"); put(triggerParameters,"samplePath","Stems/kick.wav");
        auto repeated=object();put(repeated,"id","second-trigger");put(repeated,"kind","CatLive Trigger");put(repeated,"settings",settings.clone());
        auto main=object();fxui::defaults(main);put(main,"instances",Array<var>{repeated});put(main,"inserted",Array<var>{"Native:second-trigger"});
        jaras::Project project;project.masterFXJSON=utf8(JSON::toString(main));
        require(mediaCleanup::references(project).count("Stems/kick.wav")==1,"Native instance sample missing from owned media");
        require(projectMediaRecovery::missingPaths(project,directory).contains("Stems/kick.wav"),"Missing trigger sample was not offered for recovery");
        dynamicsAssets::rewrite(project,{{"Stems/kick.wav","Stems/kick (2).wav"}});
        require(mediaCleanup::references(project).count("Stems/kick (2).wav")==1,"Portable package did not rewrite nested trigger media");
        auto preset=fxpresets::capture("CatLive Trigger",settings,"Kick");
        require(str(get(get(preset,"native"),"trigger"),"samplePath").isEmpty(),"Preset retained a path from another project");
        auto newSettings=settings.clone(); auto newTrigger=get(newSettings,"trigger");put(newTrigger,"samplePath","Stems/snare.wav");
        fxpresets::apply("CatLive Trigger",newSettings,preset);
        require(str(get(newSettings,"trigger"),"samplePath")=="Stems/snare.wav","Applying preset replaced project-local sample");
        for(const String kind:{"CatLive Trigger","Cat Gate"}) {
            var values=object();fxui::defaults(values);fxui::enable(kind,values,true);int commits=0;
            CatDynamicsEditor editor(kind,directory,[&]{return values;},[&]{++commits;},[&](String error){require(false,error);});editor.setSize(650,500);
            Slider *slider=nullptr;
            for(auto *child:editor.getChildren()) if(auto *knob=dynamic_cast<fxui::Knob*>(child))
                if(knob->slider.getComponentID()==(kind=="Cat Gate"?"gate_threshold":"trigger_threshold"))slider=&knob->slider;
            require(slider!=nullptr,"Missing dynamics threshold control");slider->setValue(-25,sendNotificationSync);
            require(commits==1&&num(get(values,kind=="Cat Gate"?"gate":"trigger"),"threshold")==-25,"Dynamics editor did not persist its own parameter");
            auto image=editor.createComponentSnapshot(editor.getLocalBounds());auto output=directory.getChildFile(kind=="Cat Gate"?"cat-gate.png":"catlive-trigger.png").createOutputStream();
            require(output&&PNGImageFormat().writeImageToStream(image,*output),"Cannot capture dynamics editor");
        }
    });
}
}
