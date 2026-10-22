#pragma once
#include "Session.h"
#include "ModalSheet.h"
namespace catlive {
class ClickSoundDesigner final : public Component {
  public:
    ClickSoundDesigner(Session &s, ID target) : session(s), track(std::move(target)) {
        getProperties().set("selfContainedSheet", true);
        for(auto *c:std::initializer_list<Component*>{&choose,&reset,&close,&error}) addAndMakeVisible(c);
        choose.onClick=[this]{selectFile();};
        reset.onClick=[this]{apply({});};
        close.onClick=[this]{ModalSheet::dismiss(*this);};
        error.setFont(theme::font(11));error.setColour(Label::textColourId,Colours::red);
        refresh();
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);g.setColour(theme::green);g.setFont(theme::semiboldFont(13));
        g.drawText("Sound Designer",22,20,getWidth()-44,20,Justification::centredLeft);
        g.setColour(Colours::black.withAlpha(.3f));g.fillRoundedRectangle(22,56,getWidth()-44.f,48,8);
        g.setColour(Colours::white);g.setFont(theme::mediumFont(13));
        g.drawFittedText(sound.isEmpty()?String::fromUTF8("Click padrão"):sound.fromLastOccurrenceOf("/",false,false),34,63,getWidth()-68,34,Justification::centredLeft,2);
        g.setColour(theme::secondary);g.setFont(theme::font(11));
        g.drawFittedText(String::fromUTF8("WAV, AIFF ou MP3. O som escolhido será copiado para a pasta Stems deste projeto."),22,116,getWidth()-44,34,Justification::topLeft,2);
    }
    void resized() override {
        choose.setBounds(22,166,146,26);reset.setBounds(getWidth()-130,166,108,26);
        error.setBounds(22,200,getWidth()-44,36);close.setBounds(getWidth()-88,getHeight()-46,66,26);
    }
  private:
    Session &session; ID track; String sound; bool busy=false;
    TextButton choose{String::fromUTF8("Escolher arquivo…")},reset{String::fromUTF8("Usar padrão")},close{"Fechar"};
    Label error;std::unique_ptr<FileChooser> chooser;
    static ThreadPool &worker(){static ThreadPool pool(1);return pool;}
    void refresh(){
        sound.clear();
        if(const auto *song=session.song())for(const auto &t:song->tracks)if(t.id==track && t.clickSound)sound=text(t.clickSound->path);
        choose.setEnabled(!busy && session.mediaDirectory!=File());reset.setEnabled(!busy && sound.isNotEmpty());close.setEnabled(!busy);repaint();
    }
    bool apply(std::optional<jaras::AudioFile> file){
        try {
            if(session.busy)throw std::runtime_error("Aguarde a operação atual terminar.");
            session.edit([&](jaras::Project &p){
                bool found=false;for(auto &song:p.songs)for(auto &t:song.tracks)if(t.id==track && t.role.id=="generatedClick"){t.clickSound=file;found=true;}
                if(!found)throw std::runtime_error("A pista de Click não existe mais.");
            });
            error.setText({},dontSendNotification);refresh();return true;
        }catch(const std::exception &e){error.setText(String::fromUTF8(e.what()),dontSendNotification);return false;}
    }
    void selectFile(){
        chooser=std::make_unique<FileChooser>(String::fromUTF8("Som de click"),File(),"*.wav;*.aif;*.aiff;*.mp3",true);
        chooser->launchAsync(FileBrowserComponent::openMode|FileBrowserComponent::canSelectFiles,[safe=SafePointer<ClickSoundDesigner>(this)](const FileChooser &fc){
            if(!safe || !fc.getResult().existsAsFile())return;
            const auto source=fc.getResult(),directory=safe->session.mediaDirectory;
            const auto project=safe->session.project().id;
            const auto destination=directory.getChildFile("Stems").getNonexistentChildFile(source.getFileNameWithoutExtension(),source.getFileExtension(),false);
            const String relative="Stems/"+destination.getFileName();
            safe->busy=true;safe->refresh();
            worker().addJob([safe,source,destination,project,relative]{
                String failure;
                try {
                    AudioFormatManager formats;registerAudioFormats(formats);
                    ClickProgram::decode(std::unique_ptr<AudioFormatReader>(formats.createReaderFor(source)));
                    if(destination.getParentDirectory().createDirectory().failed() || !source.copyFileTo(destination))throw std::runtime_error("Não foi possível copiar o som de click.");
                }catch(const std::exception &e){failure=String::fromUTF8(e.what());}
                MessageManager::callAsync([safe,destination,project,relative,failure]{
                    bool applied=false;
                    if(safe){safe->busy=false;
                        if(safe->session.project().id==project && failure.isEmpty())applied=safe->apply(jaras::AudioFile{utf8(relative),{}});
                        else if(failure.isNotEmpty())safe->error.setText(failure,dontSendNotification);
                        safe->refresh();
                    }
                    if(!applied)destination.getParentDirectory().deleteRecursively();
                });
            });
        });
    }
};
}
