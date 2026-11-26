#pragma once
#include "ModalSheet.h"
#include "ConfirmationStyle.h"
namespace catlive {
class TimebaseConfirmationPanel final : public Component {
  public:
    TimebaseConfirmationPanel(bool relative, std::function<void()> accept)
        : heading(localization::translate(relative ? "Enable relative timebase?" : "Disable relative timebase?")),
          detail(localization::translate(relative ? "Relative timebase: changing the project BPM adjusts item duration and playback speed to follow the tempo. With Free timebase, changing the project BPM preserves item duration and playback speed. Tempo markers with their own timebase keep their individual settings." : "Free timebase: changing the project BPM changes the grid without stretching or shortening items. Item duration and playback speed are preserved. Tempo markers with their own timebase keep their individual settings.")),
          commit(std::move(accept)) {
        getProperties().set("selfContainedSheet", true);
        getProperties().set("sheetCornerRadius",double(confirmationStyle::radius));
        setComponentID("timebaseConfirmation"); setWantsKeyboardFocus(true);
        addAndMakeVisible(cancel); addAndMakeVisible(apply);
        cancel.setButtonText(localization::translate("Cancel")); cancel.setComponentID("timebaseCancel");
        apply.setButtonText(localization::translate(relative ? "Enable" : "Disable")); apply.setComponentID("timebaseApply");
        for(auto *button:{&cancel,&apply}) {
            button->getProperties().set("flat",true);
            button->getProperties().set("cornerRadius",confirmationStyle::buttonHeight/2.f);
            button->getProperties().set("fontSize",confirmationStyle::buttonSize);
        }
        cancel.setColour(TextButton::buttonColourId,Colour(0xff444444));
        apply.setColour(TextButton::buttonColourId,theme::green);
        apply.setColour(TextButton::textColourOffId,Colours::black);
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        apply.onClick=[this]{auto action=commit;ModalSheet::dismiss(*this);action();};
    }
    int preferredHeight() const {
        TextLayout layout;AttributedString text;text.setFont(theme::font(13));text.append(detail);
        layout.createLayout(text,confirmationStyle::width-2*confirmationStyle::margin);return std::max(240,int(std::ceil(layout.getHeight()))+142);
    }
    void paint(Graphics &g) override {
        confirmationStyle::surface(g,getLocalBounds().toFloat());
        g.setColour(Colours::white);g.setFont(theme::semiboldFont(confirmationStyle::titleSize));
        g.drawFittedText(heading,20,20,getWidth()-40,44,Justification::centredLeft,2,1.f);
        g.setFont(theme::font(13));g.drawFittedText(detail,20,70,getWidth()-40,getHeight()-136,Justification::centredLeft,20,1.f);
    }
    void resized() override {
        const int width=(getWidth()-2*confirmationStyle::margin-confirmationStyle::gap)/2;
        cancel.setBounds(confirmationStyle::margin,getHeight()-50,width,confirmationStyle::buttonHeight);
        apply.setBounds(cancel.getRight()+confirmationStyle::gap,cancel.getY(),width,confirmationStyle::buttonHeight);
    }
    bool keyPressed(const KeyPress &key) override {
        if(key==KeyPress::escapeKey){ModalSheet::dismiss(*this);return true;}
        return false;
    }
  private:
    String heading,detail;std::function<void()> commit;
    QuietButton cancel,apply;
};
}
