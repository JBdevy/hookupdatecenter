#pragma once
#include "Localization.h"
#include "Session.h"
#include "ProjectReduction.h"
#include "ModalSheet.h"
namespace catlive {
class ProjectReductionPanel final : public Component, public DragAndDropContainer, public DragAndDropTarget, private Timer {
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
        String getNameForRow(int row) override {
            return row<0||row>=getNumRows()?String{}:source?text(owner.sources[(size_t)row].name):owner.groups[(size_t)row].name;
        }
        var getDragSourceDescription(const SparseSet<int> &rows) override {
            if(source || !owner.ready || owner.work || rows.size()!=1)return {};
            const int row=rows[0];if(row<0||row>=getNumRows())return {};
            auto value=object();put(value,"type","catlive-reduction-track");
            put(value,"id",text(owner.groups[(size_t)row].id));return value;
        }
        void backgroundClicked(const MouseEvent &) override {owner.finishEditing();}
        void selectedRowsChanged(int) override {if(!owner.refreshing)owner.selectionChanged(source);}
    } leftModel{*this,false},rightModel{*this,true};
    Session &session;std::function<void(std::function<void()>)> save;
    std::vector<jaras::Track> sources;std::vector<projectReduction::Group> groups;
    ListBox left{"Destinos",&leftModel},right{"Origens",&rightModel};
    TextButton edit{localization::translate("Editar")},remove{localization::translate("Remover")},create{"+ Create Track"},cancel{localization::translate("Cancelar")},reduce{"Reduzir"},saveButton{localization::translate("Salvar")};
    double displayedProgress=0;ProgressBar progressBar{displayedProgress};
    Label status;int editing=-1, insertion=-1;bool refreshing=false,ready=false;
    double draftSaveAt=0;
    const ID projectID;
    int sheetHeight=0;
    bool saveWarning=false;
    struct Work{std::atomic<bool> cancel{false};std::atomic<double> progress{0};std::mutex mutex;String message;};std::shared_ptr<Work> work;
    std::unique_ptr<FileChooser> chooser;
    bool needsSave()const{return session.dirty||session.isSaving()||!session.document.existsAsFile();}
    void persistDraft(){
        if(refreshing || !ready || session.project().id!=projectID)return;
        auto draft=object();Array<var> entries,checked;
        for(const auto &group:groups){auto entry=object();Array<var> ids;for(const auto &id:group.sources)ids.add(text(id));put(entry,"id",text(group.id));put(entry,"name",group.name);put(entry,"sources",ids);entries.add(entry);}
        for(const auto &id:selectedSources())checked.add(text(id));
        put(draft,"groups",entries);put(draft,"checked",checked);
        if(editing>=0&&editing<(int)groups.size())put(draft,"selected",text(groups[(size_t)editing].id));
        session.setReductionDraft(draft);draftSaveAt=Time::getMillisecondCounterHiRes()+400;
    }
    void restoreDraft(){
        if(!session.project().reductionDraftJSON)return;
        const auto draft=JSON::parse(text(*session.project().reductionDraftJSON));
        std::set<ID> available,used,groupIDs;for(const auto &track:sources)available.insert(track.id);
        for(const auto &entry:list(get(draft,"groups"))){
            projectReduction::Group group;group.id=utf8(str(entry,"id"));group.name=str(entry,"name").trim();
            if(group.id.empty()||group.name.isEmpty()||!groupIDs.insert(group.id).second)continue;
            for(const auto &value:list(get(entry,"sources"))){auto id=utf8(value.toString());if(available.count(id)&&used.insert(id).second)group.sources.insert(id);}
            groups.push_back(std::move(group));
        }
        refreshing=true;left.updateContent();right.updateContent();
        for(int i=0;i<(int)groups.size();++i)if(text(groups[(size_t)i].id)==str(draft,"selected")){editing=i;left.selectRow(i);}
        std::set<ID> checked;
        if(editing>=0)checked=groups[(size_t)editing].sources;
        else for(const auto &value:list(get(draft,"checked"))){auto id=utf8(value.toString());if(available.count(id)&&!used.count(id))checked.insert(id);}
        for(int i=0;i<(int)sources.size();++i)if(checked.count(sources[(size_t)i].id))right.selectRow(i,true,false);
        refreshing=false;
    }
    std::set<ID> selectedSources()const{std::set<ID> ids;for(int i=0;i<right.getSelectedRows().size();i++){int row=right.getSelectedRows()[i];if(row>=0&&row<(int)sources.size())ids.insert(sources[(size_t)row].id);}return ids;}
    bool availableSource(int row)const{
        if(row<0||row>=(int)sources.size())return false;
        for(size_t i=0;i<groups.size();++i)if((int)i!=editing&&groups[i].sources.count(sources[(size_t)row].id))return false;
        return true;
    }
    void selectionChanged(bool source){
        if(source){refreshing=true;for(int row=0;row<(int)sources.size();++row)if(!availableSource(row))right.deselectRow(row);refreshing=false;if(editing>=0)groups[(size_t)editing].sources=selectedSources();}
        else{editing=left.getSelectedRow();refreshing=true;right.deselectAllRows();if(editing>=0)for(int i=0;i<(int)sources.size();i++)if(groups[(size_t)editing].sources.count(sources[(size_t)i].id))right.selectRow(i,true,false);refreshing=false;}
        right.repaint();persistDraft();timerCallback();
    }
    void finishEditing(){
        if(work||editing<0)return;
        refreshing=true;editing=-1;left.deselectAllRows();right.deselectAllRows();refreshing=false;right.repaint();persistDraft();timerCallback();
    }
    void nameTrack(bool rename){
        if(!ready||work)return;
        if(rename && (editing<0||editing>=(int)groups.size()))return;
        if(!rename && editing>=0){finishEditing();return;}
        const auto selected=selectedSources();
        if(!rename&&selected.empty()){status.setText(localization::translate(String::fromUTF8("Selecione as pistas de origem à direita.")),dontSendNotification);return;}
        const auto target=rename?std::optional<ID>(groups[(size_t)editing].id):std::nullopt;
        String initial;
        if(target)initial=groups[(size_t)editing].name;
        else if(selected.size()==1)for(const auto &track:sources)if(selected.count(track.id))initial=text(track.name);
        auto *dialog=new AlertWindow(localization::translate("Nome da pista"),"",MessageBoxIconType::NoIcon,this);
        dialog->addTextEditor("name",initial,localization::translate("Nome"));
        dialog->addButton(localization::translate(rename?"Salvar":"Criar"),1,KeyPress(KeyPress::returnKey));
        dialog->addButton(localization::translate("Cancelar"),0,KeyPress(KeyPress::escapeKey));
        auto safe=SafePointer<ProjectReductionPanel>(this);
        dialog->enterModalState(true,ModalCallbackFunction::create([safe,dialog,selected,target](int result){
            if(!safe||result!=1||safe->session.project().id!=safe->projectID)return;
            auto name=dialog->getTextEditorContents("name").trim();if(name.isEmpty())return;
            if(target){for(auto &group:safe->groups)if(group.id==*target)group.name=name;}
            else{projectReduction::Group group;group.name=name;group.sources=selected;safe->groups.push_back(group);safe->refreshing=true;safe->right.deselectAllRows();safe->refreshing=false;}
            safe->left.updateContent();safe->left.repaint();safe->right.repaint();safe->persistDraft();safe->timerCallback();
        }),true);
        MessageManager::callAsync([weak=SafePointer<AlertWindow>(dialog)]{
            if(!weak)return;auto *field=weak->getTextEditor("name");field->grabKeyboardFocus();field->selectAll();
        });
    }
    void run(const File &target,const ExportEncoding &encoding){
        if(work||!ready)return;
        if(needsSave()){auto safe=SafePointer<ProjectReductionPanel>(this);save([safe,target,encoding]{if(safe)safe->run(target,encoding);});return;}
        const auto original=session.project();const auto media=session.document.getParentDirectory();const auto definitions=groups;
        work=std::make_shared<Work>();auto state=work;auto safe=SafePointer<ProjectReductionPanel>(this);ModalSheet::blockDismiss(*this,true);timerCallback();
        Thread::launch([safe,state,original,definitions,media,target,encoding]{String error;try{projectReduction::write(original,definitions,media,target,state->cancel,[state](const projectReduction::Progress &p){std::lock_guard<std::mutex> lock(state->mutex);state->progress=p.fraction;state->message=p.message;},encoding.format,std::nullopt,encoding.bits,encoding.rate,encoding.bitrate);}catch(const std::exception &e){error=String::fromUTF8(e.what());}
            MessageManager::callAsync([safe,error,target]{if(!safe)return;safe->work.reset();ModalSheet::blockDismiss(*safe,false);safe->status.setText(error.isEmpty()?String::fromUTF8("Projeto reduzido salvo: ")+target.getFullPathName():error,dontSendNotification);safe->timerCallback();});
        });
    }
    static ExportEncoding readEncoding(AlertWindow &dialog){
        ExportEncoding result;result.format=dialog.getComboBoxComponent("format")->getText();
        result.bits=dialog.getComboBoxComponent("bits")->getText().getIntValue();
        result.rate=dialog.getComboBoxComponent("rate")->getSelectedItemIndex()==0?44100:48000;
        result.bitrate=dialog.getComboBoxComponent("bitrate")->getText().getIntValue();result.floatingPoint=result.bits==32;
        return result;
    }
    void chooseDestination(const ExportEncoding &encoding){
        auto safe=SafePointer<ProjectReductionPanel>(this);
        chooser=std::make_unique<FileChooser>("Reduzir projeto",session.document.getSiblingFile(session.document.getFileNameWithoutExtension()+" - Reduzido.jl"),"*.jl",true);
        chooser->launchAsync(FileBrowserComponent::saveMode|FileBrowserComponent::canSelectFiles,[safe,encoding](const FileChooser &fc){
            if(!safe||fc.getResult()==File{})return;auto chosen=fc.getResult().withFileExtension("jl"),folder=chosen.getParentDirectory();
            if(folder.getFileName()!=chosen.getFileNameWithoutExtension())folder=folder.getChildFile(chosen.getFileNameWithoutExtension());
            safe->run(folder.getChildFile(chosen.getFileName()),encoding);
        });
    }
    void timerCallback()override{
        if(!ready&&!needsSave())ready=true;
        const bool editable=ready&&!work;
        for(Component *c:std::initializer_list<Component*>{&left,&right,&create,&edit,&remove,&reduce})c->setVisible(ready);
        left.setEnabled(editable);right.setEnabled(editable);create.setEnabled(editable);
        edit.setEnabled(editable&&editing>=0);remove.setEnabled(editable&&editing>=0);reduce.setEnabled(editable&&!groups.empty());
        saveButton.setVisible(!ready);saveButton.setEnabled(!session.busy&&!session.isSaving());
        saveButton.setButtonText(localization::translate(session.isSaving()?"Salvando…":"Salvar"));
        progressBar.setVisible(work!=nullptr);
        if(work){std::lock_guard<std::mutex> lock(work->mutex);displayedProgress=work->progress.load();status.setText(work->message,dontSendNotification);}
        else if(!ready){status.setText(localization::translate("Salve o projeto antes de reduzir."),dontSendNotification);saveWarning=true;}
        else if(saveWarning){status.setText({},dontSendNotification);saveWarning=false;}
        const int height=ready?560:206;
        if(sheetHeight!=height){sheetHeight=height;ModalSheet::resizeContent(*this,height);resized();repaint();}
        if(draftSaveAt>0&&Time::getMillisecondCounterHiRes()>=draftSaveAt&&!session.isSaving()){
            draftSaveAt=0;session.saveReductionDraft();
        }
    }
public:
    ProjectReductionPanel(Session &s,std::function<void(std::function<void()>)> saveAction):session(s),save(std::move(saveAction)),projectID(s.project().id){
        std::set<ID> parents;for(const auto &song:s.project().songs)for(const auto &t:song.tracks)if(t.parentTrackID)parents.insert(*t.parentTrackID);
        for(const auto &song:s.project().songs)for(const auto &t:song.tracks)if(!parents.count(t.id))sources.push_back(t);
        // The ListBoxes were constructed before the source tracks were populated.
        // Refresh their cached row count now that the project snapshot is available.
        left.updateContent();right.updateContent();
        getProperties().set("selfContainedSheet",true);right.setMultipleSelectionEnabled(true);right.setClickingTogglesRowSelection(true);
        for(Component *c:std::initializer_list<Component*>{&left,&right,&create,&edit,&remove,&cancel,&reduce,&saveButton,&status,&progressBar})addAndMakeVisible(c);
        for(auto *b:{&create,&edit,&remove,&cancel,&reduce,&saveButton})b->getProperties().set("flat",true);
        reduce.setColour(TextButton::buttonColourId,theme::green);
        reduce.setColour(TextButton::textColourOffId,Colours::black);reduce.setColour(TextButton::textColourOnId,Colours::black);
        left.setComponentID("reductionDestinations");right.setComponentID("reductionSources");
        create.setComponentID("reductionCreate");edit.setComponentID("reductionEdit");remove.setComponentID("reductionRemove");saveButton.setComponentID("reductionSave");reduce.setComponentID("reductionApply");
        status.setColour(Label::textColourId,theme::secondary);status.setJustificationType(Justification::topLeft);progressBar.setColour(ProgressBar::foregroundColourId,theme::green);
        create.onClick=[this]{nameTrack(false);};edit.onClick=[this]{nameTrack(true);};remove.onClick=[this]{if(editing<0)return;groups.erase(groups.begin()+editing);refreshing=true;editing=-1;left.deselectAllRows();right.deselectAllRows();refreshing=false;left.updateContent();right.repaint();persistDraft();timerCallback();};cancel.onClick=[this]{if(work)work->cancel=true;else ModalSheet::dismiss(*this);};
        auto safe=SafePointer<ProjectReductionPanel>(this);saveButton.onClick=[safe]{if(safe)safe->save([safe]{if(safe)safe->timerCallback();});};
        reduce.onClick=[this,safe]{
            const auto size=projectReduction::estimate(session.project(),groups,session.document.getParentDirectory());
            auto *dialog=new AlertWindow("Formato do projeto reduzido",String::fromUTF8("Tamanho aproximado do projeto, incluindo as mídias copiadas.\nO formato vale para os áudios renderizados; pistas individuais mantêm os arquivos originais. MP3 usa compressão com perda."),MessageBoxIconType::NoIcon);
            dialog->addComboBox("format",StringArray{"WAV","AIFF","MP3"},"Formato");
            dialog->addComboBox("bits",StringArray{"16-bit","24-bit","32-bit float"},"Bits");
            dialog->addComboBox("rate",StringArray{"44.100 Hz","48.000 Hz"},String::fromUTF8("Frequência"));
            dialog->addComboBox("bitrate",StringArray{"128 kbps","160 kbps","192 kbps","224 kbps","256 kbps","320 kbps"},"Bitrate MP3");
            dialog->getComboBoxComponent("format")->setSelectedItemIndex(0,dontSendNotification);
            dialog->getComboBoxComponent("bits")->setSelectedItemIndex(2,dontSendNotification);
            dialog->getComboBoxComponent("rate")->setSelectedItemIndex(1,dontSendNotification);
            dialog->getComboBoxComponent("bitrate")->setSelectedItemIndex(5,dontSendNotification);
            auto update=[dialog,size]{
                const auto encoding=readEncoding(*dialog);
                dialog->getComboBoxComponent("bits")->setEnabled(encoding.format!="MP3");
                dialog->getComboBoxComponent("bitrate")->setEnabled(encoding.format=="MP3");
                String message=String::fromUTF8("Tamanho estimado do projeto, incluindo mídias copiadas:\n");
                for(const String format:{String("WAV"),String("AIFF"),String("MP3")})message+=format+String::fromUTF8(": ≈ ")+String(size.bytes(format,encoding.bits,encoding.rate,encoding.bitrate)/1e9,2)+" GB\n";
                message+=String::fromUTF8("Pistas individuais sem renderização mantêm os arquivos originais. MP3 usa compressão com perda.");
                dialog->setMessage(message);
            };
            for(const String field:{String("format"),String("bits"),String("rate"),String("bitrate")})dialog->getComboBoxComponent(field)->onChange=update;
            update();
            dialog->addButton("Voltar",0,KeyPress(KeyPress::escapeKey));dialog->addButton("Escolher local...",1,KeyPress(KeyPress::returnKey));
            dialog->enterModalState(true,ModalCallbackFunction::create([safe,dialog](int result){
                if(!safe||result!=1)return;const auto encoding=readEncoding(*dialog);
                MessageManager::callAsync([safe,encoding]{if(!safe)return;safe->chooseDestination(encoding);});
            }),true);
        };
        restoreDraft();startTimerHz(10);timerCallback();
    }
    ~ProjectReductionPanel()override{if(work)work->cancel=true;if(draftSaveAt>0&&session.project().id==projectID)session.saveReductionDraft();}
    void mouseDown(const MouseEvent &event)override {if(event.eventComponent==this)finishEditing();}
    bool isInterestedInDragSource(const SourceDetails &details)override{
        return ready&&!work&&details.sourceComponent==&left&&str(details.description,"type")=="catlive-reduction-track";
    }
    void itemDragEnter(const SourceDetails &details)override{itemDragMove(details);}
    void itemDragMove(const SourceDetails &details)override{
        const auto point=left.getLocalPoint(this,details.localPosition);
        insertion=isInterestedInDragSource(details)&&left.getLocalBounds().contains(point)
            ?std::clamp(left.getInsertionIndexForPosition(point.x,point.y),0,(int)groups.size()):-1;
        if(insertion>=0){const auto inViewport=left.getViewport()->getLocalPoint(&left,point);left.getViewport()->autoScroll(inViewport.x,inViewport.y,24,8);}
        repaint();
    }
    void itemDragExit(const SourceDetails &)override{insertion=-1;repaint();}
    void itemDropped(const SourceDetails &details)override{
        itemDragMove(details);const int at=insertion;insertion=-1;repaint();if(at<0)return;
        const auto id=utf8(str(details.description,"id"));
        const auto found=std::find_if(groups.begin(),groups.end(),[&](const auto &group){return group.id==id;});
        if(found==groups.end())return;
        const auto selected=editing>=0?std::optional<ID>(groups[(size_t)editing].id):std::nullopt;
        const int from=(int)std::distance(groups.begin(),found),to=at-(from<at?1:0);
        if(from==to)return;
        auto moving=std::move(*found);groups.erase(found);groups.insert(groups.begin()+to,std::move(moving));
        refreshing=true;left.deselectAllRows();editing=-1;left.updateContent();
        if(selected)for(int i=0;i<(int)groups.size();++i)if(groups[(size_t)i].id==*selected){editing=i;left.selectRow(i);}
        refreshing=false;left.repaint();persistDraft();timerCallback();
    }
    void paintOverChildren(Graphics &g)override{
        if(insertion<0)return;const int y=std::clamp(left.getY()+left.getRowPosition(insertion,true).getY(),left.getY()+1,left.getBottom()-2);
        g.setColour(theme::green);g.fillRect(left.getX()+3,y,left.getWidth()-6,2);
    }
    void paint(Graphics &g)override{
        g.fillAll(theme::panel);g.setColour(Colours::white);g.setFont(theme::font(18,true));g.drawText(localization::translate("Reduzir projeto"),24,18,getWidth()-48,28,Justification::centredLeft);
        if(ready){g.setColour(theme::secondary);g.setFont(theme::font(12));g.drawText(localization::translate(String::fromUTF8("Apenas as pistas escolhidas serão levadas. Áudios separados por região.")),24,52,getWidth()-48,24,Justification::centredLeft);}
    }
    void resized()override{
        const int half=(getWidth()-64)/2;
        create.setBounds(24,90,138,28);edit.setBounds(170,90,70,28);remove.setBounds(248,90,86,28);
        left.setBounds(24,128,half,std::max(0,getHeight()-238));right.setBounds(40+half,128,half,std::max(0,getHeight()-238));
        saveButton.setBounds(24,104,112,28);
        progressBar.setBounds(24,getHeight()-107,getWidth()-48,12);
        status.setBounds(24,ready?getHeight()-89:56,getWidth()-48,42);
        cancel.setBounds(24,getHeight()-44,90,28);reduce.setBounds(getWidth()-114,getHeight()-44,90,28);
    }
};
}
