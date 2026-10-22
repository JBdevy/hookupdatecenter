#pragma once
#include "Common.h"
#include "Localization.h"
#include "../../WindowsNative/Source/StemSeparator.h"
namespace catlive {
namespace stemMix {
inline var defaults() {
    auto mix=object();Array<var> sources;
    for(int i=0;i<5;i++){auto source=object();put(source,"gain",1.);put(source,"mute",false);put(source,"solo",false);sources.add(source);}
    put(mix,"sources",sources);return mix;
}
inline native::stem::Mix decode(const var &value) {
    native::stem::Mix mix;mix.enabled=flag(value,"stemSeparatorEnabled");
    const auto sources=list(get(get(value,"stemMix"),"sources"));
    for(int i=0;i<std::min(5,sources.size());i++){
        mix.gains[size_t(i)]=(float)jlimit(0.,4.,num(sources[i],"gain",1));
        if(flag(sources[i],"mute"))mix.muteMask|=1u<<i;if(flag(sources[i],"solo"))mix.soloMask|=1u<<i;
    }
    return mix;
}
}
// The editor only changes the saved mix; closing it leaves the audio worker alive.
class CatStemEditor final : public Component, private Timer {
    struct FaderLook : LookAndFeel_V4 {
        void drawLinearSlider(Graphics &g,int x,int y,int width,int height,float position,float,float,
                              Slider::SliderStyle,Slider &slider) override {
            const float centre=x+width*.5f;
            const auto tint=slider.findColour(Slider::trackColourId).withMultipliedAlpha(slider.isEnabled()?1.f:.35f);
            g.setColour(Colours::black.withAlpha(.5f));g.fillRoundedRectangle(centre-3,float(y),6,float(height),3);
            g.setColour(tint.withAlpha(.75f));g.fillRoundedRectangle(centre-3,position,6,std::max(1.f,y+height-position),3);
            g.setColour(tint);g.fillRoundedRectangle(centre-18,position-11,36,22,4);
            g.setColour(Colours::black.withAlpha(.7f));g.fillRect(centre-14,position-1,28.f,2.f);
        }
    } look;
    String title, status;
    std::function<var()> read;
    std::function<void(var,bool)> write;
    std::function<native::stem::Status()> report;
    ToggleButton enabled;
    std::array<ParameterSlider,5> gain;
    std::array<QuietButton,5> mute, solo;
    std::array<String,5> names{{"Vocal","Drum","Bass","Guitar","Other"}};
    std::array<Colour,5> colours{{Colour(0xffb68af4),Colour(0xff69ed91),Colour(0xff8e70ca),Colour(0xff45ba91),Colour(0xffaaa0c7)}};
    bool failed=false;
    juce::Rectangle<int> strips()const{return getLocalBounds().reduced(20).withTrimmedTop(58).withTrimmedBottom(58);}
    void change(int index,const Identifier &field,var value,bool commit) {
        auto settings=read();
        if(!get(settings,"stemMix").isObject())put(settings,"stemMix",stemMix::defaults());
        auto sources=list(get(get(settings,"stemMix"),"sources"));
        if(sources.size()!=5)return;
        put(sources[index],field,value);write(settings,commit);refresh();
    }
    void refresh() {
        const auto settings=read();const auto sources=list(get(get(settings,"stemMix"),"sources"));
        const bool active=flag(settings,"stemSeparatorEnabled")&&sources.size()==5;
        enabled.setToggleState(active,dontSendNotification);
        for(int i=0;i<5;++i){
            gain[i].setEnabled(active);mute[i].setEnabled(active);solo[i].setEnabled(active);
            const auto source=i<sources.size()?sources[i]:var();
            if(!gain[i].isMouseButtonDown()){
                const auto value=num(source,"gain",1);
                gain[i].setValue(value<=0?-60:20*std::log10(value),dontSendNotification);
            }
            mute[i].setToggleState(flag(source,"mute"),dontSendNotification);
            solo[i].setToggleState(flag(source,"solo"),dontSendNotification);
        }
        failed=false;
        if(!active)status="Bypass";
        else {
            const auto state=report();failed=state.state=="fault";
            if(failed)status=localization::translate(text(state.error));
            else if(state.state=="pending")status=localization::translate(String::fromUTF8("CatStem pronto. Pare o transporte para ativar a compensação."));
            else if(state.state=="running"||state.state=="priming")status=localization::translate(String::fromUTF8("Tempo real · 5 stems"));
            else status=localization::translate(String::fromUTF8("Preparando CatStem…"));
        }
        repaint();
    }
    void timerCallback()override{refresh();}
public:
    CatStemEditor(String name,std::function<var()> reader,std::function<void(var,bool)> writer,
                  std::function<native::stem::Status()> reporter)
        :title(std::move(name)),read(std::move(reader)),write(std::move(writer)),report(std::move(reporter)) {
        enabled.setButtonText(localization::translate("Enabled"));enabled.setComponentID("catStemEnabled");
        enabled.onClick=[this]{auto settings=read();if(!get(settings,"stemMix").isObject())put(settings,"stemMix",stemMix::defaults());
            put(settings,"stemSeparatorEnabled",enabled.getToggleState());write(settings,true);refresh();};
        addAndMakeVisible(enabled);
        for(int i=0;i<5;++i){
            auto &fader=gain[i];fader.setLookAndFeel(&look);fader.setSliderStyle(Slider::LinearVertical);
            fader.setTextBoxStyle(Slider::NoTextBox,false,0,0);fader.setRange(-60,12,.1);fader.setDoubleClickReturnValue(true,0);
            fader.setColour(Slider::trackColourId,colours[i]);fader.setComponentID("catStemGain"+String(i));fader.setTitle(names[i]);
            fader.onValueChange=[this,i]{const double db=gain[i].getValue();change(i,"gain",db<=-60?0:std::min(4.,std::pow(10.,db/20)),!gain[i].isMouseButtonDown());};
            fader.onDragEnd=[this]{write(read(),true);refresh();};
            addAndMakeVisible(fader);
            for(auto *button:{&mute[i],&solo[i]}){button->setClickingTogglesState(true);addAndMakeVisible(*button);}
            mute[i].setButtonText("M");solo[i].setButtonText("S");
            mute[i].setTitle("Mute "+names[i]);solo[i].setTitle("Solo "+names[i]);
            mute[i].setComponentID("catStemMute"+String(i));solo[i].setComponentID("catStemSolo"+String(i));
            mute[i].setColour(TextButton::buttonOnColourId,theme::liveOffRed);solo[i].setColour(TextButton::buttonOnColourId,theme::yellow);
            for(auto *button:{&mute[i],&solo[i]})button->setColour(TextButton::textColourOnId,Colours::black);
            mute[i].onClick=[this,i]{change(i,"mute",mute[i].getToggleState(),true);};
            solo[i].onClick=[this,i]{change(i,"solo",solo[i].getToggleState(),true);};
        }
        refresh();startTimerHz(2);
    }
    ~CatStemEditor()override{stopTimer();for(auto &fader:gain)fader.setLookAndFeel(nullptr);}
    void paint(Graphics &g) override {
        g.fillAll(theme::background);g.setColour(Colours::white);g.setFont(theme::semiboldFont(19));
        g.drawText(native::stem::effectName,20,12,getWidth()-160,28,Justification::centredLeft);
        g.setColour(theme::secondary);g.setFont(theme::font(11));g.drawText(title,20,42,getWidth()-40,18,Justification::centredLeft);
        const auto area=strips();const float width=float(area.getWidth())/5;
        for(int i=0;i<5;++i){
            auto card=juce::Rectangle<float>(area.getX()+i*width, float(area.getY()),width-8,float(area.getHeight()));
            g.setColour(theme::panel);g.fillRoundedRectangle(card,7);g.setColour(colours[i]);g.setFont(theme::semiboldFont(13));
            g.drawText(names[i],card.withHeight(30),Justification::centred);
            g.setColour(Colours::white);g.setFont(theme::mediumFont(11));
            const auto db=gain[i].getValue();const auto number=db<=-60?String::fromUTF8("−∞ dB"):(db>=0?"+":"")+String(db,1)+" dB";
            g.drawText(number,card.withTop(card.getBottom()-30),Justification::centred);
        }
        g.setColour(failed?theme::liveOffRed:theme::secondary);g.setFont(theme::font(11));
        g.drawFittedText(status,20,getHeight()-65,getWidth()-40,50,Justification::centredLeft,3);
    }
    void resized()override{
        enabled.setBounds(getWidth()-120,14,100,26);const auto area=strips();const int width=area.getWidth()/5;
        for(int i=0;i<5;++i){const int x=area.getX()+i*width;
            mute[i].setBounds(x+width/2-31,area.getY()+32,25,21);solo[i].setBounds(x+width/2+3,area.getY()+32,25,21);
            gain[i].setBounds(x+8,area.getY()+64,std::max(1,width-24),std::max(20,area.getHeight()-98));}
    }
};
}
