#pragma once
#include "Localization.h"
#include "Session.h"
namespace catlive {
class SpecialTrackControls final : public Component, private Timer {
    uint64 displayedProgramChange=0;
    Session &session;ID id;std::function<void(ID,String)> action;
    TextButton insert{"Insert"},media{localization::translate(String::fromUTF8("Adicionar mídia"))},addText{localization::translate(String::fromUTF8("Adicionar texto"))},settings,patch{"Patch"},copy{"Copy"},scan{"Scan"},mtc{"MTC"},ltc{"LTC"};
    const jaras::Track *track() const {if(auto *s=session.song())for(const auto &t:s->tracks)if(t.id==id)return &t;return nullptr;}
  public:
    SpecialTrackControls(Session &s,ID target,std::function<void(ID,String)> callback):session(s),id(std::move(target)),action(std::move(callback)) {
        setComponentID("specialTrackControls");
        for(auto *b:{&insert,&media,&addText,&settings,&patch,&copy,&scan,&mtc,&ltc}){addChildComponent(*b);b->setWantsKeyboardFocus(false);b->getProperties().set("fontSize",b==&insert?10:12);b->getProperties().set("cornerRadius",b==&insert?3.f:5.f);b->getProperties().set("borderAlpha",.18f);b->getProperties().set("flat",b==&insert);b->setColour(TextButton::buttonColourId,Colours::white.withAlpha(.12f));}
        insert.setComponentID("insertClick");media.setComponentID("insertMedia");addText.setComponentID("insertText");settings.getProperties().set("icon","settings");
        insert.onClick=[this]{action(id,"click");};media.onClick=[this]{action(id,"media");};addText.onClick=[this]{action(id,"text");};settings.onClick=[this]{action(id,"settings");};
        copy.onClick=[this]{action(id,"pcCopyPaste");};
        patch.setComponentID("specialPatch");
        patch.onClick=[this]{const auto *t=track();action(id,t&&t->role.id=="generatedClick"?"clickPatch":"pcPatch");};scan.onClick=[this]{action(id,"pcScan");};startTimerHz(8);
        mtc.onClick=[this]{action(id,"mtc");};ltc.onClick=[this]{action(id,"ltc");};refresh();
    }
    void timerCallback() override {
        const auto *t=track();if(!t || t->role.id!="programChange")return;
        const bool active=session.scanningProgramChange(id);
        const auto packet=session.scannedProgramChangePacket(id);
        if(packet!=displayedProgramChange) {
            displayedProgramChange=packet;
            if(auto *parent=getParentComponent())parent->repaint();
        }
        const bool ready=session.programChangePasteReady || session.selectedProgramMarker()!=nullptr;
        copy.setButtonText(localization::translate(session.programChangePasteReady?"Paste":"Copy"));
        copy.setEnabled(ready);copy.setColour(TextButton::buttonColourId,ready?theme::green:Colours::white.withAlpha(.12f));
        copy.setColour(TextButton::textColourOffId,ready?Colours::black:Colours::white);
        scan.setButtonText(active?localization::translate("Apply"):"Scan");
        scan.setColour(TextButton::buttonColourId,active && (Time::getMillisecondCounter()/450)%2 ? theme::green : Colours::white.withAlpha(.12f));
    }
    void refresh(){const auto *t=track();if(!t)return;const auto mode=t->timecode.value_or(jaras::TimecodeSettings{}).mode;
        for(auto pair:{std::pair<TextButton*,bool>{&mtc,mode=="mtc"},{&ltc,mode=="ltc"}}){pair.first->setColour(TextButton::buttonColourId,pair.second?theme::green:Colours::white.withAlpha(.12f));pair.first->setColour(TextButton::textColourOffId,pair.second?Colours::black:Colours::white);}resized();}
    void resized() override {
        for(auto *b:{&insert,&media,&addText,&settings,&patch,&copy,&scan,&mtc,&ltc})b->setVisible(false);
        const auto *t=track();if(!t)return;const auto &role=t->role.id;
        std::vector<TextButton*> buttons;
        if(role=="programChange")buttons={&patch,&copy,&scan};else if(role=="generatedClick")buttons={&patch,&insert};else if(role=="timecode")buttons={&settings,&mtc,&ltc};else if(role=="video")buttons={&media};
        else if(jaras::isTeleprompterRole(t->role)||role=="chords")buttons={&addText};
        if(getWidth()<100 || jaras::isTeleprompterRole(t->role)){int y=0;for(auto *b:buttons){b->setBounds(0,y,getWidth(),21);b->setVisible(true);y+=24;}}
        else{int x=0;for(auto *b:buttons){int width=(b==&patch||b==&copy||b==&scan)?50:b==&settings?30:(b==&mtc||b==&ltc?38:role=="generatedClick"?47:102);b->setBounds(x,0,width,std::min(24,getHeight()));b->setVisible(true);x+=width+3;}}
    }
};
}
