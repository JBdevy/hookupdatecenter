#pragma once
#include "Localization.h"
#include "Appearance.h"
#include "AudioEngine.h"
#include "ModalSheet.h"
namespace catlive {
inline var metronomePreferences(const Appearance &appearance){
    auto value=object();
    for(auto key:{"enabled","preset","mode","gainA","gainB","output","pathA","pathB"}){
        auto fallback=String(key)=="preset"?var("Digital"):String(key)=="gainA"||String(key)=="gainB"?var(-1.):var();
        put(value,Identifier(key),appearance.value("jaras.metronome."+String(key),fallback));
    }
    return value;
}
class MetronomePanel final:public Component {
  public:
    MetronomePanel(Appearance &p,AudioEngine &e):preferences(p),engine(e),settings(metronomePreferences(p)){
        for(auto *c:std::initializer_list<Component*>{&sound,&output,&gainA,&gainB,&close,&status,&fileA,&fileB})addAndMakeVisible(c);
        sound.addItemList({"Digital","Wood","Clave","User"},1);sound.setSelectedId(std::max(1,StringArray{"Digital","Wood","Clave","User"}.indexOf(str(settings,"preset"))+1),dontSendNotification);
        sound.onChange=[this]{change("preset",sound.getText());resized();};
        for(int i=0;i<3;++i){auto *b=modes.add(new TextButton(i==0?String::fromUTF8("A–B"):i==1?String::fromUTF8("Só A"):String::fromUTF8("Só B")));addAndMakeVisible(b);b->setToggleState(i==(int)num(settings,"mode"),dontSendNotification);b->onClick=[this,i]{change("mode",i);for(int n=0;n<3;++n)modes[n]->setToggleState(n==i,dontSendNotification);};}
        auto *device=engine.devices.getCurrentAudioDevice();const int count=device?device->getOutputChannelNames().size():2;
        for(int i=1;i<=count;++i){patches.push_back({i,1});output.addItem("Out "+String(i),(int)patches.size());}
        for(int i=1;i<count;i+=2){patches.push_back({i,2});output.addItem("Out "+String(i)+" / "+String(i+1),(int)patches.size());}
        const auto saved=get(settings,"output");int selected=0;
        for(size_t i=0;i<patches.size();++i)if(patches[i].firstChannel==(int)num(saved,"firstChannel",1)&&patches[i].channelCount==(int)num(saved,"channelCount",2))selected=(int)i+1;
        if(!selected){patches.push_back({(int)num(saved,"firstChannel",1),(int)num(saved,"channelCount",2)});selected=(int)patches.size();output.addItem(String::fromUTF8("Saída salva — Indisponível"),selected);}
        output.setSelectedId(selected,dontSendNotification);output.onChange=[this]{const auto p=patches[(size_t)output.getSelectedId()-1];auto value=object();put(value,"firstChannel",p.firstChannel);put(value,"channelCount",p.channelCount);change("output",value);};
        for(auto *slider:{&gainA,&gainB}){slider->setRange(-60,12,.1);slider->setSliderStyle(Slider::LinearHorizontal);slider->setTextBoxStyle(Slider::TextBoxRight,false,70,26);slider->setTextValueSuffix(" dB");}
        gainA.setValue(num(settings,"gainA",-1),dontSendNotification);gainB.setValue(num(settings,"gainB",-1),dontSendNotification);
        gainA.onDragEnd=[this]{change("gainA",gainA.getValue());};gainB.onDragEnd=[this]{change("gainB",gainB.getValue());};
        gainA.onValueChange=[this]{if(!gainA.isMouseButtonDown())change("gainA",gainA.getValue());};gainB.onValueChange=[this]{if(!gainB.isMouseButtonDown())change("gainB",gainB.getValue());};
        fileA.onClick=[this]{import(true);};fileB.onClick=[this]{import(false);};
        close.onClick=[this]{ModalSheet::dismiss(*this);};status.setFont(theme::font(11));status.setColour(Label::textColourId,theme::yellow);
    }
    void paint(Graphics &g)override{
        g.fillAll(theme::background);g.setColour(Colours::white);g.setFont(theme::font(13));
        for(auto row:std::initializer_list<std::pair<String,int>>{{"Som de click",20},{"Modo de click",64},{localization::translate(String::fromUTF8("Saída")),108},{"Click A",190},{"Click B",234}})g.drawText(localization::translate(row.first),20,row.second,112,28,Justification::centredLeft);
        g.setFont(theme::font(11));g.setColour(theme::secondary);g.drawText(localization::translate(String::fromUTF8("A: primeiro tempo · B: demais tempos")),20,280,getWidth()-40,24,Justification::centredLeft);
    }
    void resized()override{
        sound.setBounds(136,20,getWidth()-156,28);output.setBounds(136,108,getWidth()-156,28);
        for(int i=0;i<3;++i)modes[i]->setBounds(136+i*(getWidth()-156)/3,64,(getWidth()-156)/3,28);
        fileA.setVisible(sound.getText()=="User");fileB.setVisible(sound.getText()=="User");
        fileA.setBounds(136,150,112,26);fileB.setBounds(254,150,112,26);
        gainA.setBounds(94,190,getWidth()-114,28);gainB.setBounds(94,234,getWidth()-114,28);
        status.setBounds(20,308,getWidth()-100,42);close.setBounds(getWidth()-86,getHeight()-38,66,26);
    }
  private:
    Appearance &preferences;AudioEngine &engine;var settings;ComboBox sound,output;OwnedArray<TextButton>modes;ParameterSlider gainA,gainB;
    TextButton close{localization::translate("Fechar")},fileA{"Importar A"},fileB{"Importar B"};Label status;std::vector<jaras::OutputPatch>patches;std::unique_ptr<FileChooser>chooser;
    void change(String key,var value){
        auto next=settings.clone();put(next,Identifier(key),value);
        try{engine.configureMetronome(next);auto result=preferences.set("jaras.metronome."+key,value);if(result.failed())throw std::runtime_error(utf8(result.getErrorMessage()));settings=next;status.setText({},dontSendNotification);}
        catch(const std::exception &e){status.setText(String::fromUTF8(e.what()),dontSendNotification);}
    }
    void import(bool first){
        chooser=std::make_unique<FileChooser>("Som de click",File(),"*.wav;*.aif;*.aiff;*.mp3;*.flac",true);
        chooser->launchAsync(FileBrowserComponent::openMode|FileBrowserComponent::canSelectFiles,[safe=SafePointer<MetronomePanel>(this),first](const FileChooser &fc){
            if(!safe||!fc.getResult().existsAsFile())return;
            try{
                ClickProgram::decode(std::unique_ptr<AudioFormatReader>(safe->engine.formats.createReaderFor(fc.getResult())));
                auto folder=File::getSpecialLocation(File::userApplicationDataDirectory).getChildFile("Hook Developer/CatLive/Metronome");folder.createDirectory();
                auto target=folder.getChildFile(text(uuid())+"-"+fc.getResult().getFileName());if(!fc.getResult().copyFileTo(target))throw std::runtime_error("Não foi possível copiar o som.");
                safe->change(first?"pathA":"pathB",target.getFullPathName());
            }catch(const std::exception &e){safe->status.setText(String::fromUTF8(e.what()),dontSendNotification);}
        });
    }
};
}
