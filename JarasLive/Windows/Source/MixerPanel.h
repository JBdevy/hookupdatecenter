#pragma once
#include "Session.h"
#include "GainFader.h"
#include "MeterDisplay.h"
#include "FXChain.h"
#include "TrackDrop.h"
#include "SpecialTrackControls.h"
#include "RecordingOptionsPanel.h"
namespace catlive {
class MixerPanel final : public Component, public DragAndDropContainer, private Timer {
  public:
    MixerPanel(Session &owner, std::function<void(ID,String)> effects, std::function<void(ID, ModifierKeys)> selected,
               std::function<void(String)> failure, std::function<void(ID, bool)> chainAction,
               std::function<bool(ID)> isSelected, std::function<void(ID,Point<int>)> contextMenu, std::function<void(ID,String)> specialCallback = {})
        : session(owner), openEffects(std::move(effects)), selectTrack(std::move(selected)),
          error(std::move(failure)), changeEffects(std::move(chainAction)), selectedTrack(std::move(isSelected)), openContextMenu(std::move(contextMenu)),specialAction(std::move(specialCallback)) {
        addAndMakeVisible(viewport);
        viewport.setViewedComponent(&content, false);
        viewport.setScrollBarsShown(false, true);
        viewport.setScrollBarThickness(10);
        viewport.addMouseListener(this, true);
        startTimerHz(30);
        refresh();
    }
    ~MixerPanel() override {
        stopTimer();
        viewport.removeMouseListener(this);
        viewport.setViewedComponent(nullptr, false);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::background);
        g.setColour(theme::line);
        g.drawHorizontalLine(0, 0, (float)getWidth());
    }
    void resized() override {
        viewport.setBounds(0, 4, getWidth(), std::max(1, getHeight() - 4));
        content.setSize(std::max(viewport.getWidth(), strips.size() * 86),
                        std::max(1, viewport.getHeight() - 10));
        for (int i = 0; i < strips.size(); ++i)
            strips[i]->setBounds(i * 86, 0, 83, content.getHeight());
    }
    void refresh() {
        std::vector<ID> wanted;
        if (const auto *song = session.song())
            for (const auto &track : song->tracks)
                wanted.push_back(track.id);
        if (wanted != ids) {
            ids = wanted;
            strips.clear();
            for (const auto &id : ids) {
                auto *strip = strips.add(new Strip(*this, id));
                content.addAndMakeVisible(strip);
            }
            resized();
        }
        for (auto *strip : strips)
            strip->refresh();
    }
    void mouseWheelMove(const MouseEvent &event, const MouseWheelDetails &wheel) override {
        for (auto *strip : strips) if (strip->getLocalBounds().contains(event.getEventRelativeTo(strip).getPosition()) &&
                                      strip->scrollEffects(event.getEventRelativeTo(strip), wheel)) return;
        viewport.setViewPosition(
            jlimit(0, std::max(0, content.getWidth() - viewport.getViewWidth()),
                   viewport.getViewPositionX() -
                       (int)((wheel.deltaX != 0 ? wheel.deltaX : wheel.deltaY) * 320)),
            0);
    }
    int scrollX() const { return viewport.getViewPositionX(); }
    void paintOverChildren(Graphics &g) override {
        Graphics::ScopedSaveState saved(g);g.reduceClipRegion(viewport.getBounds());
        const ID target=dropPreview?dropPreview->indicator:blocked;auto at=std::find(ids.begin(),ids.end(),target);if(at==ids.end())return;
        auto *strip=strips[(int)std::distance(ids.begin(),at)];auto r=getLocalArea(strip,strip->getLocalBounds());
        if(dropPreview){g.setColour(dropPreview->joins?theme::yellow:theme::green);g.fillRect(dropPreview->after?r.getRight()-2:r.getX(),r.getY(),2,r.getHeight());}
        else{g.setColour(Colours::red);g.drawRect(r.reduced(2),2);}
    }

