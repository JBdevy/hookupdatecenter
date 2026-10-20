#pragma once
#include "ModalSheet.h"
namespace catlive {
// Compact, app-owned notice shared by validation errors and recording warnings.
class ValidationNoticePanel final : public Component {
  public:
    ValidationNoticePanel(String title, String message) : heading(std::move(title)), detail(std::move(message)) {
        getProperties().set("selfContainedSheet",true);
        setComponentID("noticePanel"); setWantsKeyboardFocus(true);
        addAndMakeVisible(ok); ok.setComponentID("noticeOK");
        ok.setColour(TextButton::buttonColourId,theme::green);
        ok.setColour(TextButton::textColourOffId,Colours::black);
        ok.onClick=[this]{ ModalSheet::dismiss(*this); };
    }
    int preferredHeight() const {
        TextLayout layout; AttributedString text;
        text.setFont(theme::font(13)); text.append(localization::translate(detail));
        layout.createLayout(text,368); return std::max(190, int(std::ceil(layout.getHeight()))+130);
    }
    void paint(Graphics &g) override {
        g.setColour(theme::panel); g.fillRoundedRectangle(getLocalBounds().toFloat(),16);
        g.setColour(Colours::white); g.setFont(theme::semiboldFont(18));
        g.drawText(localization::translate(heading),24,22,getWidth()-48,28,Justification::centred);
        g.setFont(theme::font(13));
        g.drawFittedText(localization::translate(detail),24,62,getWidth()-48,getHeight()-128,Justification::centred,20,1.f);
    }
    void resized() override { ok.setBounds((getWidth()-104)/2,getHeight()-50,104,30); }
    bool keyPressed(const KeyPress &key) override {
        if(key==KeyPress::returnKey || key==KeyPress::escapeKey) { ModalSheet::dismiss(*this);return true; }
        return false;
    }
  private:
    String heading,detail;
    QuietButton ok{"OK"};
};
}
