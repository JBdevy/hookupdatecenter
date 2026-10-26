#pragma once
#include "ModalSheet.h"
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
            g.setColour(Colours::white);g.setFont(theme::semiboldFont(17));
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
        getProperties().set("sheetCornerRadius",38.0);
        setComponentID("projectOpenConfirmation");setWantsKeyboardFocus(true);
        cancel.setButtonText(localization::translate("Cancel"));cancel.setComponentID("cancelOpenProject");
        open.setButtonText(localization::translate("Open Project"));open.setComponentID("confirmOpenProject");open.primary=true;
        addAndMakeVisible(cancel);addAndMakeVisible(open);
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        open.onClick=[this]{accepted=true;auto action=accept;ModalSheet::dismiss(*this);MessageManager::callAsync(std::move(action));};
    }
    ~ProjectOpenConfirmationPanel() override { if (!accepted && rejected) rejected(); }
    void paint(Graphics &g) override {
        const auto bounds=getLocalBounds().toFloat().reduced(.5f);
        g.setGradientFill(ColourGradient(Colour(0xf5373739),0,0,Colour(0xf52e2e30),(float)getWidth(),(float)getHeight(),false));
        g.fillRoundedRectangle(bounds,38);
        g.setColour(Colours::white.withAlpha(.22f));g.drawRoundedRectangle(bounds,38,1);
        g.setColour(Colours::white);g.setFont(theme::semiboldFont(18));
        g.drawText(localization::translate("Open another project?"),34,30,getWidth()-68,28,Justification::centredLeft);
        g.setFont(theme::font(18));g.drawFittedText(detail,34,72,getWidth()-68,getHeight()-146,Justification::topLeft,4,1.f);
    }
    void resized() override {
        const int width=(getWidth()-64)/2;
        cancel.setBounds(24,getHeight()-68,width,44);
        open.setBounds(40+width,getHeight()-68,width,44);
    }
    bool keyPressed(const KeyPress &key) override {
        if(key==KeyPress::escapeKey){cancel.onClick();return true;}
        if(key==KeyPress::returnKey){open.onClick();return true;}
        return false;
    }
};
}
