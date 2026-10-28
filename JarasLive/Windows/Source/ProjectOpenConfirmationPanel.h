#pragma once
#include "ModalSheet.h"
#include "ConfirmationStyle.h"
namespace catlive {
class ProjectOpenConfirmationPanel final : public Component {
    class Choice final : public QuietButton {
      public:
        bool primary = false;
        void paintButton(Graphics &g, bool hover, bool down) override {
            auto colour = primary ? Colour(0xff60b746) : Colour(0xff505052);
            if (hover) colour = colour.brighter(.08f);
            if (down) colour = colour.darker(.12f);
            g.setColour(colour);g.fillRoundedRectangle(getLocalBounds().toFloat(), getHeight() * .5f);
            g.setColour(Colours::white);g.setFont(theme::semiboldFont(confirmationStyle::buttonSize));
            g.drawText(getButtonText(),getLocalBounds().reduced(10,0),Justification::centred);
        }
    } cancel, open;
    String detail;
    std::function<void()> accept, rejected;
    bool accepted = false;
  public:
    ProjectOpenConfirmationPanel(const String &project, std::function<void()> action, std::function<void()> cancelled = {})
        : detail(localization::translate("The current project will be replaced by %@.").replace("%@",project)), accept(std::move(action)), rejected(std::move(cancelled)) {
        getProperties().set("selfContainedSheet",true);
        getProperties().set("sheetCornerRadius",(double)confirmationStyle::radius);
        setComponentID("projectOpenConfirmation");setWantsKeyboardFocus(true);
        cancel.setButtonText(localization::translate("Cancel"));cancel.setComponentID("cancelOpenProject");
        open.setButtonText(localization::translate("Open Project"));open.setComponentID("confirmOpenProject");open.primary=true;
        addAndMakeVisible(cancel);addAndMakeVisible(open);
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        open.onClick=[this]{accepted=true;auto action=accept;ModalSheet::dismiss(*this);MessageManager::callAsync(std::move(action));};
    }
    ~ProjectOpenConfirmationPanel() override { if (!accepted && rejected) rejected(); }
    void paint(Graphics &g) override {
        confirmationStyle::surface(g,getLocalBounds().toFloat());
        g.setColour(Colours::white);g.setFont(theme::semiboldFont(confirmationStyle::titleSize));
        g.drawText(localization::translate("Open another project?"),20,20,getWidth()-40,24,Justification::centredLeft);
        g.setFont(theme::font(confirmationStyle::bodySize));
        g.drawFittedText(detail,20,54,getWidth()-40,getHeight()-116,Justification::topLeft,4,1.f);
    }
    void resized() override {
        const int width=(getWidth()-2*confirmationStyle::margin-confirmationStyle::gap)/2;
        cancel.setBounds(confirmationStyle::margin,getHeight()-52,width,confirmationStyle::buttonHeight);
        open.setBounds(cancel.getRight()+confirmationStyle::gap,cancel.getY(),width,confirmationStyle::buttonHeight);
    }
    bool keyPressed(const KeyPress &key) override {
        if(key==KeyPress::escapeKey){cancel.onClick();return true;}
        if(key==KeyPress::returnKey){open.onClick();return true;}
        return false;
    }
};
}
