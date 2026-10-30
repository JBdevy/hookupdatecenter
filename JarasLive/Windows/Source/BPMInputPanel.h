#pragma once
#include "ModalSheet.h"
namespace catlive {
/// Compact in-window BPM sheet, with the value ready for typing.
class BPMInputPanel final : public Component {
    class InputLook final : public LookAndFeel_V4 {
        void fillTextEditorBackground(Graphics&,int,int,TextEditor&) override {}
        void drawTextEditorOutline(Graphics&,int,int,TextEditor&) override {}
    } inputLook;
    class Choice final : public QuietButton {
      public:
        bool primary=false;
        void paintButton(Graphics &g,bool hover,bool down) override {
            auto colour=primary?Colour(0xff60b746):Colour(0xff505050);
            if(hover)colour=colour.brighter(.08f);if(down)colour=colour.darker(.12f);
            g.setColour(colour);g.fillRoundedRectangle(getLocalBounds().toFloat(),8);
            g.setColour(primary ? Colours::black : Colours::white);g.setFont(theme::font(18));
            g.drawText(getButtonText(),getLocalBounds(),Justification::centred);
        }
    } cancel,apply;
    TextEditor input;
    std::function<void(double)> commit;
    std::function<void(String)> report;
  public:
    ~BPMInputPanel() override {input.setLookAndFeel(nullptr);}
    BPMInputPanel(String value, std::function<void(double)> action, std::function<void(String)> error)
        : commit(std::move(action)), report(std::move(error)) {
        getProperties().set("selfContainedSheet",true);
        getProperties().set("sheetCornerRadius",22.0);
        setComponentID("bpmInputPanel");setWantsKeyboardFocus(true);
        input.setLookAndFeel(&inputLook);apply.primary=true;
        input.setName("BPM");input.setComponentID("bpmValue");input.setFont(theme::font(18));
        input.setInputRestrictions(8,"0123456789.,");input.setSelectAllWhenFocused(true);
        input.setPopupMenuEnabled(false);input.setText(value,false);
        input.setColour(TextEditor::backgroundColourId,Colour(0xff171717));
        input.setColour(TextEditor::focusedOutlineColourId,theme::green);
        input.setIndents(8,4);
        cancel.setButtonText(localization::translate("Cancel"));apply.setButtonText(localization::translate("Apply"));
        cancel.setColour(TextButton::buttonColourId,Colour(0xff505050));
        apply.setColour(TextButton::buttonColourId,theme::green);
        for(auto *button:{&cancel,&apply}){button->getProperties().set("fontSize",18.f);button->setColour(TextButton::textColourOffId,Colours::white);addAndMakeVisible(button);}
        addAndMakeVisible(input);
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        apply.onClick=[this]{
            const double value=input.getText().replaceCharacter(',','.').getDoubleValue();
            if(!std::isfinite(value)||value<60||value>300){if(report)report("Informe um BPM entre 60 e 300.");return;}
            auto action=commit;ModalSheet::dismiss(*this);
            MessageManager::callAsync([action,value]{if(action)action(value);});
        };
        input.onReturnKey=[this]{apply.onClick();};input.onEscapeKey=[this]{cancel.onClick();};
    }
    void focusGained(FocusChangeType) override {input.grabKeyboardFocus();input.selectAll();}
    void paint(Graphics &g) override {
        auto area=getLocalBounds().toFloat().reduced(.5f);
        g.setColour(Colour(0xff202020));g.fillRoundedRectangle(area,22);
        g.setColour(Colour(0xff414141));g.drawRoundedRectangle(area,22,1);
        g.setColour(Colours::white);g.setFont(theme::semiboldFont(18));
        g.drawText("BPM",28,22,getWidth()-56,26,Justification::centredLeft);
        g.setColour(Colour(0xff171717));g.fillRoundedRectangle(input.getBounds().toFloat().expanded(3),12);
        g.setColour(Colour(0xff568d43));g.drawRoundedRectangle(input.getBounds().toFloat().expanded(3),12,4);
    }
    void resized() override {
        input.setBounds(30,68,getWidth()-60,30);
        cancel.setBounds(28,getHeight()-66,116,36);apply.setBounds(getWidth()-128,getHeight()-66,100,36);
    }
    bool keyPressed(const KeyPress &key) override {
        if(key==KeyPress::returnKey){apply.onClick();return true;}
        if(key==KeyPress::escapeKey){cancel.onClick();return true;}return false;
    }
};
}
