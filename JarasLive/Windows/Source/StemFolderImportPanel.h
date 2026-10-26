#pragma once
#include "StemFolderImport.h"
#include "ModalSheet.h"
#include "Localization.h"
namespace catlive {
class StemBPMQuestion final : public Component {
    class Choice final : public TextButton {
    public:
        bool primary=false;
        void paintButton(Graphics& g,bool hover,bool down) override {
            g.setColour((primary?Colour(0xff60b746):Colour(0xff414141)).brighter(hover?.06f:0).darker(down?.1f:0));
            g.fillRoundedRectangle(getLocalBounds().toFloat(),getHeight()/2.f);g.setColour(Colours::white);g.setFont(theme::mediumFont(17));g.drawText(getButtonText(),getLocalBounds(),Justification::centred);
        }
    } yes,no,cancel;
public:
    explicit StemBPMQuestion(std::function<void(bool)> accept) {
        getProperties().set("selfContainedSheet",true);getProperties().set("sheetCornerRadius",36.0);
        for(auto* b:{&yes,&no,&cancel})addAndMakeVisible(*b);
        yes.primary=true;yes.setButtonText(localization::translate("Yes"));no.setButtonText(localization::translate("No"));cancel.setButtonText(localization::translate("Cancel"));
        auto finish=[this,accept](bool value){ModalSheet::dismiss(*this);MessageManager::callAsync([accept,value]{accept(value);});};
        yes.onClick=[finish]{finish(true);};no.onClick=[finish]{finish(false);};cancel.onClick=[this]{ModalSheet::dismiss(*this);};
    }
    void paint(Graphics& g) override {g.setGradientFill(ColourGradient(Colour(0xff343434),0,0,Colour(0xff292929),0,(float)getHeight(),false));g.fillRoundedRectangle(getLocalBounds().toFloat().reduced(.5f),36);g.setColour(Colours::white.withAlpha(.2f));g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(.5f),36,1);g.setColour(Colours::white);g.setFont(theme::semiboldFont(18));g.drawFittedText(localization::translate("Detect BPM for each song?"),24,24,getWidth()-48,44,Justification::centred,2);}
    void resized() override {yes.setBounds(20,82,getWidth()-40,36);no.setBounds(20,126,getWidth()-40,36);cancel.setBounds(20,170,getWidth()-40,36);}
};
class StemFolderImportPanel final : public Component,private ListBoxModel {
    class Preview final : public Component {
    public:
        StringArray names;
        void paint(Graphics& g) override {for(int i=0;i<names.size();++i){int y=i*38;g.setColour(Colour(0xff202020));g.fillRoundedRectangle(0,(float)y,(float)getWidth(),34,5);g.setColour(theme::green);g.fillRoundedRectangle(8,(float)y+7,3,20,1.5f);g.setColour(theme::secondary);g.setFont(theme::font(11));g.drawText(String(i+1).paddedLeft('0',2),17,y,27,34,Justification::centredLeft);g.setColour(Colours::white);g.setFont(theme::mediumFont(15));g.drawFittedText(names[i],44,y,getWidth()-52,34,Justification::centredLeft,1);}}
    } previewContent;
    class Suggestion final : public ToggleButton {
    public:
        String count;
        void paintButton(Graphics& g,bool hover,bool) override {g.setColour(getToggleState()?Colour(0xff28382a):Colour(hover?0xff292929:0xff202020));g.fillRect(getLocalBounds());g.setColour(Colours::white);g.setFont(theme::mediumFont(16));g.drawText(getButtonText(),8,0,getWidth()-60,getHeight(),Justification::centredLeft);g.drawText(count,getWidth()-50,0,42,getHeight(),Justification::centredRight);}
    };
public:
    using Confirm=std::function<void(std::shared_ptr<stemImport::Scan>,String,bool,std::function<void()>)>;
    StemFolderImportPanel(std::shared_ptr<stemImport::Scan> value,bool adding,Confirm confirm,bool scanInBackground=false):scan(std::move(value)),complete(std::move(confirm)),appending(adding) {
        getProperties().set("selfContainedSheet",true);
        addAndMakeVisible(suggestionViewport);suggestionViewport.setViewedComponent(&suggestionContent,false);suggestionViewport.setScrollBarsShown(true,false);
        list.setModel(this);list.setRowHeight(38);list.setColour(ListBox::backgroundColourId,theme::background);
        preview.setViewedComponent(&previewContent,false);preview.setScrollBarsShown(true,false);
        search.setTextToShowWhenEmpty(localization::translate("Search folders"),theme::secondary);
        search.onTextChange=[this]{filter();};
        for(auto* button:{&all,&back,&cancel,&next,&yes,&no})addAndMakeVisible(*button);
        next.setColour(TextButton::buttonColourId,Colour(0xff3e7854));next.setColour(TextButton::textColourOffId,Colours::white);
        cancel.setButtonText(localization::translate("Cancel"));back.setButtonText(localization::translate("Back"));yes.setButtonText(localization::translate("Yes"));no.setButtonText(localization::translate("No"));
        all.onClick=[this]{if(selected.size()==scan->folders.size())selected.clear();else {selected.clear();for(size_t i=0;i<scan->folders.size();++i)selected.push_back(i);}refreshOrder();};
        back.onClick=[this]{ModalSheet::dismiss(*this);};
        next.onClick=[this]{if(step==0){if(selected.empty())return;step=1;refreshStep();}else {auto safe=SafePointer<StemFolderImportPanel>(this);ModalSheet::open(*this,"",std::make_unique<StemBPMQuestion>([safe](bool bpm){if(safe)safe->finish(bpm);}),380,230);}};
        yes.onClick=[this]{finish(true);};no.onClick=[this]{finish(false);};cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        cleanup.setTextToShowWhenEmpty(localization::translate("Names to remove, separated by commas"),theme::secondary);
        for(auto* view:std::initializer_list<Component*>{&list,&preview,&search,&cleanup})addAndMakeVisible(*view);
        rebuildSuggestions();
        filter();refreshOrder();refreshStep();setComponentID("stem-folder-review");
        if(scanInBackground){
            loading=true;refreshOrder();Array<File> directories;for(const auto& folder:scan->folders)directories.add(folder.directory);
            auto safe=SafePointer<StemFolderImportPanel>(this);
            Thread::launch([safe,directories]{
                std::shared_ptr<stemImport::Scan> result;String error;
                try{result=stemImport::scan(directories);}catch(const std::exception& e){error=String::fromUTF8(e.what());}
                MessageManager::callAsync([safe,result,error]{
                    if(!safe)return;
                    safe->loading=false;safe->scanError=error;
                    if(result){
                        std::vector<File> chosen;for(auto index:safe->selected)chosen.push_back(safe->scan->folders[index].directory);
                        safe->scan=result;safe->selected.clear();
                        for(const auto& directory:chosen)for(size_t i=0;i<result->folders.size();++i)if(result->folders[i].directory==directory)safe->selected.push_back(i);
                        safe->rebuildSuggestions();safe->filter();
                    }
                    safe->refreshStep();
                });
            });
        }
    }
    void paint(Graphics& g) override {
        g.fillAll(Colour(0xff161616));g.setColour(step==0?theme::green:Colours::white);g.setFont(theme::mediumFont(19));
        if(step==0)drawInterfaceIcon(g,"folder",{20.f,14.f,24.f,26.f});
        g.drawText(localization::translate(step==0?"Choose folders":step==1?"Review stems":"Detect BPM for each song?"),step==0?52:20,12,getWidth()-72,30,Justification::centredLeft);
        g.setFont(theme::font(13));g.setColour(theme::secondary);
        if(loading||scanError.isNotEmpty())g.drawFittedText(loading?localization::translate(String::fromUTF8("Reading audio files…")):scanError,130,getHeight()-44,std::max(10,getWidth()-320),32,Justification::centredLeft,2);
        if(step==0){g.setColour(theme::line);g.drawVerticalLine(getWidth()/2,156.f,(float)getHeight()-62);g.setColour(theme::secondary);g.drawText(String((int)selected.size())+" / "+String((int)scan->folders.size()),getWidth()-100,84,80,28,Justification::centredRight);g.drawText(localization::translate("Folders"),20,156,getWidth()/2-30,22,Justification::centredLeft);g.drawText(localization::translate("All regions preview"),getWidth()/2+10,156,getWidth()/2-30,22,Justification::centredLeft);
            g.drawFittedText(localization::translate(appending?"Songs will be added in this order after the last song in the open project.":"Folders will be placed on the grid in the order you check them."),20,120,getWidth()-40,28,Justification::centredLeft,2);
        }else if(step==1){int count=0;for(auto index:selected)count+=(int)scan->folders[index].files.size();g.setColour(Colours::white);g.drawText(String((int)selected.size())+" "+localization::translate("song folders")+String::fromUTF8(" · ")+String(count)+" "+localization::translate("audio files"),20,48,getWidth()-40,25,Justification::centredLeft);g.setColour(theme::secondary);g.drawFittedText(localization::translate("Repeated names were found that may identify providers. Select suggestions or type names to remove."),20,80,getWidth()-40,46,Justification::centredLeft,3);
            g.drawFittedText(localization::translate("Original folders remain unchanged. Audio is copied beside the .jl project."),20,getHeight()-100,getWidth()-40,38,Justification::centredLeft,2);
        }
    }
    void resized() override {
        int half=getWidth()/2;search.setBounds(half-155,52,310,30);all.setBounds(20,84,150,28);
        list.setBounds(20,182,half-30,getHeight()-244);preview.setBounds(half+10,182,half-30,getHeight()-244);
        previewContent.setSize(std::max(1,preview.getWidth()-12),std::max(preview.getHeight(),(int)selected.size()*38));
        int y=0;for(auto& button:suggestions){button->setBounds(0,y,getWidth()-52,28);y+=33;}
        int suggestionsHeight=std::min(160,std::max(0,getHeight()-300));suggestionViewport.setBounds(20,132,getWidth()-40,suggestionsHeight);suggestionContent.setSize(getWidth()-52,y);
        cleanup.setBounds(20,144+suggestionsHeight,getWidth()-40,32);
        cancel.setBounds(20,getHeight()-44,100,32);back.setBounds(20,getHeight()-44,100,32);next.setBounds(getWidth()-180,getHeight()-44,160,32);
        yes.setBounds(getWidth()/2-130,100,120,40);no.setBounds(getWidth()/2+10,100,120,40);
    }
private:
    void rebuildSuggestions(){suggestions.clear();
        if(auto values=scan->suggestions.getArray())for(const auto& value:*values){auto button=std::make_unique<Suggestion>();auto term=value["text"].toString();button->setButtonText(term);button->count=value["count"].toString()+String::fromUTF8("×");
            button->onClick=[this,term,p=button.get()]{auto terms=StringArray::fromTokens(cleanup.getText(),",","");terms.trim();terms.removeEmptyStrings();if(p->getToggleState())terms.addIfNotAlreadyThere(term);else terms.removeString(term);cleanup.setText(terms.joinIntoString(", "));};suggestionContent.addAndMakeVisible(*button);suggestions.push_back(std::move(button));}
    }
    int getNumRows() override{return (int)filtered.size();}
    void paintListBoxItem(int row,Graphics& g,int width,int height,bool) override {
        if(row<0||row>=getNumRows())return;auto index=filtered[row];auto found=std::find(selected.begin(),selected.end(),index);bool checked=found!=selected.end();
        g.setColour(checked?Colour(0xff223125):Colour(0xff202020));g.fillRoundedRectangle(0,0,(float)width,(float)height-4,5);g.setColour(checked?theme::green:theme::secondary);g.drawRect(8,10,16,16,1);if(checked){g.fillRoundedRectangle(8,10,16,16,2);g.setColour(Colour(0xff16381f));Path check;check.startNewSubPath(11,18);check.lineTo(15,22);check.lineTo(21,13);g.strokePath(check,PathStrokeType(1.5f));}
        g.setColour(Colours::white);g.setFont(theme::font(14));g.drawFittedText(scan->folders[index].directory.getFileName(),32,0,width-76,height,Justification::centredLeft,1);
        if(checked){g.setColour(theme::green);g.drawText(String((int)std::distance(selected.begin(),found)+1).paddedLeft('0',2),width-40,0,34,height,Justification::centredRight);}
    }
    void listBoxItemClicked(int row,const MouseEvent&) override {if(row<0||row>=getNumRows())return;auto index=filtered[row];auto found=std::find(selected.begin(),selected.end(),index);if(found==selected.end())selected.push_back(index);else selected.erase(found);refreshOrder();}
    void filter(){filtered.clear();for(size_t i=0;i<scan->folders.size();++i)if(scan->folders[i].directory.getFileName().containsIgnoreCase(search.getText()))filtered.push_back(i);list.updateContent();list.repaint();}
    void refreshOrder(){previewContent.names.clear();for(auto index:selected)previewContent.names.add(scan->folders[index].directory.getFileName());previewContent.setSize(std::max(1,preview.getWidth()-12),std::max(preview.getHeight(),(int)selected.size()*38));previewContent.repaint();all.setButtonText(localization::translate(selected.size()==scan->folders.size()?"Deselect all":"Select all"));next.setEnabled(!loading&&scanError.isEmpty()&&(step!=0||!selected.empty()));list.repaint();repaint();}
    void refreshStep(){for(auto* view:std::initializer_list<Component*>{&list,&preview,&search,&all})view->setVisible(step==0);cleanup.setVisible(step==1);suggestionViewport.setVisible(step==1);for(auto& button:suggestions)button->setVisible(step==1);back.setVisible(step>0);cancel.setVisible(step==0);next.setVisible(step<2);yes.setVisible(step==2);no.setVisible(step==2);next.setButtonText(localization::translate(step==0?"Continue":"Create / Add"));refreshOrder();resized();repaint();}
    void finish(bool bpm){auto result=std::make_shared<stemImport::Scan>(*scan);result->folders.clear();for(auto index:selected)result->folders.push_back(scan->folders[index]);auto callback=complete;auto remove=cleanup.getText();auto safe=SafePointer<StemFolderImportPanel>(this);MessageManager::callAsync([callback,result,remove,bpm,safe]{if(safe)callback(result,remove,bpm,[safe]{if(safe)ModalSheet::dismiss(*safe);});});}
    std::shared_ptr<stemImport::Scan> scan;Confirm complete;bool appending=false,loading=false;String scanError;int step=0;
    std::vector<size_t> selected,filtered;ListBox list;TextEditor cleanup,search;Component suggestionContent;Viewport preview,suggestionViewport;TextButton all,back,cancel,next,yes,no;std::vector<std::unique_ptr<Suggestion>> suggestions;
};
}
