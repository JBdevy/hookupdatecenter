#pragma once
#include "Session.h"
namespace catlive {
class SpecialTrackControls final : public Component {
    Session &session;ID id;std::function<void(ID,String)> action;
    TextButton insert{"Insert"},media{String::fromUTF8("Adicionar mídia")},addText{String::fromUTF8("Adicionar texto")},settings,mtc{"MTC"},ltc{"LTC"};
    const jaras::Track *track() const {if(auto *s=session.song())for(const auto &t:s->tracks)if(t.id==id)return &t;return nullptr;}
  public:
    SpecialTrackControls(Session &s,ID target,std::function<void(ID,String)> callback):session(s),id(std::move(target)),action(std::move(callback)) {
        setComponentID("specialTrackControls");
        for(auto *b:{&insert,&media,&addText,&settings,&mtc,&ltc}){addChildComponent(*b);b->setWantsKeyboardFocus(false);b->getProperties().set("fontSize",b==&insert?10:12);b->getProperties().set("cornerRadius",b==&insert?3.f:5.f);b->getProperties().set("borderAlpha",.18f);b->getProperties().set("flat",b==&insert);b->setColour(TextButton::buttonColourId,Colours::white.withAlpha(.12f));}
        insert.setComponentID("insertClick");media.setComponentID("insertMedia");addText.setComponentID("insertText");settings.getProperties().set("icon","settings");
        insert.onClick=[this]{action(id,"click");};media.onClick=[this]{action(id,"media");};addText.onClick=[this]{action(id,"text");};settings.onClick=[this]{action(id,"settings");};
        mtc.onClick=[this]{action(id,"mtc");};ltc.onClick=[this]{action(id,"ltc");};refresh();
    }
    void refresh(){const auto *t=track();if(!t)return;const auto mode=t->timecode.value_or(jaras::TimecodeSettings{}).mode;
        for(auto pair:{std::pair<TextButton*,bool>{&mtc,mode=="mtc"},{&ltc,mode=="ltc"}}){pair.first->setColour(TextButton::buttonColourId,pair.second?theme::green:Colours::white.withAlpha(.12f));pair.first->setColour(TextButton::textColourOffId,pair.second?Colours::black:Colours::white);}resized();}
    void resized() override {
        for(auto *b:{&insert,&media,&addText,&settings,&mtc,&ltc})b->setVisible(false);
        const auto *t=track();if(!t)return;const auto &role=t->role.id;
        std::vector<TextButton*> buttons;
        if(role=="generatedClick")buttons={&insert};else if(role=="timecode")buttons={&settings,&mtc,&ltc};else if(role=="video")buttons={&media};
        else if(jaras::isTeleprompterRole(t->role)||role=="chords")buttons={&addText};
        if(getWidth()<100 || jaras::isTeleprompterRole(t->role)){int y=0;for(auto *b:buttons){b->setBounds(0,y,getWidth(),21);b->setVisible(true);y+=24;}}
        else{int x=0;for(auto *b:buttons){int width=b==&settings?30:(b==&mtc||b==&ltc?38:role=="generatedClick"?47:102);b->setBounds(x,0,width,std::min(24,getHeight()));b->setVisible(true);x+=width+3;}}
    }
};
}
