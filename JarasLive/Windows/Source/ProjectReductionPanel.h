#pragma once
#include "Session.h"
#include "ProjectReduction.h"
#include "ModalSheet.h"
namespace catlive {
class ProjectReductionPanel final : public Component, private Timer {
    struct Rows : ListBoxModel {
        ProjectReductionPanel &owner;bool source;
        Rows(ProjectReductionPanel &p,bool s):owner(p),source(s){}
        int getNumRows() override {return source?(int)owner.sources.size():(int)owner.groups.size();}
        void paintListBoxItem(int row,Graphics &g,int width,int height,bool selected) override {
            if(row<0||row>=getNumRows())return;
            const bool available=!source||owner.availableSource(row);
            if(selected&&available){g.setColour(theme::green.withAlpha(.25f));g.fillRect(0,0,width,height);}
            if(source){
                const juce::Rectangle<float> box(8.f,(height-16.f)*.5f,16.f,16.f);
                g.setColour(selected&&available?theme::green:Colour(0xff242424));g.fillRoundedRectangle(box,4.f);
                g.setColour(available?theme::green:Colour(0xff4a4a4a));g.drawRoundedRectangle(box.reduced(.75f),4.f,available?1.5f:1.f);
                if(selected&&available){Path tick;tick.startNewSubPath(box.getX()+4,box.getY()+8);tick.lineTo(box.getX()+7,box.getY()+11);tick.lineTo(box.getX()+12,box.getY()+5);g.setColour(Colours::white);g.strokePath(tick,PathStrokeType(1.8f));}
            }
            g.setColour(available?Colours::white:theme::secondary);g.setFont(theme::font(13));
            String label=source?text(owner.sources[(size_t)row].name):owner.groups[(size_t)row].name;
            const int inset=source?32:8;g.drawText(label,inset,0,width-inset-8,height,Justification::centredLeft);
        }
        void backgroundClicked(const MouseEvent &) override {owner.finishEditing();}
        void selectedRowsChanged(int) override {if(!owner.refreshing)owner.selectionChanged(source);}
    } leftModel{*this,false},rightModel{*this,true};
    Session &session;std::function<void(std::function<void()>)> save;
    std::vector<jaras::Track> sources;std::vector<projectReduction::Group> groups;
    ListBox left{"Destinos",&leftModel},right{"Origens",&rightModel};
    TextButton remove{"Remover"},create{"+ Create Track"},cancel{"Cancelar"},reduce{"Reduzir"},saveButton{"Salvar"};
    double displayedProgress=0;ProgressBar progressBar{displayedProgress};
    Label status;int editing=-1;bool refreshing=false;
    struct Work{std::atomic<bool> cancel{false};std::atomic<double> progress{0};std::mutex mutex;String message;};std::shared_ptr<Work> work;
    std::unique_ptr<FileChooser> chooser;
    bool needsSave()const{return session.dirty||!session.document.existsAsFile();}
    std::set<ID> selectedSources()const{std::set<ID> ids;for(int i=0;i<right.getSelectedRows().size();i++){int row=right.getSelectedRows()[i];if(row>=0&&row<(int)sources.size())ids.insert(sources[(size_t)row].id);}return ids;}
    bool availableSource(int row)const{
        if(row<0||row>=(int)sources.size())return false;
        for(size_t i=0;i<groups.size();++i)if((int)i!=editing&&groups[i].sources.count(sources[(size_t)row].id))return false;
        return true;
    }
    void selectionChanged(bool source){
        if(source){refreshing=true;for(int row=0;row<(int)sources.size();++row)if(!availableSource(row))right.deselectRow(row);refreshing=false;if(editing>=0)groups[(size_t)editing].sources=selectedSources();}
        else{editing=left.getSelectedRow();refreshing=true;right.deselectAllRows();if(editing>=0)for(int i=0;i<(int)sources.size();i++)if(groups[(size_t)editing].sources.count(sources[(size_t)i].id))right.selectRow(i,true,false);refreshing=false;}
        right.repaint();
    }
    void finishEditing(){
        if(work||editing<0)return;
        refreshing=true;editing=-1;left.deselectAllRows();right.deselectAllRows();refreshing=false;right.repaint();timerCallback();
    }
    void createTrack(){
        if(editing>=0){finishEditing();return;}
        auto selected=selectedSources();if(selected.empty()){status.setText(String::fromUTF8("Selecione as pistas de origem à direita."),dontSendNotification);return;}
        for(const auto &group:groups)for(const auto &id:selected)if(group.sources.count(id)){status.setText(String::fromUTF8("Uma pista de origem só pode pertencer a uma combinação."),dontSendNotification);return;}
        auto *dialog=new AlertWindow("Nome da pista","",MessageBoxIconType::NoIcon);dialog->addTextEditor("name","","Nome");dialog->addButton("Criar",1,KeyPress(KeyPress::returnKey));dialog->addButton("Cancelar",0,KeyPress(KeyPress::escapeKey));
        auto safe=SafePointer<ProjectReductionPanel>(this);
        dialog->enterModalState(true,ModalCallbackFunction::create([safe,dialog,selected](int result){if(!safe||result!=1)return;auto name=dialog->getTextEditorContents("name").trim();if(name.isEmpty())return;projectReduction::Group group;group.name=name;group.sources=selected;safe->groups.push_back(group);safe->refreshing=true;safe->right.deselectAllRows();safe->refreshing=false;safe->left.updateContent();safe->right.repaint();safe->timerCallback();}),true);
    }
    void run(const File &target,const String &format){
        if(needsSave()||work)return;const auto original=session.project();const auto media=session.document.getParentDirectory();const auto definitions=groups;
        work=std::make_shared<Work>();auto state=work;auto safe=SafePointer<ProjectReductionPanel>(this);ModalSheet::blockDismiss(*this,true);timerCallback();
        Thread::launch([safe,state,original,definitions,media,target,format]{String error;try{projectReduction::write(original,definitions,media,target,state->cancel,[state](const projectReduction::Progress &p){std::lock_guard<std::mutex> lock(state->mutex);state->progress=p.fraction;state->message=p.message;},format);}catch(const std::exception &e){error=String::fromUTF8(e.what());}
            MessageManager::callAsync([safe,error,target]{if(!safe)return;safe->work.reset();ModalSheet::blockDismiss(*safe,false);safe->status.setText(error.isEmpty()?String::fromUTF8("Projeto reduzido salvo: ")+target.getFullPathName():error,dontSendNotification);safe->timerCallback();});
        });
    }
    void chooseDestination(const String &format){
        auto safe=SafePointer<ProjectReductionPanel>(this);
        chooser=std::make_unique<FileChooser>("Reduzir projeto",session.document.getSiblingFile(session.document.getFileNameWithoutExtension()+" - Reduzido.jl"),"*.jl",true);
        chooser->launchAsync(FileBrowserComponent::saveMode|FileBrowserComponent::canSelectFiles,[safe,format](const FileChooser &fc){
            if(!safe||fc.getResult()==File{})return;auto chosen=fc.getResult().withFileExtension("jl"),folder=chosen.getParentDirectory();
            if(folder.getFileName()!=chosen.getFileNameWithoutExtension())folder=folder.getChildFile(chosen.getFileNameWithoutExtension());
            safe->run(folder.getChildFile(chosen.getFileName()),format);
        });
    }
    void timerCallback()override{
        const bool editable=!work&&!needsSave();left.setEnabled(editable);right.setEnabled(editable);create.setEnabled(editable);remove.setEnabled(editable&&editing>=0);reduce.setEnabled(editable&&!groups.empty());saveButton.setVisible(needsSave());saveButton.setEnabled(!work&&!session.busy);
        progressBar.setVisible(work!=nullptr);
        if(work){std::lock_guard<std::mutex> lock(work->mutex);displayedProgress=work->progress.load();status.setText(work->message,dontSendNotification);}
        else if(needsSave())status.setText("Salve o projeto antes de reduzir.",dontSendNotification);
    }
public:
    ProjectReductionPanel(Session &s,std::function<void(std::function<void()>)> saveAction):session(s),save(std::move(saveAction)){
        std::set<ID> parents;for(const auto &song:s.project().songs)for(const auto &t:song.tracks)if(t.parentTrackID)parents.insert(*t.parentTrackID);
        for(const auto &song:s.project().songs)for(const auto &t:song.tracks)if(!parents.count(t.id))sources.push_back(t);
        // The ListBoxes were constructed before the source tracks were populated.
        // Refresh their cached row count now that the project snapshot is available.
        left.updateContent();right.updateContent();
        getProperties().set("selfContainedSheet",true);right.setMultipleSelectionEnabled(true);right.setClickingTogglesRowSelection(true);
        for(Component *c:std::initializer_list<Component*>{&left,&right,&create,&remove,&cancel,&reduce,&saveButton,&status,&progressBar})addAndMakeVisible(c);
        for(auto *b:{&create,&remove,&cancel,&reduce,&saveButton})b->getProperties().set("flat",true);
        reduce.setColour(TextButton::buttonColourId,theme::green);status.setColour(Label::textColourId,theme::secondary);status.setJustificationType(Justification::topLeft);progressBar.setColour(ProgressBar::foregroundColourId,theme::green);
        create.onClick=[this]{createTrack();};remove.onClick=[this]{if(editing<0)return;groups.erase(groups.begin()+editing);refreshing=true;editing=-1;left.deselectAllRows();right.deselectAllRows();refreshing=false;left.updateContent();right.repaint();timerCallback();};cancel.onClick=[this]{if(work)work->cancel=true;else ModalSheet::dismiss(*this);};
        auto safe=SafePointer<ProjectReductionPanel>(this);saveButton.onClick=[safe]{if(safe)safe->save([safe]{if(safe)safe->timerCallback();});};
        reduce.onClick=[this,safe]{
            const auto size=projectReduction::estimate(session.project(),groups,session.document.getParentDirectory());
            auto *dialog=new AlertWindow("Formato do projeto reduzido",String::fromUTF8("Tamanho aproximado do projeto, incluindo as mídias copiadas.\nO formato vale para os áudios renderizados; pistas individuais mantêm os arquivos originais. MP3 usa compressão com perda."),MessageBoxIconType::NoIcon);
            StringArray options;for(const String format:{String("WAV"),String("AIFF"),String("MP3")})
                options.add(format+String::fromUTF8(" — ")+(format=="MP3"?String("320 kbps"):String("32-bit float"))+String::fromUTF8(" · estéreo · 48 kHz — ≈ ")+String(size.bytes(format)/1e9,2)+" GB");
            dialog->addComboBox("format",options,"Formato");dialog->getComboBoxComponent("format")->setSelectedItemIndex(0);
            dialog->addButton("Voltar",0,KeyPress(KeyPress::escapeKey));dialog->addButton("Escolher local...",1,KeyPress(KeyPress::returnKey));
            dialog->enterModalState(true,ModalCallbackFunction::create([safe,dialog](int result){
                if(!safe||result!=1)return;const String format=StringArray{"WAV","AIFF","MP3"}[dialog->getComboBoxComponent("format")->getSelectedItemIndex()];
                MessageManager::callAsync([safe,format]{if(!safe)return;safe->chooseDestination(format);});
            }),true);
        };
        startTimerHz(10);timerCallback();
    }
    ~ProjectReductionPanel()override{if(work)work->cancel=true;}
    void mouseDown(const MouseEvent &event)override {if(event.eventComponent==this)finishEditing();}
    void paint(Graphics &g)override{g.fillAll(theme::panel);g.setColour(Colours::white);g.setFont(theme::font(18,true));g.drawText("Reduzir projeto",24,18,getWidth()-48,28,Justification::centredLeft);g.setColour(theme::secondary);g.setFont(theme::font(12));g.drawText(String::fromUTF8("Apenas as pistas escolhidas serão levadas. Áudios separados por região."),24,52,getWidth()-48,24,Justification::centredLeft);}
    void resized()override{const int half=(getWidth()-64)/2;create.setBounds(24,90,150,28);remove.setBounds(180,90,86,28);saveButton.setBounds(getWidth()-110,90,86,28);left.setBounds(24,128,half,getHeight()-238);right.setBounds(40+half,128,half,getHeight()-238);progressBar.setBounds(24,getHeight()-107,getWidth()-48,12);status.setBounds(24,getHeight()-89,getWidth()-48,42);cancel.setBounds(24,getHeight()-44,90,28);reduce.setBounds(getWidth()-114,getHeight()-44,90,28);}
};
}