  private:
    class Strip final : public Component, public DragAndDropTarget {
      public:
        Strip(MixerPanel &owner, ID target) : mixer(owner), id(std::move(target)) {
            setComponentID("mixerStrip:"+text(id));
            for (auto *button : {&fx, &mute, &solo, &phase, &record}) {
                addAndMakeVisible(button);
                button->getProperties().set("flat", true);
                button->getProperties().set("fontSize", 11);
                button->setWantsKeyboardFocus(false);
                button->setColour(TextButton::buttonColourId, Colours::white.withAlpha(.15f));
            }
            mute.setColour(TextButton::buttonOnColourId, Colour(0xffff4444));
            solo.setColour(TextButton::buttonOnColourId, theme::yellow);
            phase.setColour(TextButton::buttonOnColourId, theme::yellow);
            record.setColour(TextButton::textColourOffId, Colour(0xffff4444));
            fx.onClick = [this] { mixer.openEffects(id,{}); };
            fxchain::bind(fx, mixer.session, id, [this](bool remove) { mixer.changeEffects(id, remove); });
            mute.onClick = [this] { command(jaras::CommandKind::mute); };
            solo.onClick = [this] { command(jaras::CommandKind::solo); };
            phase.onClick = [this] { command(jaras::CommandKind::phase); };
            record.setColour(TextButton::buttonOnColourId, Colour(0xffff1f1f));
            record.onClick = [this] {
                try {
                    mixer.session.cycleRecordArm(id, selection());
                } catch (const std::exception &e) {
                    mixer.error(String::fromUTF8(e.what()));
                }
            };
            record.context = [this](Point<int>) {
                RecordingOptionsPanel::show(mixer.session, id, selection(), record, mixer.error);
            };
            addAndMakeVisible(fader);
            fader.setComponentID("mixerFader");
            fader.setSliderStyle(Slider::LinearVertical);
            fader.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
            fader.setDoubleClickReturnValue(true, 1);
            fader.onDragStart = [this] { mixer.session.beginMixerGesture(jaras::CommandKind::volume,id); };
            fader.onDragEnd = [this] { mixer.session.endMixerGesture(); };
            fader.onValueChange = [this] { command(jaras::CommandKind::volume, fader.getValue()); };
            addAndMakeVisible(pan);
            pan.setComponentID("mixerPan");
            pan.setRange(-1, 1, .01);
            pan.setSliderStyle(Slider::RotaryHorizontalVerticalDrag);
            pan.getProperties().set("footerPan", true);
            pan.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
            pan.setDoubleClickReturnValue(true, 0);
            pan.onDragStart = [this] { mixer.session.beginMixerGesture(jaras::CommandKind::pan,id); };
            pan.onDragEnd = [this] { mixer.session.endMixerGesture(); };
            pan.onValueChange = [this] { command(jaras::CommandKind::pan, pan.getValue()); };
            special=std::make_unique<SpecialTrackControls>(mixer.session,id,[this](ID id,String action){if(mixer.specialAction)mixer.specialAction(id,action);});addAndMakeVisible(*special);
        }
        const jaras::Track *track() const {
            if (const auto *song = mixer.session.song())
                for (const auto &track : song->tracks)
                    if (track.id == id)
                        return &track;
            return nullptr;
        }
        void refresh() {
            if (const auto *t = track()) {
                fader.setValue(mixer.session.trackDisplayVolume(id, t->volume), dontSendNotification);
                fader.setEnabled(!mixer.session.trackFaderLocked(id));
                pan.setValue(t->pan, dontSendNotification);
                mute.setToggleState(t->mute, dontSendNotification);
                solo.setToggleState(t->solo, dontSendNotification);
                phase.setToggleState(t->phaseInverted.value_or(false), dontSendNotification);
                record.setButtonText(mixer.session.recordArm(id) == 2 ? "A" : "REC");
                record.setToggleState(mixer.session.recordingArmed(id), dontSendNotification);
                const auto settings = t->fxJSON ? JSON::parse(text(*t->fxJSON)) : var();
                firstSlot = jlimit(0, std::max(0,list(get(settings,"inserted")).size()-2), firstSlot);
                fx.setColour(TextButton::textColourOffId, fxchain::colour(settings));
                resized();repaint();
            }
        }
        void paint(Graphics &g) override {
            const auto *t = track();
            if (!t)
                return;
            const auto colour = theme::track(*t);
            g.fillAll(colour.withAlpha(.35f));
            if (mixer.selectedTrack(id)) { g.setColour(Colours::white.withAlpha(.08f)); g.fillAll(); }
            g.setColour(colour);
            g.fillRect(0, 0, getWidth(), 3);
            auto settings = t->fxJSON ? JSON::parse(text(*t->fxJSON)) : var();
            const auto chain = list(get(settings, "inserted"));
            for (int i = 0; jaras::fixedTrackName(t->role).empty() && i < 3; ++i) {
                g.setColour(Colours::black.withAlpha(.25f));
                g.fillRect(3, 5 + i * 21, getWidth() - 6, 20);
                const int slot = firstSlot + i;
                if (slot < chain.size()) {
                    if (!fxchain::enabled(settings, chain[slot].toString())) {
                        g.setColour(Colours::red.withAlpha(.8f)); g.fillRect(3, 5 + i * 21, getWidth() - 6, 20);
                    }
                    g.setColour(Colours::white);
                    g.setFont(theme::semiboldFont(10));
                    g.drawFittedText(effectTitle(settings, chain[slot].toString()),
                                     7, 5 + i * 21, getWidth() - 14, 20, Justification::centredLeft,
                                     1);
                }
                if (effectDropSlot == slot) { g.setColour(theme::green); g.fillRect(3, 5 + i * 21, getWidth() - 6, 2); }
            }
            const int controls = std::max(76, getHeight() - 218), meterTop = controls + 55,
                      meterBottom = getHeight() - 27;
            const auto levels = mixer.session.audio.meterLevels(id);
            for (int ch = 0; !jaras::isTeleprompterRole(t->role) && t->role.id!="chords" && ch < 2; ++ch)
                meterDisplay::bar(g, {70.f + ch * 5, (float)meterTop, 3, (float)(meterBottom - meterTop)}, levels[(size_t)ch]);
            const auto shownVolume = mixer.session.trackDisplayVolume(id, t->volume);
            const auto db = shownVolume > 0 ? String(Decibels::gainToDecibels(shownVolume), 1)
                                          : String::fromUTF8("−∞");
            g.setColour(Colours::white);
            if (jaras::fixedTrackName(t->role).empty()) {
                const int percent = roundToInt(std::abs(t->pan) * 100);
                g.setFont(theme::mediumFont(8));
                g.drawText(percent == 0 ? "Center" : String(t->pan < 0 ? "L-" : "R-") + String(percent) + "%",
                           28, controls - 3, 52, 10, Justification::centred);
            }
            g.setFont(theme::semiboldFont(9));
            if(!jaras::isTeleprompterRole(t->role)&&t->role.id!="chords")g.drawText((shownVolume >= 1 ? "+" : "") + db + " dB", 28, controls + 30, 52, 16,
                       Justification::centred);
            g.setFont(theme::semiboldFont(10));
            g.drawFittedText(text(t->name), 3, getHeight() - 24, getWidth() - 6, 20,
                             Justification::centred, 1);
        }
        void resized() override {
            const auto *t=track();const bool standard=t&&jaras::fixedTrackName(t->role).empty(),textTrack=t&&(jaras::isTeleprompterRole(t->role)||t->role.id=="chords");
            fx.setVisible(standard);record.setVisible(standard);pan.setVisible(standard);phase.setVisible(standard);fader.setVisible(!textTrack);mute.setVisible(standard||(t&&(t->role.id=="timecode"||t->role.id=="generatedClick")));solo.setVisible(mute.isVisible());
            if(special){special->setVisible(!standard);special->setBounds(4,5,getWidth()-8,70);special->refresh();}
            const int y = std::max(76, getHeight() - 218);
            fx.setBounds(4, y, 22, 21);
            mute.setBounds(4, y + 26, 22, 21);
            solo.setBounds(4, y + 52, 22, 21);
            phase.setBounds(4, y + 78, 22, 21);
            record.setBounds(3, y + 104, 25, 21);
            pan.setBounds(42, y + 7, 24, 24);
            fader.setBounds(31, y + 46, 31, std::max(25, getHeight() - y - 73));
        }
        void mouseDown(const MouseEvent &event) override {
            dragging = false; pressedEffect.clear(); pressedSlot = slotAt(event.getPosition());
            if (pressedSlot >= 0) {
                const auto settings = fxchain::settings(mixer.session, id);
                const auto chain = list(get(settings, "inserted"));
                if (pressedSlot < chain.size()) pressedEffect = chain[pressedSlot].toString();
                if (event.mods.isPopupMenu()) { if (pressedEffect.isNotEmpty()) showEffectMenu(pressedEffect); pressedSlot=-1; pressedEffect.clear(); }
                return;
            }
            mixer.selectTrack(id, event.mods);
            if (event.mods.isPopupMenu()) mixer.openContextMenu(id,event.getScreenPosition());
            else dragging=event.mods.isLeftButtonDown();
        }

