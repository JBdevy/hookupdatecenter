#pragma once
#include "Session.h"
#include "ModalSheet.h"
namespace catlive {
class AutomaticSectionPanel final : public Component {
    struct Column final : ListBoxModel {
        AutomaticSectionPanel& owner; bool destinations;
        Column(AutomaticSectionPanel& p, bool right):owner(p),destinations(right){}
        int getNumRows() override { return (int)(destinations ? owner.markers.size() : owner.regions.size()); }
        void paintListBoxItem(int row, Graphics& g, int width, int height, bool) override {
            if(row<0 || row>=getNumRows())return;
            const auto id=destinations?owner.markers[(size_t)row]:owner.regions[(size_t)row];
            if(!destinations && owner.region==id){g.setColour(Colour(0xff007aff).withAlpha(.4f));g.fillAll();}
            int inset=10; String title;
            if(const auto* song=owner.session.song()) {
                if(destinations && song->markers) for(const auto& m:*song->markers)if(m.id==id)title=text(m.name);
                if(!destinations)for(const auto& p:song->parts)if(p.id==id)title=text(p.name);
            }
            if(destinations){g.setColour(id==owner.source ? theme::secondary.withAlpha(.35f) : theme::green);g.drawRoundedRectangle(10.f,10.f,18.f,18.f,3.f,1.5f);if(owner.target==id)g.fillRoundedRectangle(14.f,14.f,10.f,10.f,2.f);inset=38;}
            g.setColour(destinations && id==owner.source ? Colours::white.withAlpha(.35f) : Colours::white);g.setFont(theme::font(14));g.drawText(title,inset,0,width-inset-8,height,Justification::centredLeft,true);
        }
        void listBoxItemClicked(int row,const MouseEvent&) override {
            if(row<0 || row>=getNumRows())return;
            if(destinations){const auto id=owner.markers[(size_t)row];if(id==owner.source)return;owner.target=owner.target==id?std::nullopt:std::optional<ID>(id);}
            else {owner.region=owner.regions[(size_t)row];owner.refreshMarkers();}
            owner.left.repaint();owner.right.repaint();
        }
    };
  public:
    AutomaticSectionPanel(Session& s,ID id,std::function<void(String)> fail)
        :session(s),source(std::move(id)),project(s.project().id),error(std::move(fail)),leftModel(*this,false),rightModel(*this,true),left("songs",&leftModel),right("sections",&rightModel) {
        if(const auto* song=session.song()) {
            const jaras::TimelineMarker* original=nullptr;
            if(song->markers)for(const auto& m:*song->markers)if(m.id==source){original=&m;target=m.automaticSectionTargetID==source?std::nullopt:m.automaticSectionTargetID;}
            for(const auto& p:song->parts){
                if(std::any_of(song->parts.begin(),song->parts.end(),[&](const auto& child){return child.parentRegionID==p.id;}))continue;
                regions.push_back(p.id);
                if(original && original->position>=p.startTime && original->position<=p.endTime && (!region || original->regionOwnerID==p.id))region=p.id;
            }
        }
        for(auto* list:{&left,&right}){addAndMakeVisible(list);list->setRowHeight(38);list->setColour(ListBox::backgroundColourId,theme::display);}
        addAndMakeVisible(cancel);addAndMakeVisible(apply);
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        apply.onClick=[this]{
            if(session.project().id!=project){ModalSheet::dismiss(*this);return;}
            try {
                session.edit([&](jaras::Project& p){for(auto& song:p.songs)if(song.markers)for(auto& m:*song.markers)if(m.id==source)m.automaticSectionTargetID=target;});
                ModalSheet::dismiss(*this);
            }catch(const std::exception& e){error(String::fromUTF8(e.what()));}
        };
        refreshMarkers();
    }
    void resized() override {
        auto area=getLocalBounds().reduced(16);area.removeFromTop(38);
        auto buttons=area.removeFromBottom(38);cancel.setBounds(buttons.removeFromLeft(110));apply.setBounds(buttons.removeFromRight(110));area.removeFromBottom(14);
        left.setBounds(area.removeFromLeft((area.getWidth()-12)/2));area.removeFromLeft(12);right.setBounds(area);
        if(!revealed && region){const auto row=std::find(regions.begin(),regions.end(),*region);if(row!=regions.end()){left.scrollToEnsureRowIsOnscreen((int)std::distance(regions.begin(),row));revealed=true;}}
    }
    void paint(Graphics& g) override {g.fillAll(theme::panel);g.setColour(theme::secondary);g.setFont(theme::font(12));g.drawFittedText(String::fromUTF8("Escolha o destino. O aviso começa 5 segundos antes do marcador."),16,8,getWidth()-32,36,Justification::centredLeft,2);}
  private:
    void refreshMarkers(){
        markers.clear();if(const auto* song=session.song();song && song->markers && region){
            const auto p=std::find_if(song->parts.begin(),song->parts.end(),[&](const auto& p){return p.id==*region;});
            if(p!=song->parts.end())for(const auto& m:*song->markers)if(m.section.value_or(false)&&!m.tempoBPM&&m.position>=p->startTime&&m.position<=p->endTime)markers.push_back(m.id);
            std::stable_sort(markers.begin(),markers.end(),[&](const ID&a,const ID&b){auto at=[&](const ID&id){for(const auto&m:*song->markers)if(m.id==id)return m.position;return 0.;};return at(a)<at(b);});
        }left.updateContent();right.updateContent();
    }
    bool revealed=false;
    Session& session;ID source,project;std::function<void(String)> error;
    std::optional<ID> region,target;std::vector<ID> regions,markers;
    Column leftModel,rightModel;ListBox left,right;TextButton cancel{"Cancelar"},apply{"Aplicar"};
};
}
