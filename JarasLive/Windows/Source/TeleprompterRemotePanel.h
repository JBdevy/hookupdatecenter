#pragma once
#include "Localization.h"
#include "TeleprompterHTTP.h"
#include "ModalSheet.h"
#include "../ThirdParty/QRCode/qrcodegen.hpp"
namespace catlive {
class TeleprompterRemotePanel final : public Component, private Timer {
  public:
    TeleprompterRemotePanel(TeleprompterHTTP &value,int panel) : server(value),index(panel) {
        for(auto *c:std::initializer_list<Component*>{&enabled,&link,&copy,&close})addAndMakeVisible(c);
        enabled.setButtonText(localization::translate("Ativado"));enabled.onClick=[this]{
            try {message.clear();if(server.enabled())server.stop();else server.start(10100+index);}
            catch(const std::exception &e){message=String::fromUTF8(e.what());}refresh();
        };
        link.setReadOnly(true);link.setFont(theme::font(11));link.setPopupMenuEnabled(true);
        copy.onClick=[this]{SystemClipboard::copyTextToClipboard(link.getText());copy.setButtonText(localization::translate("Copiado"));};
        close.onClick=[this]{ModalSheet::dismiss(*this);};
        startTimerHz(2);refresh();
    }
    void resized() override {
        enabled.setBounds(getWidth()-110,8,90,26);
        link.setBounds(20,296,getWidth()-140,30);copy.setBounds(getWidth()-112,296,92,30);
        close.setBounds(getWidth()-90,364,70,26);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        const juce::Rectangle<int> box(getWidth()/2-105,38,210,210);
        if(code){
            g.setColour(Colours::white);g.fillRoundedRectangle(box.toFloat(),6);
            const int count=code->getSize(),scale=std::max(1,190/(count+8));
            const int originX=box.getCentreX()-(count*scale)/2,originY=box.getCentreY()-(count*scale)/2;
            g.setColour(Colours::black);
            for(int y=0;y<count;++y)for(int x=0;x<count;++x)if(code->getModule(x,y))g.fillRect(originX+x*scale,originY+y*scale,scale,scale);
        }else{
            g.setColour(theme::secondary);g.setFont(theme::semiboldFont(18));g.drawText("TP "+String(index),box,Justification::centred);
        }
        g.setColour(theme::secondary);g.setFont(theme::font(11));
        g.drawFittedText(server.enabled()?localization::translate(String::fromUTF8("Abra este link em um dispositivo conectado à mesma rede.")):localization::translate(String::fromUTF8("Ative o TP Remoto para compartilhar o teleprompter.")),20,254,getWidth()-40,34,Justification::centred,2);
        g.setColour(theme::yellow);g.drawFittedText(message,20,332,getWidth()-40,26,Justification::centredLeft,2);
    }
  private:
    TeleprompterHTTP &server;int index;
    ToggleButton enabled;TextEditor link;TextButton copy{localization::translate("Copiar link")},close{localization::translate("Fechar")};
    std::optional<qrcodegen::QrCode> code;String message;
    void timerCallback() override {refresh();}
    void refresh(){
        enabled.setToggleState(server.enabled(),dontSendNotification);
        const auto next=server.link();copy.setEnabled(next.isNotEmpty());
        if(link.getText()!=next){link.setText(next,false);copy.setButtonText(localization::translate("Copiar link"));code.reset();if(next.isNotEmpty())code=qrcodegen::QrCode::encodeText(next.toRawUTF8(),qrcodegen::QrCode::Ecc::MEDIUM);}
        repaint();
    }
};
}