        void mouseDrag(const MouseEvent &e) override {
            if (pressedEffect.isNotEmpty() && e.mods.isLeftButtonDown() && e.getDistanceFromDragStart() > 8) {
                auto description = object(); put(description, "type", "catlive-fx-copy");
                put(description, "project", text(mixer.session.project().id)); put(description, "source", text(id));
                put(description, "effect", pressedEffect);
                pressedEffect.clear(); pressedSlot = -1;
                mixer.startDragging(description, this); return;
            }
            if(dragging&&e.getDistanceFromDragStart()>8&&track()&&jaras::fixedTrackName(track()->role).empty()&&mixer.session.song()) {
                dragging=false;mixer.startDragging(trackDrop::description(mixer.session.project(),*mixer.session.song(),id),this);
            }
        }
        void mouseUp(const MouseEvent &e) override {
            if (pressedSlot >= 0 && !e.mods.isPopupMenu() && e.getDistanceFromDragStart() <= 8) mixer.openEffects(id,pressedEffect);
            dragging = false; pressedSlot = -1; pressedEffect.clear();
        }
        bool isInterestedInDragSource(const SourceDetails &d) override {
            if (isEffectDrag(d.description)) return track() && jaras::fixedTrackName(track()->role).empty();
            return mixer.session.song()&&!trackDrop::source(d.description,mixer.session.project(),*mixer.session.song()).empty();
        }
        void itemDragEnter(const SourceDetails &d) override {itemDragMove(d);}
        void itemDragMove(const SourceDetails &d) override {
            if (isEffectDrag(d.description)) {
                effectDropSlot = slotAt(d.localPosition); mixer.dropPreview.reset(); mixer.blocked.clear(); repaint(); return;
            }
            if(!mixer.session.song())return;
            mixer.dropPreview=trackDrop::resolve(*mixer.session.song(),trackDrop::source(d.description,mixer.session.project(),*mixer.session.song()),id,d.localPosition.x>getWidth()/2,d.localPosition.y<16);
            mixer.blocked=mixer.dropPreview?ID{}:id;mixer.repaint();
        }
        void itemDragExit(const SourceDetails &) override {effectDropSlot=-1;mixer.dropPreview.reset();mixer.blocked.clear();mixer.repaint();repaint();}
        void itemDropped(const SourceDetails &d) override {
            if (isEffectDrag(d.description)) {
                const int slot = slotAt(d.localPosition); itemDragExit(d);
                if (slot < 0) return;
                const auto chain = list(get(fxchain::settings(mixer.session, id), "inserted"));
                try {
                    mixer.session.copyEffect(utf8(str(d.description,"source")), str(d.description,"effect"), id,
                                             slot < chain.size() ? chain[slot].toString() : String());
                } catch (const std::exception &e) { mixer.error(String::fromUTF8(e.what())); }
                refresh(); return;
            }
            itemDragMove(d);const auto destination=mixer.dropPreview;const ID song=mixer.session.song()?mixer.session.song()->id:ID{};itemDragExit(d);
            if(destination)try{mixer.session.edit([&](jaras::Project &p){for(auto &s:p.songs)if(s.id==song)trackDrop::apply(s,*destination);});}catch(const std::exception &e){mixer.error(String::fromUTF8(e.what()));}
        }
        bool scrollEffects(const MouseEvent &event, const MouseWheelDetails &wheel) {
            if (slotAt(event.getPosition()) < 0) return false;
            const auto count = list(get(fxchain::settings(mixer.session,id),"inserted")).size();
            firstSlot = jlimit(0, std::max(0,count-2), firstSlot + (wheel.deltaY < 0 ? 1 : wheel.deltaY > 0 ? -1 : 0));
            repaint(); return true;
        }

