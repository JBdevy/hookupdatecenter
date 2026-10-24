#pragma once
#include "TrackInstrumentIcons.h"
#include "ModalSheet.h"
namespace catlive {
class TrackInstrumentPicker final : public Component {
    class Choice final : public Button {
    public:
        const trackIcons::Icon *icon;
        bool selected=false;
        explicit Choice(const trackIcons::Icon *value):Button(value?String::fromUTF8(value->title):String::fromUTF8("Sem ícone")),icon(value) {
            setComponentID(value?String("trackIcon:")+value->id:"trackIcon:none");
        }
        void paintButton(Graphics &g,bool over,bool down) override {
            const auto r=getLocalBounds().toFloat().reduced(1);
            g.setColour(selected?theme::green.withAlpha(.25f):Colours::white.withAlpha(over||down?.12f:.06f));
            g.fillRoundedRectangle(r,5);
            if(selected){g.setColour(theme::green);g.drawRoundedRectangle(r,5,1.5f);}
            const auto artwork=juce::Rectangle<float>(6,6,getWidth()-12.f,38);
            if(icon)trackIcons::draw(g,*icon,artwork);
            else {g.setColour(Colours::white.withAlpha(.35f));Path outline,dashed;outline.addRoundedRectangle(artwork.reduced(7),3);const float dash[]{3,3};PathStrokeType(1).createDashedStroke(dashed,outline,dash,2);g.fillPath(dashed);}
            g.setColour(Colours::white);g.setFont(theme::font(10));
            g.drawFittedText(getName(),4,47,getWidth()-8,17,Justification::centred,1,.7f);
        }
    };
    String trackName;
    std::optional<std::string> value;
    std::function<void(std::optional<std::string>)> save;
    Viewport viewport;
    Component grid;
    OwnedArray<Choice> choices;
    QuietButton cancel{"Cancelar"},apply{"Salvar"};
public:
    TrackInstrumentPicker(String name,std::optional<std::string> initial,std::function<void(std::optional<std::string>)> action)
        :trackName(std::move(name)),value(std::move(initial)),save(std::move(action)) {
        setComponentID("trackInstrumentPicker");setWantsKeyboardFocus(true);
        getProperties().set("selfContainedSheet",true);
        addAndMakeVisible(viewport);viewport.setViewedComponent(&grid,false);viewport.setScrollBarsShown(true,false);viewport.setScrollBarThickness(8);
        auto add=[&](const trackIcons::Icon *icon){auto *choice=choices.add(new Choice(icon));grid.addAndMakeVisible(choice);
            choice->selected=icon?value==icon->id:!value;
            choice->onClick=[this,icon]{value=icon?std::optional<std::string>(icon->id):std::nullopt;
                for(auto *c:choices){c->selected=c->icon?value==c->icon->id:!value;c->repaint();}};
        };
        add(nullptr);for(const auto &icon:trackIcons::catalog())add(&icon);
        for(auto *button:{&cancel,&apply}){addAndMakeVisible(button);button->setColour(TextButton::buttonColourId,theme::accent);}
        cancel.setComponentID("trackIconCancel");apply.setComponentID("trackIconSave");
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        apply.onClick=[this]{auto action=save;auto selected=value;ModalSheet::dismiss(*this);action(selected);};
    }
    ~TrackInstrumentPicker() override {viewport.setViewedComponent(nullptr,false);}
    void paint(Graphics &g) override {
        g.setColour(theme::panel);g.fillRoundedRectangle(getLocalBounds().toFloat(),16);
        g.setColour(Colours::white);g.setFont(theme::semiboldFont(18));g.drawText(String::fromUTF8("Ícone da pista"),22,18,getWidth()-44,26,Justification::centredLeft);
        g.setColour(theme::secondary);g.setFont(theme::font(11));g.drawText(trackName,22,52,getWidth()-44,20,Justification::centredLeft);
    }
    void resized() override {
        viewport.setBounds(22,78,getWidth()-44,std::max(50,getHeight()-146));
        const int width=std::max(1,(viewport.getWidth()-8-5*8)/6);
        grid.setSize(viewport.getWidth()-8,((choices.size()+5)/6)*74);
        for(int i=0;i<choices.size();++i)choices[i]->setBounds((i%6)*(width+8),(i/6)*74,width,66);
        cancel.setBounds(22,getHeight()-50,84,30);apply.setBounds(getWidth()-106,getHeight()-50,84,30);
    }
    bool keyPressed(const KeyPress &key) override {
        if(key==KeyPress::returnKey){apply.onClick();return true;}
        if(key==KeyPress::escapeKey){cancel.onClick();return true;}return false;
    }
};
}
