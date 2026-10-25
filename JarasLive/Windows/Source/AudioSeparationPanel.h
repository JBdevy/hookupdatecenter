#pragma once
#include "Session.h"
#include "ModalSheet.h"
namespace catlive {
class AudioSeparationPanel final : public Component, private Timer {
  public:
    explicit AudioSeparationPanel(Session &owner) : session(owner), progress(displayedProgress) {
        getProperties().set("selfContainedSheet",true);
        getProperties().set("sheetCornerRadius",16.0);
        setComponentID("audioSeparationProgress");setWantsKeyboardFocus(true);
        for(auto *component : std::initializer_list<Component*>{&heading,&status,&progress,&percentage,&cancel})addAndMakeVisible(*component);
        heading.setText("Separation audio",dontSendNotification);heading.setFont(theme::semiboldFont(18));
        heading.setColour(Label::textColourId,Colours::white);
        heading.setJustificationType(Justification::centred);
        status.setFont(theme::font(13));status.setColour(Label::textColourId,theme::secondary);
        status.setJustificationType(Justification::centred);
        percentage.setFont(theme::font(13));percentage.setColour(Label::textColourId,theme::secondary);
        percentage.setJustificationType(Justification::centred);
        progress.setPercentageDisplay(false);
        progress.setColour(ProgressBar::foregroundColourId,theme::green);
        progress.setColour(ProgressBar::backgroundColourId,Colour(0xff121212));
        cancel.setComponentID("cancelAudioSeparation");
        cancel.onClick=[this]{
            if(session.busy){cancelling=true;session.cancelExport();cancel.setEnabled(false);status.setText(String::fromUTF8("Cancelando…"),dontSendNotification);}
            else ModalSheet::dismiss(*this);
        };
        startTimerHz(15);refresh();
    }
    void parentHierarchyChanged()override{if(getParentComponent())refresh();}
    void paint(Graphics &g)override{g.fillAll(theme::background);}
    void resized()override{
        heading.setBounds(24,20,getWidth()-48,30);status.setBounds(24,60,getWidth()-48,44);
        progress.setBounds(24,110,getWidth()-48,6);percentage.setBounds(24,120,getWidth()-48,22);
        cancel.setBounds((getWidth()-100)/2,getHeight()-46,100,28);
    }
    bool keyPressed(const KeyPress &key)override{
        if(key==KeyPress::escapeKey){if(cancel.isEnabled())cancel.triggerClick();return true;}return false;
    }
  private:
    Session &session;double displayedProgress=0;ProgressBar progress;Label heading,status,percentage;
    TextButton cancel{String::fromUTF8("Cancelar")};bool cancelling=false;
    void refresh(){
        ModalSheet::blockDismiss(*this,session.busy);
        displayedProgress=jlimit(0.,1.,session.importProgress);
        progress.setVisible(session.busy);progress.repaint();
        percentage.setVisible(session.busy);percentage.setText(String(roundToInt(displayedProgress*100))+"%",dontSendNotification);
        if(!cancelling)status.setText(session.message,dontSendNotification);
        if(!session.busy){
            stopTimer();cancel.setEnabled(true);
            if(cancelling||session.importProgress>=1){ModalSheet::dismiss(*this);return;}
            cancel.setButtonText(String::fromUTF8("Fechar"));
            status.setText(session.message,dontSendNotification);status.setColour(Label::textColourId,Colours::red);
        }
    }
    void timerCallback()override{refresh();}
};
}