      private:
        MixerPanel &mixer;
        ID id;
        bool dragging=false;
        int pressedSlot=-1, effectDropSlot=-1, firstSlot=0;
        String pressedEffect;
        int slotAt(Point<int> point) const {
            if (!track() || !jaras::fixedTrackName(track()->role).empty() ||
                !juce::Rectangle<int>(3,5,getWidth()-6,63).contains(point)) return -1;
            return firstSlot + (point.y-5)/21;
        }
        bool isEffectDrag(const var &description) const {
            return str(description,"type")=="catlive-fx-copy" && str(description,"project")==text(mixer.session.project().id);
        }
        static String effectTitle(const var &settings, const String &key) {
            for (const auto &plugin : list(get(settings,"externalPlugins"))) if (key=="External:"+str(plugin,"id")) return str(plugin,"name");
            for (const auto &instance : list(get(settings,"instances"))) if (key=="Native:"+str(instance,"id") || key=="Instance:"+str(instance,"id")) return str(instance,"kind");
            return key;
        }
        void showEffectMenu(String key) {
            const auto settings = fxchain::settings(mixer.session,id);
            PopupMenu menu; menu.addItem(1,"Bypass",true,!fxchain::enabled(settings,key)); menu.addItem(2,"Remover");
            menu.showMenuAsync(PopupMenu::Options().withTargetComponent(this),[safe=Component::SafePointer<Strip>(this),key](int result) {
                if (!safe || result==0) return;
                auto settings = fxchain::settings(safe->mixer.session,safe->id).clone();
                if (result==1) fxchain::setEnabled(settings,key,!fxchain::enabled(settings,key));
                else {
                    auto chain=list(get(settings,"inserted")); chain.removeAllInstancesOf(var(key)); put(settings,"inserted",chain);
                    for (const auto property : {"instances","externalPlugins"}) {
                        auto entries=list(get(settings,property));
                        for (int i=entries.size();--i>=0;) if (key.endsWith(":"+str(entries[i],"id"))) entries.remove(i);
                        put(settings,property,entries);
                    }
                }
                try { safe->mixer.session.configureEffects(safe->id,settings); }
                catch (const std::exception &e) { safe->mixer.error(String::fromUTF8(e.what())); }
            });
        }
        std::unique_ptr<SpecialTrackControls> special;
        QuietButton fx{"FX"}, mute{"M"}, solo{"S"}, phase{String::fromUTF8("Ø")}, record{"REC"};
        GainFader fader;
        ParameterSlider pan;
        std::set<ID> selection() const {
            std::set<ID> targets{id};
            if (mixer.selectedTrack(id))
                if (const auto *song = mixer.session.song())
                    for (const auto &t : song->tracks) if (mixer.selectedTrack(t.id)) targets.insert(t.id);
            return targets;
        }
        void command(jaras::CommandKind kind, double value = 0) {
            try {
                mixer.session.mixerCommand(kind, id, selection(), value);
            } catch (const std::exception &e) {
                mixer.error(String::fromUTF8(e.what()));
            }
        }
    };
    Session &session;
    std::function<void(ID,String)> openEffects;
    std::function<void(ID, ModifierKeys)> selectTrack;
    std::function<void(String)> error;
    std::function<void(ID, bool)> changeEffects;
    std::function<bool(ID)> selectedTrack;
    std::function<void(ID,Point<int>)> openContextMenu;
    std::function<void(ID,String)> specialAction;
    std::optional<trackDrop::Destination> dropPreview;ID blocked;
    Viewport viewport;
    Component content;
    OwnedArray<Strip> strips;
    std::vector<ID> ids;
    void timerCallback() override {
        if (isShowing())
            refresh();
    }
};
} // namespace catlive
