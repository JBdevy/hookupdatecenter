#pragma once
#include "Localization.h"
#include "Common.h"
namespace catlive {
class TempoMarkerPanel final : public Component {
  public:
    TempoMarkerPanel(jaras::TimelineMarker value, std::function<void(jaras::TimelineMarker)> save,
                     std::function<void()> dismiss) : marker(std::move(value)), apply(std::move(save)) {
        for (auto *field : {&bpm, &beats, &unit}) {
            addAndMakeVisible(field); field->setFont(theme::font(13));
            field->setSelectAllWhenFocused(true); field->onReturnKey=[this]{commit();};
        }
        bpm.setText(String(marker.tempoBPM.value_or(120)),false);
        beats.setText(String(marker.tempoBeats.value_or(4)),false);
        unit.setText(String(marker.tempoUnit.value_or(4)),false);
        bpm.setName("BPM"); beats.setName("Beats per bar"); unit.setName("Beat unit");
        addAndMakeVisible(timebase); timebase.addItemList({"Global", "Livre", "Relativa"},1);
        const auto base=marker.tempoTimebase.value_or("global");
        timebase.setSelectedId(base=="free"?2:base=="relative"?3:1,dontSendNotification);
        addAndMakeVisible(cancel); addAndMakeVisible(ok);
        cancel.onClick=std::move(dismiss); ok.onClick=[this]{commit();};
    }
    void resized() override {
        bpm.setBounds(52,18,72,26);beats.setBounds(240,18,36,26);unit.setBounds(295,18,36,26);
        timebase.setBounds(108,66,getWidth()-128,26);
        cancel.setBounds(getWidth()-170,116,76,26);ok.setBounds(getWidth()-88,116,68,26);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::background);g.setColour(Colours::white);g.setFont(theme::font(13));
        g.drawText("BPM",20,18,32,26,Justification::centredLeft);
        g.drawText(localization::translate("Compasso"),140,18,95,26,Justification::centredLeft);
        g.drawText("/",280,18,12,26,Justification::centred);
        g.drawText("Base de tempo",20,66,86,26,Justification::centredLeft);
        if(invalid){g.setColour(Colours::red);g.setFont(theme::font(11));g.drawText(String::fromUTF8("Tempo ou compasso inválido."),20,46,370,18,Justification::centredLeft);}
    }
  private:
    jaras::TimelineMarker marker;
    std::function<void(jaras::TimelineMarker)> apply;
    TextEditor bpm,beats,unit; ComboBox timebase; TextButton cancel{localization::translate("Cancelar")},ok{localization::translate("Aplicar")};
    bool invalid=false;
    void commit() {
        const double tempo=bpm.getText().replace(",",".").getDoubleValue();
        const int count=beats.getText().getIntValue(),denominator=unit.getText().getIntValue();
        invalid=!std::isfinite(tempo)||tempo<60||tempo>300||count<1||count>32||denominator<1||denominator>64||(denominator&(denominator-1));
        if(invalid){repaint();return;}
        marker.name="TEMPO";marker.color=0x999999;marker.tempoBPM=tempo;marker.tempoBeats=count;marker.tempoUnit=denominator;
        marker.tempoTimebase=timebase.getSelectedId()==2?"free":timebase.getSelectedId()==3?"relative":"global";
        apply(marker);
    }
};
}
