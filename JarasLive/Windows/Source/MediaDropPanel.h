#pragma once
#include "ModalSheet.h"
#include "MediaDropLayout.h"
namespace catlive {
class MediaDropPanel final : public Component {
    ToggleButton separate{String::fromUTF8("Uma pista por item")},same{String::fromUTF8("Na mesma pista, em sequência")},stacked{String::fromUTF8("Na mesma pista, iniciando juntos")};
    Label gapLabel{{},String::fromUTF8("Intervalo entre itens (s)")},error;
    TextEditor gap;
    ParameterSlider interval{Slider::LinearHorizontal,Slider::NoTextBox};
    TextButton cancel{String::fromUTF8("Cancelar")},apply{String::fromUTF8("Importar")};
    std::function<void(MediaDropLayout,double)> accepted;
    void update(){bool visible=same.getToggleState();gap.setVisible(visible);gapLabel.setVisible(visible);interval.setVisible(visible);error.setText({},dontSendNotification);error.setVisible(visible);ModalSheet::resizeContent(*this,visible?283:188);}
    void submit(){auto value=gap.getText().trim().replaceCharacter(',','.');char *end=nullptr;double seconds=std::strtod(value.toRawUTF8(),&end);
        if(same.getToggleState()&&(value.isEmpty()||!end||*end||!std::isfinite(seconds)||seconds<0||seconds>60)){error.setText("Informe um intervalo de 0 a 60 segundos.",dontSendNotification);return;}
        auto callback=accepted;const bool sequential=same.getToggleState();const auto layout=sequential?MediaDropLayout::sameTrack:(stacked.getToggleState()?MediaDropLayout::stacked:MediaDropLayout::separateTracks);ModalSheet::dismiss(*this);callback(layout,sequential?seconds:0);
    }
  public:
    explicit MediaDropPanel(std::function<void(MediaDropLayout,double)> callback):accepted(std::move(callback)) {
        setComponentID("mediaDropOptions");separate.setComponentID("mediaDropSeparate");same.setComponentID("mediaDropSame");stacked.setComponentID("mediaDropStacked");gap.setComponentID("mediaDropGap");apply.setComponentID("mediaDropImport");
        for(auto *button:{&separate,&same,&stacked}){addAndMakeVisible(*button);button->setRadioGroupId(1);button->onClick=[this]{update();};}
        separate.setToggleState(true,dontSendNotification);
        for(Component *component:std::initializer_list<Component*>{static_cast<Component*>(&gap),&gapLabel,&interval,&error,&cancel,&apply})addAndMakeVisible(component);
        gap.setText("0");interval.setRange(0,60,1);interval.onValueChange=[this]{gap.setText(String(interval.getValue()),false);};
        gap.onReturnKey=[this]{submit();};gap.onFocusLost=[this]{interval.setValue(jlimit(0.,60.,gap.getText().replaceCharacter(',','.').getDoubleValue()),dontSendNotification);};
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};apply.onClick=[this]{submit();};error.setColour(Label::textColourId,Colours::red);update();
    }
    void resized()override{separate.setBounds(20,15,getWidth()-40,27);same.setBounds(20,48,getWidth()-40,27);stacked.setBounds(20,81,getWidth()-40,27);gapLabel.setBounds(20,124,230,27);gap.setBounds(getWidth()-84,124,64,27);interval.setBounds(20,158,getWidth()-40,25);error.setBounds(20,187,getWidth()-40,36);cancel.setBounds(20,getHeight()-49,90,30);apply.setBounds(getWidth()-110,getHeight()-49,90,30);}
    bool keyPressed(const KeyPress &key)override{if(key==KeyPress::returnKey){submit();return true;}return false;}
};
}
