#pragma once
#include "Session.h"
#include "TrackVisibility.h"

namespace catlive {
class TrackVisibilityPanel final : public Component,private ListBoxModel {
  public:
    using Panel=TrackVisibility::Panel;
    TrackVisibilityPanel(Session &owner,TrackVisibility &preferences,
                         std::function<void(Panel,const ID &,bool)> change)
        : session(owner),visibility(preferences),changed(std::move(change)) {
        setComponentID("trackVisibilityPanel");
        for(auto *button:{&trackTab,&barTab}) {addAndMakeVisible(*button);button->setWantsKeyboardFocus(false);}
        trackTab.setComponentID("trackVisibilityTrackTab");barTab.setComponentID("trackVisibilityBarTab");
        trackTab.onClick=[this]{selectPanel(Panel::trackMixer);};
        barTab.onClick=[this]{selectPanel(Panel::barMixer);};
        addAndMakeVisible(listBox);listBox.setComponentID("trackVisibilityList");
        listBox.setModel(this);listBox.setRowHeight(34);listBox.setColour(ListBox::backgroundColourId,Colours::transparentBlack);
        listBox.setOutlineThickness(0);listBox.setMultipleSelectionEnabled(false);
        selectPanel(Panel::trackMixer);
    }
    ~TrackVisibilityPanel() override {listBox.setModel(nullptr);}
    void resized() override {
        const int half=(getWidth()-36)/2;
        trackTab.setBounds(14,12,half,30);barTab.setBounds(22+half,12,half,30);
        listBox.setBounds(12,78,getWidth()-24,std::max(1,getHeight()-90));
    }
    void paint(Graphics &g) override {
        g.setColour(theme::secondary);g.setFont(theme::font(11));
        g.drawText(panel==Panel::trackMixer?String::fromUTF8("Mostrar pistas no Track Mixer e no grid")
                                          :String::fromUTF8("Mostrar pistas na Hoz-Mixer"),
                   16,48,getWidth()-32,22,Justification::centredLeft);
        if(ids.empty())g.drawText("Nenhuma pista",listBox.getBounds(),Justification::centred);
    }
  private:
    class Row final : public Component {
      public:
        explicit Row(TrackVisibilityPanel &owner):panel(owner) {
            addAndMakeVisible(check);check.setWantsKeyboardFocus(false);
            check.onClick=[this] {
                if(panel.changed)panel.changed(panel.panel,id,check.getToggleState());
                panel.listBox.updateContent();panel.listBox.repaint();
            };
        }
        void update(const ID &target) {
            id=target;depth=0;inherited=false;name.clear();colour=theme::secondary;
            if(const auto *song=panel.session.song()) {
                auto at=trackTree::index(*song,id);
                if(at<song->tracks.size()) {
                    const auto &track=song->tracks[at];name=text(track.name);colour=theme::track(track);
                    for(size_t guard=0;at<song->tracks.size()&&guard<song->tracks.size();++guard) {
                        if(!song->tracks[at].parentTrackID)break;
                        ++depth;at=trackTree::index(*song,*song->tracks[at].parentTrackID);
                    }
                    const auto parent=track.parentTrackID;
                    inherited=parent&&!panel.visibility.visible(*song,panel.panel,*parent);
                }
            }
            check.setComponentID("trackVisibility:"+TrackVisibility::panelName(panel.panel)+":"+text(id));
            check.setToggleState(panel.visibility.ownVisible(panel.panel,id),dontSendNotification);
            check.setEnabled(!inherited);
            check.setTooltip(inherited?String::fromUTF8("Oculta pelo grupo. Mostre o grupo para alterar esta pista."):name);
            resized();repaint();
        }
        void resized() override {check.setBounds(4+std::min(depth,8)*14,5,24,24);}
        void paint(Graphics &g) override {
            const int x=check.getRight()+5;
            g.setColour(colour.withMultipliedAlpha(inherited?.35f:1.f));g.fillRoundedRectangle(float(x),11,4,12,2);
            g.setColour(inherited?theme::secondary:Colours::white);g.setFont(theme::font(13));
            g.drawText(name,x+12,0,getWidth()-x-18,getHeight(),Justification::centredLeft);
        }
      private:
        TrackVisibilityPanel &panel;ID id;ToggleButton check;String name;Colour colour;
        int depth=0;bool inherited=false;
    };
    Session &session;TrackVisibility &visibility;
    std::function<void(Panel,const ID &,bool)> changed;
    TextButton trackTab{"Track Mixer"},barTab{"Hoz-Mixer"};ListBox listBox;
    std::vector<ID> ids;Panel panel=Panel::trackMixer;
    void selectPanel(Panel next) {
        panel=next;ids.clear();
        if(const auto *song=session.song())for(const auto &track:song->tracks)
            if(panel==Panel::trackMixer||TrackVisibility::supportsBarMixer(track))ids.push_back(track.id);
        trackTab.setToggleState(panel==Panel::trackMixer,dontSendNotification);
        barTab.setToggleState(panel==Panel::barMixer,dontSendNotification);
        for(auto *button:{&trackTab,&barTab}) {
            button->setColour(TextButton::buttonOnColourId,theme::green.withAlpha(.18f));
            button->setColour(TextButton::textColourOnId,theme::green);
        }
        listBox.updateContent();listBox.repaint();repaint();
    }
    int getNumRows() override {return int(ids.size());}
    void paintListBoxItem(int,Graphics &,int,int,bool) override {}
    Component *refreshComponentForRow(int row,bool,Component *existing) override {
        if(row<0||row>=(int)ids.size()){delete existing;return nullptr;}
        auto *item=dynamic_cast<Row*>(existing);if(!item)item=new Row(*this);
        item->update(ids[(size_t)row]);return item;
    }
};
} // namespace catlive
