#pragma once
#include "ModalSheet.h"
#include "ConfirmationStyle.h"
namespace catlive {
class ConfirmationPanel final : public Component {
    class Choice final : public QuietButton {
    public:
        bool destructive=false,primary=false;
        void paintButton(Graphics &g,bool over,bool down) override {
            auto fill=destructive?Colour(0xff693c3b):primary?theme::green:Colour(0xff444444);
            if(over)fill=fill.brighter(.08f);if(down)fill=fill.darker(.15f);
            g.setColour(fill);g.fillRoundedRectangle(getLocalBounds().toFloat(),getHeight()/2.f);
            g.setColour(destructive?Colour(0xffff3b30):Colour(0xffdddddd));
            g.setFont(theme::mediumFont(confirmationStyle::buttonSize));
            g.drawFittedText(getButtonText(),getLocalBounds().reduced(8,0),Justification::centred,1);
        }
    } cancel,accept;
    TextLayout titleLayout,messageLayout;
    std::function<void()> done,cancelled;
    bool accepted=false,vertical=false,destructive=false;
public:
    static void show(MessageBoxIconType,const String &title,const String &message,const String &action,const String &cancelTitle,Component *parent,ModalComponentManager::Callback *callback) {
        auto reply=std::shared_ptr<ModalComponentManager::Callback>(callback);
        if(!parent)parent=TopLevelWindow::getActiveTopLevelWindow();
        if(!parent){if(reply)reply->modalStateFinished(0);return;}
        const bool danger=StringArray{"Delete","Excluir","Deletar","Remover","Remove","Parar","Stop"}.contains(action,true);
        auto panel=std::make_unique<ConfirmationPanel>(localization::translate(title),localization::translate(message),localization::translate(action),danger,false,
            [reply]{if(reply)reply->modalStateFinished(1);},[reply]{if(reply)reply->modalStateFinished(0);});
        panel->cancel.setButtonText(localization::translate(cancelTitle));
        const int height=panel->getHeight();
        ModalSheet::open(*parent->getTopLevelComponent(),title,std::move(panel),confirmationStyle::width,height);
    }
    ConfirmationPanel(String title,String message,String action,bool danger,bool stacked,
                      std::function<void()> confirmed,std::function<void()> rejected)
        :done(std::move(confirmed)),cancelled(std::move(rejected)),vertical(stacked),destructive(danger) {
        getProperties().set("selfContainedSheet",true);
        getProperties().set("sheetCornerRadius",double(confirmationStyle::radius));
        setComponentID("confirmationPanel");setWantsKeyboardFocus(true);
        AttributedString heading(title);heading.setFont(theme::semiboldFont(confirmationStyle::titleSize));heading.setColour(Colour(0xffdddddd));
        titleLayout.createLayout(heading,confirmationStyle::width-2*confirmationStyle::margin);
        if(message!=title && message.isNotEmpty()) {
            AttributedString body(message);body.setFont(theme::font(confirmationStyle::bodySize));body.setColour(Colour(0xffdddddd));
            messageLayout.createLayout(body,confirmationStyle::width-2*confirmationStyle::margin);
        }
        cancel.setButtonText(localization::translate("Cancel"));cancel.setComponentID("confirmationCancel");
        accept.setButtonText(action);accept.setComponentID("confirmationAccept");accept.destructive=danger;accept.primary=!danger;
        addAndMakeVisible(cancel);addAndMakeVisible(accept);
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        accept.onClick=[this]{if(accepted)return;accepted=true;auto action=done;ModalSheet::dismiss(*this);if(action)MessageManager::callAsync(std::move(action));};
        const int textHeight=(int)std::ceil(titleLayout.getHeight()+messageLayout.getHeight())+(messageLayout.getHeight()>0?12:0);
        setSize(confirmationStyle::width,2*confirmationStyle::margin+textHeight+20+confirmationStyle::buttonHeight*(vertical?2:1)+(vertical?confirmationStyle::gap:0));
    }
    ~ConfirmationPanel() override {if(!accepted&&cancelled)MessageManager::callAsync(std::move(cancelled));}
    void paint(Graphics &g) override {
        confirmationStyle::surface(g,getLocalBounds().toFloat());
        const float x=confirmationStyle::margin,w=getWidth()-2*x;
        titleLayout.draw(g,{x,x,w,titleLayout.getHeight()});
        if(messageLayout.getHeight()>0)messageLayout.draw(g,{x,x+titleLayout.getHeight()+12,w,messageLayout.getHeight()});
    }
    void resized() override {
        const int x=confirmationStyle::margin,w=getWidth()-2*x,h=confirmationStyle::buttonHeight;
        if(vertical){cancel.setBounds(x,getHeight()-x-h,w,h);accept.setBounds(x,cancel.getY()-confirmationStyle::gap-h,w,h);}
        else {const int half=(w-confirmationStyle::gap)/2;cancel.setBounds(x,getHeight()-x-h,half,h);accept.setBounds(cancel.getRight()+confirmationStyle::gap,cancel.getY(),half,h);}
    }
    bool keyPressed(const KeyPress &key) override {
        if(key==KeyPress::escapeKey){cancel.onClick();return true;}
        if(key==KeyPress::returnKey){if(destructive)cancel.onClick();else accept.onClick();return true;}
        return false;
    }
};
}
