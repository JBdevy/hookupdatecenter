#pragma once
#include "Localization.h"
#include "Session.h"
#include "ModalSheet.h"
namespace catlive {
class ItemTunerPanel final : public Component, private Timer {
    struct Row final : Component {
        ItemTunerPanel &owner;
        ID id;
        Label title, value;
        TextButton minus{String::fromUTF8("−")}, plus{"+"};
        double pitch = 0;
        Row(ItemTunerPanel &panel, ID item) : owner(panel), id(std::move(item)) {
            for (Component *c : std::initializer_list<Component*>{&title,&value,&minus,&plus}) addAndMakeVisible(c);
            minus.setComponentID("itemTunerDown"); plus.setComponentID("itemTunerUp");
            minus.setWantsKeyboardFocus(false); plus.setWantsKeyboardFocus(false);
            value.setJustificationType(Justification::centred);
            value.setColour(Label::textColourId, theme::green);
            minus.onClick = [this] { owner.change(id,-1); };
            plus.onClick = [this] { owner.change(id,1); };
        }
        void resized() override {
            title.setBounds(10,4,std::max(0,getWidth()-186),48);
            minus.setBounds(getWidth()-166,14,34,28);
            value.setBounds(getWidth()-130,14,76,28);
            plus.setBounds(getWidth()-52,14,34,28);
        }
        void paint(Graphics &g) override { g.setColour(theme::display);g.fillRoundedRectangle(getLocalBounds().toFloat(),7); }
    };
    Session &session;
    std::function<void(String)> error;
    Viewport viewport;
    Component list;
    Label instruction;
    TextButton close{localization::translate("Fechar")};
    std::vector<std::unique_ptr<Row>> rows;
  public:
    ItemTunerPanel(Session &owner, ID target, std::function<void(String)> failure, std::set<ID> selection = {})
        : session(owner), error(std::move(failure)) {
        if (!selection.count(target)) selection = {target};
        addAndMakeVisible(viewport);viewport.setViewedComponent(&list,false);viewport.setScrollBarsShown(true,false);
        addAndMakeVisible(instruction);instruction.setFont(theme::font(11));instruction.setColour(Label::textColourId,theme::secondary);
        if (const auto *song=session.song()) for (const auto &track:song->tracks) for (const auto &clip:track.clips)
            if (selection.count(clip.id) && !clip.midi) {
                auto row=std::make_unique<Row>(*this,clip.id);list.addAndMakeVisible(*row);rows.push_back(std::move(row));
            }
        addAndMakeVisible(close);close.setWantsKeyboardFocus(false);close.onClick=[this]{ModalSheet::dismiss(*this);};
        refresh();startTimerHz(10);
    }
    int preferredHeight() const { return std::min(420,104+(int)rows.size()*66); }
    void paint(Graphics &g) override { g.fillAll(theme::panel); }
    void resized() override {
        const int top=rows.size()>1?54:12;
        instruction.setBounds(16,4,getWidth()-32,46);instruction.setVisible(rows.size()>1);
        viewport.setBounds(16,top,getWidth()-32,std::max(0,getHeight()-top-52));
        const int width=std::max(0,viewport.getWidth()-viewport.getScrollBarThickness());
        list.setSize(width,(int)rows.size()*66);
        int y=0;for(auto &row:rows){row->setBounds(0,y,width,56);y+=66;}
        close.setBounds(getWidth()-96,getHeight()-40,76,26);
    }
  private:
    void refresh() {
        std::map<ID,const jaras::AudioClip*> clips;
        if(const auto *song=session.song())for(const auto &track:song->tracks)for(const auto &clip:track.clips)clips[clip.id]=&clip;
        instruction.setText(localization::translate("Hold Shift and click − or + to adjust all listed items by the same amount."),dontSendNotification);
        close.setButtonText(localization::translate("Fechar"));
        for(auto &row:rows){
            const auto found=clips.find(row->id);const bool exists=found!=clips.end();
            if(exists){row->pitch=found->second->pitchSemitones.value_or(0);row->title.setText(text(found->second->name),dontSendNotification);}
            row->value.setText((row->pitch>=0?"+":"")+String(row->pitch,2).trimCharactersAtEnd("0").trimCharactersAtEnd(".")+" st",dontSendNotification);
            const bool editable=exists&&session.tunerInputAllowed()&&!session.busy&&!jaras::projectSync::readOnly();
            row->minus.setEnabled(editable&&row->pitch>-12);row->plus.setEnabled(editable&&row->pitch<12);
        }
    }
    void timerCallback() override { refresh(); }
    void change(const ID &id,int step) {
        if (!session.tunerInputAllowed()) return;
        try {
            refresh();
            const bool together=ModifierKeys::getCurrentModifiersRealtime().isShiftDown();
            double delta=step;std::vector<std::pair<ID,double>> values;
            for(const auto &row:rows)if(together||row->id==id){values.emplace_back(row->id,row->pitch);delta=std::max(-12.-row->pitch,std::min(12.-row->pitch,delta));}
            for(const auto &value:values)session.setItemPitch(value.first,value.second+delta);
            refresh();
        }catch(const std::exception &e){error(String::fromUTF8(e.what()));}
    }
};
} // namespace catlive
