#pragma once
#include "EffectsPanel.h"
namespace catlive::eqAnalysisTests {
template<class Test, class Require>
void run(Test test, Require require, const File &directory) {
    test("EQ RTA captures live stereo input and output and survives parameter commits", [&] {
        for (double rate : {44100., 48000.}) {
            auto settings = fxschema::defaults(true), band = object();
            put(settings, "inserted", Array<var>{"EQ"}); put(settings, "eqEnabled", true);
            put(band, "frequency", 1000.); put(band, "gain", 0.); put(band, "q", .707);
            put(band, "type", "bell"); put(band, "enabled", true); put(settings, "bands", Array<var>{band});
            NativeFX fx; fx.prepare(settings, rate);
            auto capture = fx.eqAnalysis("EQ"); require(capture != nullptr, "Live EQ has no RTA capture");
            AudioBuffer<float> signal(2, 1024); int64 position = 0;
            auto render = [&](NativeFX &processor) {
                for (int n=0;n<1024;++n) {
                    const auto value = .1f * std::sin(float((position+n)*MathConstants<double>::twoPi*1000/rate));
                    signal.setSample(0,n,value); signal.setSample(1,n,-value);
                }
                processor.process(signal,1024); position += 1024;
            };
            render(fx); require(capture->serial()==0, "Closed EQ editor still captures PCM");
            capture->addReader(); render(fx); render(fx);
            analysis::Frame frame; require(capture->read(frame), "EQ RTA has no complete frame");
            for (std::size_t n=0;n<analysis::sampleCount;++n)
                require(std::abs(frame.input[0][n]-frame.output[0][n])<1.e-6f, "Flat EQ changed the input captured by RTA");
            auto edited=settings.clone(); put(list(get(edited,"bands")).getReference(0),"gain",6.020599913);
            fx.previewParameters("EQ",NativeFX::parameterPreview("EQ",edited,rate));
            for(int n=0;n<12;++n)render(fx);
            require(capture->read(frame),"EQ preview stopped publishing RTA");
            analysis::Analyzer analyzer; const auto spectrum=analyzer.analyze(&frame,1);
            const auto peak=std::size_t(std::max_element(spectrum.input.begin(),spectrum.input.end())-spectrum.input.begin());
            require(spectrum.input[peak]>-50 && std::abs(spectrum.output[peak]-spectrum.input[peak]-6.0206f)<.15f,
                    "RTA does not show the live EQ gain or opposite-polarity stereo cancelled");
            NativeFX committed; committed.prepare(edited,rate,&fx); committed.adoptDynamicsState(fx);
            require(committed.eqAnalysis("EQ")==capture,"Parameter commit replaced the RTA capture");
            render(committed); require(capture->read(frame),"Committed EQ no longer publishes");
            capture->removeReader(); const auto serial=capture->serial(); render(committed);
            require(capture->serial()==serial,"Last editor close did not disable RTA capture");
            NativeFX offline;offline.prepare(settings,rate,nullptr,true);
            require(!offline.eqAnalysis("EQ"),"Offline export allocated an unused RTA capture");
        }
    });
    test("EQ lower controls edit the selected band live and enforce filter types", [&] {
        fxui::EQGraph graph;graph.setSize(640,360);graph.settings=fxschema::defaults(true);
        Array<var> bands;
        for(double hz:{100.,1000.,10000.}){auto band=object();put(band,"frequency",hz);put(band,"gain",0.);put(band,"q",.707);put(band,"type","bell");bands.add(band);}
        put(graph.settings,"bands",bands);int previews=0,commits=0;
        graph.changed=[&]{++previews;};graph.commit=[&]{++commits;};graph.refreshControls();
        auto *choice=dynamic_cast<ComboBox*>(graph.findChildWithID("eqBand"));
        auto *type=dynamic_cast<ComboBox*>(graph.findChildWithID("eqType"));
        auto *gain=dynamic_cast<Slider*>(graph.findChildWithID("eqGain"));
        auto *frequency=dynamic_cast<Slider*>(graph.findChildWithID("eqFrequency"));
        auto *slope=dynamic_cast<ComboBox*>(graph.findChildWithID("eqSlope"));
        require(choice&&type&&gain&&frequency&&slope,"Missing EQ lower controls");
        choice->setSelectedId(2,sendNotificationSync);require(type->getNumItems()==1,"Middle band offered edge-only filters");
        gain->setValue(6,sendNotificationSync);require(num(list(get(graph.settings,"bands"))[1],"gain")==6&&previews>0&&commits>0,"Gain did not preview and persist the selected band");
        frequency->setValue(1200,sendNotificationSync);require(num(list(get(graph.settings,"bands"))[1],"frequency")==1200,"Frequency edited wrong band");
        choice->setSelectedId(1,sendNotificationSync);type->setSelectedId(2,sendNotificationSync);
        require(str(list(get(graph.settings,"bands"))[0],"type")=="lowCut"&&!gain->isEnabled()&&slope->isVisible(),"Cut band must expose slope and disable gain");
        slope->setSelectedId(48,sendNotificationSync);require(num(list(get(graph.settings,"bands"))[0],"slope")==48,"Slope did not persist");
        auto stream=directory.getChildFile("eq-lower-controls.png").createOutputStream();
        require(stream&&PNGImageFormat().writeImageToStream(graph.createComponentSnapshot(graph.getLocalBounds()),*stream),"Cannot capture lower EQ controls");
    });
    test("EQ graph draws input and output spectra without covering response controls", [&] {
        fxui::EQGraph graph; graph.setSize(640,260); graph.settings=fxschema::defaults(true);
        auto capture=std::make_shared<analysis::Capture>(48000);
        graph.updateAnalysis({capture,{}});
        auto before=graph.createComponentSnapshot(graph.getLocalBounds());
        std::array<float,2048> input{},output{};
        for(std::size_t n=0;n<input.size();++n) {
            input[n]=float(.2*std::sin(double(n)*MathConstants<double>::twoPi*1000/48000));
            output[n]=input[n]*.25f;
        }
        require(capture->begin(input.data(),input.data(),2048),"Visible EQ graph did not subscribe to PCM");
        capture->finish(output.data(),output.data()); graph.updateAnalysis({capture,{}});
        auto after=graph.createComponentSnapshot(graph.getLocalBounds());int changed=0;
        for(int y=20;y<240;++y)for(int x=8;x<632;++x) if(before.getPixelAt(x,y)!=after.getPixelAt(x,y))++changed;
        require(changed>300,"RTA PCM did not change the EQ graph");
        auto stream=directory.getChildFile("eq-rta-input-output.png").createOutputStream();
        require(stream && PNGImageFormat().writeImageToStream(after,*stream),"Cannot capture EQ RTA preview");
        graph.clearAnalysis();require(!capture->begin(input.data(),input.data(),2048),"Hiding EQ retained the RTA subscription");
    });
}
}
