#pragma once
#include "ModalSheet.h"
namespace catlive {
class MediaDropPanel final : public Component {
    ToggleButton separate{String::fromUTF8("Uma pista por item")},same{String::fromUTF8("Todos os itens na mesma pista")};
    Label gapLabel{{},String::fromUTF8("Intervalo entre itens (s)")},error;
    TextEditor gap;
    ParameterSlider interval{Slider::LinearHorizontal,Slider::NoTextBox};
    TextButton cancel{String::fromUTF8("Cancelar")},apply{String::fromUTF8("Importar")};
    std::function<void(bool,double)> accepted;
    void update(){bool visible=same.getToggleState();gap.setVisible(visible);gapLabel.setVisible(visible);interval.setVisible(visible);error.setText({},dontSendNotification);error.setVisible(visible);ModalSheet::resizeContent(*this,visible?250:155);}
    void submit(){auto value=gap.getText().trim().replaceCharacter(',','.');char *end=nullptr;double seconds=std::strtod(value.toRawUTF8(),&end);
        if(same.getToggleState()&&(value.isEmpty()||!end||*end||!std::isfinite(seconds)||seconds<0||seconds>60)){error.setText("Informe um intervalo de 0 a 60 segundos.",dontSendNotification);return;}
        auto callback=accepted;const bool sequential=same.getToggleState();ModalSheet::dismiss(*this);callback(sequential,sequential?seconds:0);
    }
  public:
    explicit MediaDropPanel(std::function<void(bool,double)> callback):accepted(std::move(callback)) {
        setComponentID("mediaDropOptions");separate.setComponentID("mediaDropSeparate");same.setComponentID("mediaDropSame");gap.setComponentID("mediaDropGap");apply.setComponentID("mediaDropImport");
        for(auto *button:{&separate,&same}){addAndMakeVisible(*button);button->setRadioGroupId(1);button->onClick=[this]{update();};}
        separate.setToggleState(true,dontSendNotification);
        for(Component *component:std::initializer_list<Component*>{static_cast<Component*>(&gap),&gapLabel,&interval,&error,&cancel,&apply})addAndMakeVisible(component);
        gap.setText("0");interval.setRange(0,60,1);interval.onValueChange=[this]{gap.setText(String(interval.getValue()),false);};
        gap.onReturnKey=[this]{submit();};gap.onFocusLost=[this]{interval.setValue(jlimit(0.,60.,gap.getText().replaceCharacter(',','.').getDoubleValue()),dontSendNotification);};
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};apply.onClick=[this]{submit();};error.setColour(Label::textColourId,Colours::red);update();
    }
    void resized()override{separate.setBounds(20,15,getWidth()-40,27);same.setBounds(20,48,getWidth()-40,27);gapLabel.setBounds(20,91,230,27);gap.setBounds(getWidth()-84,91,64,27);interval.setBounds(20,125,getWidth()-40,25);error.setBounds(20,154,getWidth()-40,36);cancel.setBounds(20,getHeight()-49,90,30);apply.setBounds(getWidth()-110,getHeight()-49,90,30);}
    bool keyPressed(const KeyPress &key)override{if(key==KeyPress::returnKey){submit();return true;}return false;}
};
}
