#pragma once
#include "Session.h"
#include "ModalSheet.h"
#include "RegionEditing.h"
namespace catlive {
class MultiLoopsPanel final : public Component {
  public:
    MultiLoopsPanel(Session &s, ID region, std::function<void(String)> failure)
        : session(s), regionID(std::move(region)), error(std::move(failure)) {
        getProperties().set("selfContainedSheet", true);
        addAndMakeVisible(view); view.setViewedComponent(&content, false);
        view.setScrollBarsShown(true, false); view.setScrollBarThickness(8);
        addAndMakeVisible(cancel); addAndMakeVisible(next);
        cancel.onClick = [this] { if (!stage) ModalSheet::dismiss(*this); else { stage = 0; refreshLater(); } };
        next.onClick = [this] {
            if (stage == 1) {
                if (name.getText().trim().isEmpty()) { name.setColour(TextEditor::outlineColourId, Colours::red); name.grabKeyboardFocus(); return; }
                draft.name = utf8(name.getText().trim()); stage = 2; refreshLater();
            } else if (stage == 2 || stage == 3) save(draft);
        };
        rebuild();
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel); g.setColour(Colours::white); g.setFont(theme::font(17, true));
        g.drawText("Multiloop Manager", 20, 12, getWidth()-40, 28, Justification::centredLeft);
        g.setColour(theme::secondary); g.setFont(theme::font(13));
        if (auto *part = region()) g.drawText(text(part->name), 20, 42, getWidth()-40, 22, Justification::centredLeft);
        g.setColour(theme::line); g.drawHorizontalLine(getHeight()-54, 20.f, getWidth()-20.f);
    }
    void resized() override {
        view.setBounds(20, 78, getWidth()-40, getHeight()-145);
        content.setSize(std::max(1, view.getWidth()-10), contentHeight);
        cancel.setBounds(20, getHeight()-42, 82, 26); next.setBounds(getWidth()-102, getHeight()-42, 82, 26);
    }
  private:
    Session &session; ID regionID; std::function<void(String)> error;
    Viewport view; Component content; OwnedArray<Component> controls;
    TextButton cancel, next; TextEditor name; int stage = 0, contentHeight = 300;
    jaras::MultiLoop draft;
    const jaras::Part *region() const {
        if (auto *song = session.song()) for (const auto &part : song->parts) if (part.id == regionID) return &part;
        return nullptr;
    }
    bool bypassed() const {
        const auto *part = region(); if (!part) return true;
        if (part->totalLoop.value_or(false)) return true;
        if (part->parentRegionID) for (const auto &p : session.song()->parts)
            if (p.id == *part->parentRegionID) return p.totalLoop.value_or(false);
        return false;
    }
    std::vector<jaras::TimelineMarker> markers() const {
        std::vector<jaras::TimelineMarker> result;
        if (const auto *part = region(); part && session.song()->markers && !regionEditing::hasChildren(*session.song(), regionID))
            for (const auto &m : *session.song()->markers)
                if (m.section.value_or(false) && m.loopSection.value_or(false) && m.position >= part->startTime && m.position <= part->endTime) result.push_back(m);
        std::sort(result.begin(), result.end(), [](const auto &a, const auto &b) { return a.position == b.position ? a.id < b.id : a.position < b.position; });
        return result;
    }
    bool validPair(const jaras::MultiLoop &loop) const {
        double a = -1, b = -1;
        for (const auto &marker : markers()) { if (marker.id == loop.marker1) a = marker.position; if (marker.id == loop.marker2) b = marker.position; }
        return a >= 0 && b > a;
    }
    bool conflicts(const jaras::MultiLoop &candidate) const {
        if (!session.song() || !session.song()->markers) return false;
        std::map<ID,double> position; for (const auto &m : *session.song()->markers) position[m.id] = m.position;
        if (!position.count(candidate.marker1) || !position.count(candidate.marker2)) return false;
        bool unchanged = false;
        for (const auto &part : session.song()->parts) for (const auto &loop : part.multiLoops)
            if (loop.id == candidate.id && loop.marker1 == candidate.marker1 && loop.marker2 == candidate.marker2) unchanged = true;
        if (unchanged) return false;
        for (const auto &part : session.song()->parts) for (const auto &loop : part.multiLoops)
            if (loop.id != candidate.id && position.count(loop.marker1) && position.count(loop.marker2)
                && std::max(position[candidate.marker1], position[loop.marker1]) < std::min(position[candidate.marker2], position[loop.marker2]) - .000001) return true;
        return false;
    }
    void refreshLater() {
        MessageManager::callAsync([safe=SafePointer<MultiLoopsPanel>(this)] { if (safe) safe->rebuild(); });
    }
    void change(std::function<void(jaras::Part &)> edit) {
        try {
            session.edit([&](jaras::Project &p) { for (auto &song : p.songs) for (auto &part : song.parts) if (part.id == regionID) edit(part); });
            refreshLater();
        } catch (const std::exception &e) { error(String::fromUTF8(e.what())); }
    }
    void save(const jaras::MultiLoop &loop) {
        if (!validPair(loop)) { error(String::fromUTF8("Escolha dois marcadores diferentes em ordem cronológica.")); return; }
        if (conflicts(loop)) { error(String::fromUTF8("Um multiloop não pode existir dentro de outro multiloop.")); return; }
        change([&](jaras::Part &part) {
            auto at = std::find_if(part.multiLoops.begin(), part.multiLoops.end(), [&](const auto &value) { return value.id == loop.id; });
            if (at == part.multiLoops.end()) part.multiLoops.push_back(loop); else *at = loop;
        });
        stage = 0;
    }
    TextButton *button(String title, int x, int y, int width, std::function<void()> action, bool active = false, Colour colour = theme::green) {
        auto *b = new TextButton(title); controls.add(b); content.addAndMakeVisible(b);
        b->setBounds(x,y,width,26); b->getProperties().set("flat", true);
        b->setColour(TextButton::buttonColourId, active ? colour : Colours::white.withAlpha(.1f));
        b->setColour(TextButton::textColourOffId, active ? Colours::black : Colours::white);
        b->onClick = std::move(action); return b;
    }
    void label(String title, int x, int y, int width, float size = 13) {
        auto *l = new Label({},title); controls.add(l); content.addAndMakeVisible(l);
        l->setBounds(x,y,width,26); l->setFont(theme::font(size));
    }
    void rebuild() {
        controls.clear(); name.setVisible(false); content.removeChildComponent(&name);
        const auto *part = region(); if (!part) return;
        const bool bypass = bypassed();
        cancel.setButtonText(stage ? "Cancelar" : "Fechar"); next.setVisible(stage != 0);
        next.setButtonText(stage == 1 ? String::fromUTF8("Próximo") : stage == 2 ? "OK" : "Salvar");
        next.setEnabled(stage != 2 || (validPair(draft) && !bypass));
        int y = 0;
        if (stage == 0) {
            button("+",0,0,30,[this] { draft = {}; draft.id = uuid(); stage = 1; name.setText({}); refreshLater(); })->setEnabled(!bypass);
            button("Total Loop",40,0,110,[this, active=part->totalLoop.value_or(false)] { change([&](auto &p) { p.totalLoop = !active; }); },part->totalLoop.value_or(false));
            y = 40;
            for (const auto &loop : part->multiLoops) {
                button(loop.enabled.value_or(true) ? "On" : "Off",0,y,42,[this,loop] { auto changed = loop; changed.enabled = !loop.enabled.value_or(true); save(changed); },loop.enabled.value_or(true))->setEnabled(!bypass);
                label(text(loop.name),50,y,bypass ? 190 : 245);
                if (bypass) label("Bypass",240,y,60,11);
                button("Marcadores",310,y,100,[this,loop] { draft = loop; stage = 2; refreshLater(); });
                button("Editar",418,y,76,[this,loop] { draft = loop; stage = 3; prepareTracks(); refreshLater(); });
                button("Excluir",502,y,76,[this,id=loop.id] { change([&](auto &p) { p.multiLoops.erase(std::remove_if(p.multiLoops.begin(),p.multiLoops.end(),[&](const auto &v){return v.id==id;}),p.multiLoops.end()); }); });
                y += 42;
            }
        } else if (stage == 1) {
            content.addAndMakeVisible(name); name.setBounds(0,0,590,28); name.setFont(theme::font(13)); name.setTextToShowWhenEmpty("Nome",theme::secondary);
            name.setColour(TextEditor::outlineColourId, theme::line); name.onReturnKey = [this] { next.triggerClick(); };
            name.grabKeyboardFocus(); y = 80;
        } else if (stage == 2) {
            label(text(draft.name),0,0,590); label("Marcador 1",0,32,270); label("Marcador 2",310,32,270); y = 66;
            const auto values = markers();
            if (values.empty()) label("Nenhum marcador encontrado",0,y,590);
            for (const auto &m : values) {
                for (bool second : {false,true}) {
                    const bool active = (second ? draft.marker2 : draft.marker1) == m.id;
                    auto title = (active ? String::fromUTF8("● ") : String::fromUTF8("○ ")) + text(m.name) + "   " + String(m.position,2) + "s";
                    button(title,second ? 310 : 0,y,280,[this,id=m.id,second] {
                        auto candidate = draft; if(second) candidate.marker2=id; else candidate.marker1=id;
                        if(conflicts(candidate)) { error(String::fromUTF8("Um multiloop não pode existir dentro de outro multiloop.")); return; }
                        draft = candidate; refreshLater();
                    },active);
                }
                y += 34;
            }
            label(String::fromUTF8("Escolha dois marcadores diferentes em ordem cronológica"),0,y+8,590,11); y += 44;
        } else {
            label(text(draft.name),0,0,590);
            button("M/S",0,32,45,[this] { draft.mixerEnabled = !draft.mixerEnabled.value_or(true); refreshLater(); },draft.mixerEnabled.value_or(true),theme::yellow);
            label("Auto Fader",55,32,90);
            button(String::fromUTF8("−"),145,32,26,[this] { draft.fadeSeconds = std::max(1.,draft.fadeSeconds-1); refreshLater(); })->setEnabled(draft.fadeSeconds>1);
            label(String((int)draft.fadeSeconds)+"s",176,32,32);
            button("+",215,32,26,[this] { draft.fadeSeconds = std::min(5.,draft.fadeSeconds+1); refreshLater(); })->setEnabled(draft.fadeSeconds<5);
            y=74;
            for (auto &rule : draft.tracks) {
                String title="Master"; double ceiling=session.project().masterVolume;
                if(rule.id!="00000000-0000-0000-0000-000000000000") for(const auto &track:session.song()->tracks) if(track.id==rule.id){title=text(track.name);ceiling=track.volume;}
                label(title,0,y,145);
                auto *slider = new ParameterSlider(Slider::LinearHorizontal,Slider::NoTextBox);controls.add(slider);content.addAndMakeVisible(slider);
                slider->setBounds(145,y,180,26);slider->setRange(0,std::max(.000001,ceiling));slider->setValue(std::min(ceiling,rule.gain),dontSendNotification);slider->setEnabled(ceiling>0);
                const ID id=rule.id;
                auto *value = new Label({},rule.gain<=0?String::fromUTF8("−∞"):String(20*std::log10(std::max(.000001,std::min(ceiling,rule.gain))),1)+" dB");
                controls.add(value);content.addAndMakeVisible(value);value->setFont(theme::font(11));value->setBounds(325,y,68,26);
                slider->onValueChange=[this,id,slider,value] { for(auto &r:draft.tracks)if(r.id==id){r.gain=slider->getValue();value->setText(r.gain<=0?String::fromUTF8("−∞"):String(20*std::log10(r.gain),1)+" dB",dontSendNotification);} };
                auto toggle=[this,id](int field){for(auto &r:draft.tracks)if(r.id==id){if(field==0)r.autoFader=!r.autoFader;if(field==1)r.mute=!r.mute;if(field==2)r.solo=!r.solo;}refreshLater();};
                button("Auto Fader",395,y,92,[toggle]{toggle(0);},rule.autoFader,theme::green);
                button("M",495,y,32,[toggle]{toggle(1);},rule.mute,Colours::red);
                button("S",535,y,32,[toggle]{toggle(2);},rule.solo,theme::yellow);y+=36;
            }
        }
        contentHeight=std::max(300,y);resized();repaint();
    }
    void prepareTracks() {
        std::map<ID,double> gains{{"00000000-0000-0000-0000-000000000000",session.project().masterVolume}};
        for(const auto &track:session.song()->tracks)if(jaras::fixedTrackName(track.role).empty())gains[track.id]=track.volume;
        draft.tracks.erase(std::remove_if(draft.tracks.begin(),draft.tracks.end(),[&](const auto &r){return !gains.count(r.id);}),draft.tracks.end());
        for(const auto &entry:gains)if(std::none_of(draft.tracks.begin(),draft.tracks.end(),[&](const auto &r){return r.id==entry.first;}))draft.tracks.push_back({entry.first,entry.second});
    }
};
}
