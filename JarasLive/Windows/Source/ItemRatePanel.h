#pragma once
#include "Common.h"
#include "Localization.h"
#include "../../Core/Songs/ItemDuration.hpp"
#include <cstdlib>
namespace catlive {
class ItemRatePanel final : public Component {
    jaras::ItemRateSettings settings;
    TextEditor rate,bpm;
    Label rateLabel,bpmLabel,base;
    TextButton reset{"Reset"},rateMinus{String::charToString(0x2212)},ratePlus{"+"},
        bpmMinus{String::charToString(0x2212)},bpmPlus{"+"};
    TextButton cancel{localization::translate("Cancel")},save{localization::translate("Save")};
    std::function<void(double,bool)> commit;
    std::function<void()> close;
    bool inputValid=true,resetTempo=false;
    static std::optional<double> number(String raw) {
        const auto value=raw.trim().replaceCharacter(',','.');const auto* start=value.toRawUTF8();char* end=nullptr;
        const double result=std::strtod(start,&end);
        return end!=start && *end=='\0' && std::isfinite(result)?std::optional<double>{result}:std::nullopt;
    }
    static String offsetText(double value){return std::abs(value)<1e-7?"0":(value>0?"+":String{})+String(value,2);}
    void buttons() {
        save.setEnabled(inputValid&&settings.valid());
        rateMinus.setEnabled(settings.rate-.01>=1./32);ratePlus.setEnabled(settings.rate+.01<=32);
        bpmMinus.setEnabled((settings.baseBPM+settings.bpmOffset()-1)/settings.baseBPM>=1./32);
        bpmPlus.setEnabled((settings.baseBPM+settings.bpmOffset()+1)/settings.baseBPM<=32);
    }
    void refresh(){rate.setText(text(settings.rateText()),false);bpm.setText(offsetText(settings.bpmOffset()),false);inputValid=true;buttons();}
public:
    ItemRatePanel(double initial,double baseBPM,std::function<void(double,bool)> apply,std::function<void()> dismiss)
        :settings(baseBPM,initial),commit(std::move(apply)),close(std::move(dismiss)) {
        for(Component* c:std::initializer_list<Component*>{&rate,&bpm,&rateLabel,&bpmLabel,&base,&reset,&rateMinus,&ratePlus,&bpmMinus,&bpmPlus,&cancel,&save})addAndMakeVisible(c);
        rateLabel.setText("Rate",dontSendNotification);bpmLabel.setText(localization::translate("BPM offset"),dontSendNotification);
        base.setText("Base: "+String(baseBPM,2)+" BPM",dontSendNotification);
        rate.setComponentID("itemRate");bpm.setComponentID("itemRateBPM");
        for(auto* input:{&rate,&bpm}){input->setInputRestrictions(32,"0123456789.,+-");input->onEscapeKey=close;input->onReturnKey=[this]{if(inputValid&&settings.valid())commit(settings.rate,resetTempo);};}
        rate.onTextChange=[this]{const auto value=number(rate.getText());inputValid=bool(value);if(value){settings.rate=*value;bpm.setText(offsetText(settings.bpmOffset()),false);}buttons();};
        bpm.onTextChange=[this]{const auto value=number(bpm.getText());inputValid=bool(value);if(value){settings.setBPMOffset(*value);rate.setText(text(settings.rateText()),false);}buttons();};
        reset.onClick=[this]{settings.reset();resetTempo=true;refresh();};
        rateMinus.onClick=[this]{settings.stepRate(-1);refresh();};ratePlus.onClick=[this]{settings.stepRate(1);refresh();};
        bpmMinus.onClick=[this]{settings.stepBPM(-1);refresh();};bpmPlus.onClick=[this]{settings.stepBPM(1);refresh();};
        cancel.onClick=close;save.onClick=[this]{if(inputValid&&settings.valid())commit(settings.rate,resetTempo);};refresh();
    }
    void resized() override {
        auto area=getLocalBounds().reduced(16);reset.setBounds(area.removeFromTop(28).removeFromRight(80));area.removeFromTop(8);
        auto row=area.removeFromTop(32);rateLabel.setBounds(row.removeFromLeft(80));rateMinus.setBounds(row.removeFromLeft(32));ratePlus.setBounds(row.removeFromRight(32));rate.setBounds(row.reduced(4,0));area.removeFromTop(10);
        row=area.removeFromTop(32);bpmLabel.setBounds(row.removeFromLeft(80));bpmMinus.setBounds(row.removeFromLeft(32));bpmPlus.setBounds(row.removeFromRight(32));bpm.setBounds(row.reduced(4,0));
        base.setBounds(area.removeFromTop(28));auto bottom=area.removeFromBottom(30);cancel.setBounds(bottom.removeFromLeft(90));save.setBounds(bottom.removeFromRight(90));
    }
};
}
