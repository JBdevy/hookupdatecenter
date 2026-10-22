#pragma once
#include "ModalSheet.h"
namespace catlive {
class TimebaseConfirmationPanel final : public Component {
  public:
    TimebaseConfirmationPanel(bool relative, std::function<void()> accept)
        : heading(localization::translate(relative ? "Enable relative timebase?" : "Disable relative timebase?")),
          detail(localization::translate(relative ? "Relative timebase: changing the project BPM adjusts item duration and playback speed to follow the tempo. With Free timebase, changing the project BPM preserves item duration and playback speed. Tempo markers with their own timebase keep their individual settings." : "Free timebase: changing the project BPM changes the grid without stretching or shortening items. Item duration and playback speed are preserved. Tempo markers with their own timebase keep their individual settings.")),
          commit(std::move(accept)) {
        getProperties().set("selfContainedSheet", true);
        setComponentID("timebaseConfirmation"); setWantsKeyboardFocus(true);
        addAndMakeVisible(cancel); addAndMakeVisible(apply);
        cancel.setButtonText(localization::translate("Cancel")); cancel.setComponentID("timebaseCancel");
        apply.setButtonText(localization::translate(relative ? "Enable" : "Disable")); apply.setComponentID("timebaseApply");
        apply.setColour(TextButton::buttonColourId,theme::green);
        apply.setColour(TextButton::textColourOffId,Colours::black);
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        apply.onClick=[this]{auto action=commit;ModalSheet::dismiss(*this);action();};
    }
    int preferredHeight() const {
        TextLayout layout;AttributedString text;text.setFont(theme::font(13));text.append(detail);
        layout.createLayout(text,368);return std::max(240,int(std::ceil(layout.getHeight()))+142);
    }
    void paint(Graphics &g) override {
        g.setColour(theme::panel.withAlpha(.96f));g.fillRoundedRectangle(getLocalBounds().toFloat(),20);
        g.setColour(Colours::white);g.setFont(theme::semiboldFont(17));
        g.drawFittedText(heading,24,20,getWidth()-48,44,Justification::centredLeft,2,1.f);
        g.setFont(theme::font(13));g.drawFittedText(detail,24,70,getWidth()-48,getHeight()-136,Justification::centredLeft,20,1.f);
    }
    void resized() override {
        cancel.setBounds(24,getHeight()-48,(getWidth()-60)/2,30);
        apply.setBounds(cancel.getRight()+12,getHeight()-48,(getWidth()-60)/2,30);
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
