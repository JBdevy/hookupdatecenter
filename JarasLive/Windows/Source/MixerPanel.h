#pragma once
#include "Session.h"
#include "TrackInstrumentIcons.h"
#include "GainFader.h"
#include "MeterDisplay.h"
#include "FXChain.h"
#include "TrackDrop.h"
#include "SpecialTrackControls.h"
#include "RecordingOptionsPanel.h"
#include "HozMixerFocusGesture.h"
namespace catlive {
class MixerPanel final : public Component, public DragAndDropContainer, private Timer, private ScrollBar::Listener {
  public:
    MixerPanel(Session &owner, std::function<void(ID,String)> effects, std::function<void(ID, ModifierKeys)> selected,
               std::function<void(String)> failure, std::function<void(ID, bool)> chainAction,
               std::function<bool(ID)> isSelected, std::function<void(ID,Point<int>)> contextMenu, std::function<void(ID,String)> specialCallback = {},
               std::function<bool(ID)> visible = {})
        : session(owner), openEffects(std::move(effects)), selectTrack(std::move(selected)),
          error(std::move(failure)), changeEffects(std::move(chainAction)), selectedTrack(std::move(isSelected)), openContextMenu(std::move(contextMenu)),specialAction(std::move(specialCallback)),isTrackVisible(std::move(visible)) {
        master=std::make_unique<Strip>(*this,ID{});addAndMakeVisible(*master);
        viewport.setComponentID("mixerTracksViewport");horizontal.setComponentID("mixerHorizontalScroll");
        addAndMakeVisible(viewport);
        viewport.setViewedComponent(&content, false);
        // Wheel events bubble from the controls to this panel exactly once.
        // The hidden Viewport scrollbar must not apply a second wheel delta.
        viewport.setScrollBarsShown(false, false, false, false);
        addAndMakeVisible(horizontal);horizontal.setAutoHide(false);
        horizontal.setLookAndFeel(&scrollLook);horizontal.addListener(this);
        viewport.setScrollBarThickness(10);
        viewport.moved = [this] { refreshVisible(); syncScroll(); };
        startTimerHz(30);
        refresh();
    }
    ~MixerPanel() override {
        stopTimer();
        viewport.moved = {};
        horizontal.removeListener(this);horizontal.setLookAndFeel(nullptr);
        viewport.setViewedComponent(nullptr, false);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::background);
        g.setColour(theme::line);
        g.drawHorizontalLine(0, 0, (float)getWidth());
    }
    void resized() override {
        const int masterWidth=roundToInt(stripWidth*1.25f);
        const int trackStart=masterRight?0:masterWidth+3;
        const int trackWidth=std::max(1,getWidth()-masterWidth-3);
        master->setBounds(masterRight?std::max(0,getWidth()-masterWidth):0,20,masterWidth,std::max(1,getHeight()-20));
        horizontal.setBounds(trackStart+4,5,std::max(0,trackWidth-8),14);
        viewport.setBounds(trackStart,20,trackWidth,std::max(1,getHeight()-20));
        content.setSize(std::max(viewport.getWidth(), strips.size() * stripStride),
                        std::max(1, viewport.getHeight()));
        for (int i = 0; i < strips.size(); ++i)
            strips[i]->setBounds(i * stripStride, 0, stripWidth, content.getHeight());
        syncScroll();
    }
    void setMasterRight(bool right) {
        if(masterRight==right)return;
        masterRight=right;resized();repaint();
    }
    std::function<void(bool)> slotsOnlyChanged;
    bool isSlotsOnly() const { return slotsOnly; }
    void setSlotsOnly(bool enabled) {
        if(slotsOnly==enabled)return;
        slotsOnly=enabled;
        master->resized();master->repaint();
        for(auto *strip:strips){strip->resized();strip->repaint();}
        repaint();
    }
    void refresh() {
        const bool icons=trackIcons::visible(session.song());
        if(icons!=showsIcons){showsIcons=icons;master->resized();master->repaint();for(auto *strip:strips){strip->resized();strip->repaint();}}
        std::vector<ID> wanted;
        if (const auto *song = session.song())
            for (const auto &track : song->tracks)
                if ((jaras::fixedTrackName(track.role).empty() || track.role.id == "generatedClick")&&
                    (!isTrackVisible||isTrackVisible(track.id)))
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
        refreshVisible();
        syncScroll();
    }
    void refreshVisible() {
        master->refresh();
        const auto visible = viewport.getViewArea();
        for (auto *strip : strips)
            if (strip->getBounds().intersects(visible)) strip->refresh();
    }
    void mouseWheelMove(const MouseEvent &event, const MouseWheelDetails &wheel) override {
        if(event.mods.isShiftDown()) {
            if(const auto next=focusGesture.update(HozMixerFocusGesture::wheelDelta(wheel.deltaX,wheel.deltaY,wheel.isSmooth),
                                                   event.eventTime.toMilliseconds()/1000.,wheel.isInertial);
                next && *next!=slotsOnly) {
                setSlotsOnly(*next);if(slotsOnlyChanged)slotsOnlyChanged(*next);
            }
            return;
        }
        focusGesture.reset();
        if (master->getLocalBounds().contains(event.getEventRelativeTo(master.get()).getPosition())) {
            master->scrollEffects(event.getEventRelativeTo(master.get()),wheel);return;
        }
        for (auto *strip : strips) if (strip->getLocalBounds().contains(event.getEventRelativeTo(strip).getPosition()) &&
                                      strip->scrollEffects(event.getEventRelativeTo(strip), wheel)) return;
        const double delta=std::abs(wheel.deltaX)>std::abs(wheel.deltaY)?wheel.deltaX:wheel.deltaY;
        if(delta==0)return;
        const double desired=jlimit(0.,(double)std::max(0,content.getWidth()-viewport.getViewWidth()),
            viewport.getViewPositionX()+wheelRemainder-delta*320.);
        const int next=roundToInt(desired);
        wheelRemainder=desired-next;
        viewport.setViewPosition(next,0);
        syncScroll();
    }
    void syncScroll() {
        horizontal.setRangeLimits(0,std::max(1,content.getWidth()));
        horizontal.setCurrentRange(viewport.getViewPositionX(),viewport.getViewWidth(),dontSendNotification);
    }
    void scrollBarMoved(ScrollBar *,double position) override { wheelRemainder=0;viewport.setViewPosition(roundToInt(position),0); }
    int scrollX() const { return viewport.getViewPositionX(); }
    void paintOverChildren(Graphics &g) override {
        Graphics::ScopedSaveState saved(g);g.reduceClipRegion(viewport.getBounds());
        const ID target=dropPreview?dropPreview->indicator:blocked;auto at=std::find(ids.begin(),ids.end(),target);if(at==ids.end())return;
        auto *strip=strips[(int)std::distance(ids.begin(),at)];auto r=getLocalArea(strip,strip->getLocalBounds());
        if(dropPreview){g.setColour(dropPreview->joins?theme::yellow:theme::green);g.fillRect(dropPreview->after?r.getRight()-2:r.getX(),r.getY(),2,r.getHeight());}
        else{g.setColour(Colours::red);g.drawRect(r.reduced(2),2);}
    }

  private:
    friend struct MasterMixerTests;
    friend struct HozMixerFocusTests;
    class Strip final : public Component, public DragAndDropTarget {
      public:
        Strip(MixerPanel &owner, ID target) : mixer(owner), id(std::move(target)) {
            setComponentID(id.empty()?"mixerMaster":"mixerStrip:"+text(id));
            masterPresentation.name="Master";masterPresentation.role.id="other";
            fx.setComponentID("mixerFX");mute.setComponentID("mixerMute");solo.setComponentID("mixerSolo");
            phase.setComponentID("mixerPhase");record.setComponentID("mixerRecord");
            mono.setComponentID("mixerMono");mono.getProperties().set("icon","mono");
            mono.setWantsKeyboardFocus(false);
            phase.setTooltip("Inverter fase");
            mono.setColour(TextButton::buttonOnColourId,theme::display);
            mono.setColour(TextButton::textColourOnId,theme::green);
            mono.onClick=[this]{command(jaras::CommandKind::masterMono);};addChildComponent(mono);
            peak=std::make_unique<meterDisplay::PeakReadout>([this]{return mixer.session.audio.heldPeak(id);},[this]{mixer.session.audio.clearPeak(id);});addAndMakeVisible(*peak);
            for (auto *button : {&fx, &mute, &solo, &phase, &record}) {
                addAndMakeVisible(button);
                button->getProperties().set("flat", true);
                button->getProperties().set("fontSize", 11);
                button->setWantsKeyboardFocus(false);
                button->setColour(TextButton::buttonColourId, Colours::white.withAlpha(.15f));
            }
            for (auto *button : {&fx, &mute, &solo, &record})
                button->setColour(TextButton::buttonColourId, Colour(0xff414141));
            mute.setColour(TextButton::buttonOnColourId, Colour(0xffff4444));
            solo.setColour(TextButton::buttonOnColourId, theme::yellow);
            if (id.empty()) {
                for (auto *button : {&fx, &mute, &solo}) {
                    button->getProperties().set("macMasterControl", true);
                    button->getProperties().set("compactTrackStyle", true);
                    button->setColour(TextButton::buttonColourId, Colours::white.withAlpha(.12f));
                    button->setColour(TextButton::textColourOffId, Colours::white);
                    button->setColour(TextButton::textColourOnId, Colours::black);
                }
                mute.setColour(TextButton::buttonOnColourId, Colour(0xffff4245));
                mono.getProperties().set("flat", true);
                mono.setColour(TextButton::buttonColourId, Colours::transparentBlack);
                mono.setColour(TextButton::buttonOnColourId, Colours::transparentBlack);
                mono.setColour(TextButton::textColourOffId, Colours::white);
            }
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
            if(id.empty()) return &masterPresentation;
            if (const auto *song = mixer.session.song())
                for (const auto &track : song->tracks)
                    if (track.id == id)
                        return &track;
            return nullptr;
        }
        void refresh() {
            if(id.empty()) {
                const auto &project=mixer.session.project();
                masterPresentation.volume=project.masterVolume;masterPresentation.pan=project.masterPan;
                masterPresentation.mute=project.masterMute;masterPresentation.solo=project.masterSolo;
                masterPresentation.color=project.masterColor.value_or(0x414141);
                if (masterPresentation.fxJSON != project.masterFXJSON) {
                    masterPresentation.fxJSON = project.masterFXJSON;
                    cachedFXRevision = ~uint64(0);
                }
                mono.setToggleState(project.masterMono,dontSendNotification);
                mono.setTooltip(project.masterMono ? String::fromUTF8("Mono - Alternar para estéreo")
                                                  : String::fromUTF8("Estéreo - Alternar para mono"));
            }
            if (const auto *t = track()) {
                const auto volume = id.empty() ? t->volume : mixer.session.trackDisplayVolume(id,t->volume);
                const auto selected = !id.empty() && mixer.selectedTrack(id);
                const auto levels = mixer.slotsOnly ? std::array<float,2>{} : mixer.session.audio.meterLevels(id);
                if (lastRevision == mixer.session.revision && lastSelection == selected &&
                    lastVolume == volume && lastLocked == mixer.session.trackFaderLocked(id)) {
                    if (!mixer.slotsOnly && lastLevels != levels) {
                        const auto bounds = fader.getBounds();
                        repaint(69 + controlsOffset(), bounds.getY(), 12, bounds.getHeight());
                    }
                    lastLevels = levels;
                    return;
                }
                lastRevision = mixer.session.revision; lastSelection = selected;
                lastVolume = volume; lastLocked = mixer.session.trackFaderLocked(id); lastLevels = levels;
                fader.setValue(id.empty()?t->volume:mixer.session.trackDisplayVolume(id,t->volume),dontSendNotification);
                fader.setEnabled(!mixer.session.trackFaderLocked(id));
                pan.setValue(t->pan, dontSendNotification);
                mute.setToggleState(t->mute, dontSendNotification);
                solo.setToggleState(t->solo, dontSendNotification);
                phase.setToggleState(t->phaseInverted.value_or(false), dontSendNotification);
                phase.setTooltip(t->phaseInverted.value_or(false) ? "Fase invertida - Restaurar fase" : "Inverter fase");
                record.setButtonText(mixer.session.recordArm(id) == 2 ? "A" : "");
                record.getProperties().set("icon", mixer.session.recordArm(id) == 2 ? "" : "record.circle");
                record.setToggleState(mixer.session.recordingArmed(id), dontSendNotification);
                const auto &settings = slotSettings();
                firstSlot = jlimit(0, maximumFirstSlot(), firstSlot);
                fx.setColour(TextButton::textColourOffId, fxchain::colour(settings, id.empty()));
                resized();repaint();
            }
        }
        void paint(Graphics &g) override {
            const auto *t = track();
            if (!t)
                return;
            const auto colour = theme::track(*t);
            g.fillAll(colour.withAlpha(.35f));
            if (!id.empty() && mixer.selectedTrack(id)) { g.setColour(Colours::white.withAlpha(.08f)); g.fillAll(); }
            g.setColour(colour);
            g.fillRect(0, 0, getWidth(), 3);
            const auto &settings = slotSettings();
            const auto chain = list(get(settings, "inserted"));
            const auto geometry = layout();
            if (jaras::fixedTrackName(t->role).empty() && !geometry.slots.isEmpty()) {
                Graphics::ScopedSaveState saved(g);g.reduceClipRegion(geometry.slots.withWidth(getWidth()-4));
                for (int i = 0; i < visibleSlots(); ++i) {
                    const auto bounds=geometry.slots.withY(geometry.slots.getY()+i*21).withHeight(20);
                    g.setColour(Colours::black.withAlpha(.25f));g.fillRect(bounds);
                    const int slot=firstSlot+i;
                    if (slot < chain.size()) {
                        g.setColour(fxchain::enabled(settings,chain[slot].toString())
                            ? Colour(0xff00ff00) : Colour(0xffff0000));
                        g.setFont(theme::semiboldFont(10));
                        g.drawFittedText(effectTitle(settings,chain[slot].toString()),bounds.reduced(4,0),Justification::centredLeft,1,1.f);
                    }
                    if (effectDropSlot==slot || hoveredSlot==slot) {
                        g.setColour(effectDropSlot==slot ? theme::green.withAlpha(.3f) : Colours::white.withAlpha(.09f));
                        g.fillRect(bounds);
                    }
                }
                if (maximumFirstSlot()>0) {
                    const float height=(float)geometry.slots.getHeight(),total=(float)totalSlots()*21;
                    const float thumb=std::min(height,height*height/total);
                    const float y=geometry.slots.getY()+(height-thumb)*firstSlot/maximumFirstSlot();
                    g.setColour(theme::green.withAlpha(.15f));g.fillRoundedRectangle(getWidth()-3.f,(float)geometry.slots.getY(),2,height,1);
                    g.setColour(theme::green);g.fillRoundedRectangle(getWidth()-3.f,y,2,thumb,1);
                }
            }
            if(!mixer.slotsOnly) {
            const int controls = geometry.controlsY;
            const auto meterBounds=fader.getBounds();
            const int meterTop=meterBounds.getY()+4,meterBottom=meterBounds.getBottom()-4;
            const auto levels = mixer.session.audio.meterLevels(id);
            for (int ch = 0; !jaras::isTeleprompterRole(t->role) && t->role.id!="chords" && ch < 2; ++ch)
                meterDisplay::bar(g, {70.f + controlsOffset() + ch * 5, (float)meterTop, 3, (float)(meterBottom - meterTop)}, levels[(size_t)ch]);
            const auto shownVolume = id.empty()?t->volume:mixer.session.trackDisplayVolume(id,t->volume);
            const auto db = shownVolume > 0 ? String(Decibels::gainToDecibels(shownVolume), 1)
                                          : String::fromUTF8("−∞");
            g.setColour(Colours::white);
            if (jaras::fixedTrackName(t->role).empty()) {
                const int percent = roundToInt(std::abs(t->pan) * 100);
                g.setFont(theme::mediumFont(8));
                g.drawText(percent == 0 ? "Center" : String(t->pan < 0 ? "L-" : "R-") + String(percent) + "%",
                           28+controlsOffset(), controls, 52, 10, Justification::centred);
            }
            g.setFont(theme::semiboldFont(9));
            if(!jaras::isTeleprompterRole(t->role)&&t->role.id!="chords")g.drawText((shownVolume >= 1 ? "+" : "") + db + " dB", 28+controlsOffset(), controls + (jaras::fixedTrackName(t->role).empty()?36:25), 52, 12,
                       Justification::centred);
            }
            g.setColour(Colours::white);g.setFont(theme::semiboldFont(10));
            g.drawFittedText(text(t->name), geometry.name, Justification::centred, 1, 1.f);
            if(mixer.showsIcons && !id.empty()) if(const auto *icon=trackIcons::find(t->instrumentIcon))
                trackIcons::draw(g,*icon,{(getWidth()-26.f)/2,(float)geometry.name.getBottom()+2,26,26});
        }
        void resized() override {
            const auto *t=track();const bool standard=t&&jaras::fixedTrackName(t->role).empty(),textTrack=t&&(jaras::isTeleprompterRole(t->role)||t->role.id=="chords");
            if(mixer.slotsOnly) {
                for(auto *control:std::initializer_list<Component*>{&fx,&mute,&solo,&phase,&record,&mono,&pan,&fader,peak.get(),special.get()})
                    control->setVisible(false);
                firstSlot=jlimit(0,maximumFirstSlot(),firstSlot);
                return;
            }
            fx.setVisible(standard);record.setVisible(standard&&!id.empty());pan.setVisible(standard);phase.setVisible(standard&&!id.empty());mono.setVisible(id.empty());fader.setVisible(!textTrack);mute.setVisible(standard||(t&&(t->role.id=="timecode"||t->role.id=="generatedClick")));solo.setVisible(mute.isVisible());
            const auto geometry=layout();
            firstSlot=jlimit(0,maximumFirstSlot(),firstSlot);
            const int y=geometry.controlsY,available=geometry.controlsHeight;
            if(special){special->setVisible(!standard);special->setBounds((getWidth()-47)/2,y,47,21);special->refresh();}
            const int gap=jlimit(2,5,(available-117)/5);
            const int buttonHeight=std::min(21,std::max(16,(available-12-5*gap)/5));
            const int step=buttonHeight+gap;
            peak->setVisible(!textTrack);
            fx.setBounds(4,y,22,buttonHeight);
            mute.setBounds(4,y+(standard?step:25),22,buttonHeight);
            solo.setBounds(4,y+(standard?2*step:25+step),22,buttonHeight);
            phase.setBounds(4,y+3*step,22,buttonHeight);mono.setBounds(4,y+3*step,22,buttonHeight);
            record.setBounds(3,y+4*step,25,buttonHeight);
            peak->setBounds(1,y+(standard?5*step:25+2*step),43,12);
            pan.setBounds(42+controlsOffset(),y+11,24,24);
            const int faderOffset=standard?49:38;
            fader.setBounds(31+controlsOffset(),y+faderOffset,31,std::max(1,available-faderOffset));
        }
        void mouseMove(const MouseEvent &event) override { const int next=slotAt(event.getPosition());if(next!=hoveredSlot){hoveredSlot=next;repaint();} }
        void mouseExit(const MouseEvent &) override {hoveredSlot=-1;repaint();}
        void mouseDown(const MouseEvent &event) override {
            dragging = false; pressedEffect.clear(); pressedSlot = slotAt(event.getPosition());
            if (pressedSlot >= 0) {
                const auto settings = fxchain::settings(mixer.session, id);
                const auto chain = list(get(settings, "inserted"));
                if (pressedSlot < chain.size()) pressedEffect = chain[pressedSlot].toString();
                if (event.mods.isPopupMenu()) { if (pressedEffect.isNotEmpty()) showEffectMenu(pressedEffect); pressedSlot=-1; pressedEffect.clear(); }
                return;
            }
            if (id.empty()) {
                if(event.mods.isPopupMenu())mixer.openContextMenu(id,event.getScreenPosition());
                return;
            }
            mixer.selectTrack(id, event.mods);
            if (event.mods.isPopupMenu()) mixer.openContextMenu(id,event.getScreenPosition());
            else dragging=event.mods.isLeftButtonDown();
        }

        void mouseDrag(const MouseEvent &e) override {
            if (!id.empty() && pressedEffect.isNotEmpty() && e.mods.isLeftButtonDown() && e.getDistanceFromDragStart() > 8) {
                auto description = object(); put(description, "type", "catlive-fx-copy");
                put(description, "project", text(mixer.session.project().id)); put(description, "source", text(id));
                put(description, "effect", pressedEffect);
                pressedEffect.clear(); pressedSlot = -1;
                Image preview(Image::ARGB, std::max(1,getWidth()-6),20,true);
                { Graphics g(preview);g.setColour(Colours::white);g.setFont(theme::semiboldFont(10));
                  g.drawText(effectTitle(fxchain::settings(mixer.session,id),str(description,"effect")),preview.getBounds().reduced(4,0),Justification::centredLeft,true); }
                mixer.startDragging(description, this, ScaledImage(preview),true); return;
            }
            if(dragging&&e.getDistanceFromDragStart()>8&&track()&&jaras::fixedTrackName(track()->role).empty()&&mixer.session.song()) {
                dragging=false;mixer.startDragging(trackDrop::description(mixer.session.project(),*mixer.session.song(),id),this);
            }
        }
        void mouseUp(const MouseEvent &e) override {
            if (pressedSlot >= 0 && !e.mods.isPopupMenu() && e.getDistanceFromDragStart() <= 8) {
                if (e.mods.isAltDown() || e.mods.isShiftDown()) {
                    if (pressedEffect.isNotEmpty()) changeEffect(pressedEffect,e.mods.isAltDown());
                } else mixer.openEffects(id,pressedEffect);
            }
            dragging = false; pressedSlot = -1; pressedEffect.clear();
        }
        bool isInterestedInDragSource(const SourceDetails &d) override {
            if(id.empty()) return false;
            if (isEffectDrag(d.description)) return track() && jaras::fixedTrackName(track()->role).empty();
            return mixer.session.song()&&!trackDrop::source(d.description,mixer.session.project(),*mixer.session.song()).empty();
        }
        void itemDragEnter(const SourceDetails &d) override {itemDragMove(d);}
        void itemDragMove(const SourceDetails &d) override {
            if(id.empty()) return;
            if (isEffectDrag(d.description)) {
                effectDropSlot = slotAt(d.localPosition); mixer.dropPreview.reset(); mixer.blocked.clear(); repaint(); return;
            }
            if(!mixer.session.song())return;
            mixer.dropPreview=trackDrop::resolve(*mixer.session.song(),trackDrop::source(d.description,mixer.session.project(),*mixer.session.song()),id,d.localPosition.x>getWidth()/2,d.localPosition.y<16);
            mixer.blocked=mixer.dropPreview?ID{}:id;mixer.repaint();
        }
        void itemDragExit(const SourceDetails &) override {effectDropSlot=-1;mixer.dropPreview.reset();mixer.blocked.clear();mixer.repaint();repaint();}
        void itemDropped(const SourceDetails &d) override {
            if(id.empty()) return;
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
            if (std::abs(wheel.deltaX)>std::abs(wheel.deltaY) || event.mods.isShiftDown() || wheel.deltaY==0 ||
                !track() || !jaras::fixedTrackName(track()->role).empty()) return false;
            const auto bounds=layout().slots;
            if (bounds.isEmpty() || maximumFirstSlot()==0) return false;
            // Include the two-pixel FX scroll rail, without widening slot clicks/drags.
            if(!bounds.withWidth(getWidth()-4).contains(event.getPosition()))return false;
            firstSlot=jlimit(0,maximumFirstSlot(),firstSlot+(wheel.deltaY<0?1:-1));
            hoveredSlot=slotAt(event.getPosition());repaint(); return true;
        }

      private:
        MixerPanel &mixer;
        ID id;
        jaras::Track masterPresentation; // View state only; Master is never added to the song's tracks.
        uint64 lastRevision = ~uint64(0);
        bool lastSelection = false, lastLocked = false;
        double lastVolume = -1;
        std::array<float, 2> lastLevels{};
        mutable std::optional<std::string> cachedFX;
        mutable var cachedSettings;
        mutable uint64 cachedFXRevision = ~uint64(0);
        const var &slotSettings() const {
            if (cachedFXRevision == mixer.session.revision) return cachedSettings;
            const auto *t = track();
            const std::optional<std::string> empty;
            const auto &source = t ? t->fxJSON : empty;
            if (cachedFX != source) {
                cachedFX = source;
                cachedSettings = source ? JSON::parse(text(*source)) : var();
            }
            cachedFXRevision = mixer.session.revision;
            return cachedSettings;
        }
        // Reserve the peak's full two-decimal text width before the fader.
        int controlsOffset() const { return 17 + std::max(0,(getWidth()-stripWidth)/2); }
        bool dragging=false;
        int pressedSlot=-1, effectDropSlot=-1, firstSlot=0, hoveredSlot=-1;
        String pressedEffect;
        friend struct MasterMixerTests;
        friend struct HozMixerFocusTests;
        struct StripLayout { juce::Rectangle<int> slots,name;int controlsY=0,controlsHeight=0; };
        StripLayout layout() const {
            const int height=std::max(1,getHeight()-(mixer.showsIcons?30:0));
            if(mixer.slotsOnly) {
                const int nameTop=std::max(3,height-26);
                return {{3,13,std::max(0,getWidth()-6),std::max(0,nameTop-17)},
                        {3,nameTop,std::max(0,getWidth()-6),std::min(22,std::max(0,height-nameTop))},nameTop,0};
            }
            // Match FooterMixerStrip: the docked panel hides FX at 255 pt and below.
            // The 22 pt allowance accounts for the Mac host's inset/chrome beyond
            // this strip's bounds; growth above the threshold belongs to FX slots.
            const int inner=std::max(0,height-22);
            const int controls=std::min(187,std::max(100,inner-26));
            const int slots=std::max(0,inner-controls-26);
            return {{3,13,std::max(0,getWidth()-6),slots},
                    {3,13+slots+controls+4,std::max(0,getWidth()-6),22},13+slots,controls};
        }
        int totalSlots() const {return std::max(3,list(get(slotSettings(),"inserted")).size()+1);}
        int maximumFirstSlot() const {
            const int height=layout().slots.getHeight();
            return height<=0?0:jlimit(0,totalSlots()-1,(totalSlots()*21-height+19)/21);
        }
        int visibleSlots() const {
            return std::min(totalSlots()-firstSlot,(layout().slots.getHeight()+20)/21);
        }
        int slotAt(Point<int> point) const {
            const auto bounds=layout().slots;
            if (!track() || !jaras::fixedTrackName(track()->role).empty() || !bounds.contains(point))return -1;
            const int slot=firstSlot+(point.y-bounds.getY())/21;
            return slot<totalSlots()?slot:-1;
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
                safe->changeEffect(key,result==2);
            });
        }
        void changeEffect(const String &key,bool remove) {
            auto settings=fxchain::settings(mixer.session,id).clone();
            if(!remove) fxchain::setEnabled(settings,key,!fxchain::enabled(settings,key));
            else {
                auto chain=list(get(settings,"inserted"));chain.removeAllInstancesOf(var(key));put(settings,"inserted",chain);
                for(const auto property:{"instances","externalPlugins"}) {
                    auto entries=list(get(settings,property));
                    for(int i=entries.size();--i>=0;) if(key.endsWith(":"+str(entries[i],"id"))) entries.remove(i);
                    put(settings,property,entries);
                }
            }
            try { mixer.session.configureEffects(id,settings);refresh(); }
            catch(const std::exception &e) { mixer.error(String::fromUTF8(e.what())); }
        }

        std::unique_ptr<meterDisplay::PeakReadout> peak;
        std::unique_ptr<SpecialTrackControls> special;
        QuietButton fx{"FX"}, mute{"M"}, solo{"S"}, phase{String::fromUTF8("Ø")}, record{"REC"}, mono;
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
                if(id.empty()) mixer.session.command(kind,{},value);
                else mixer.session.mixerCommand(kind,id,selection(),value);
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
    std::function<bool(ID)> isTrackVisible;
    bool masterRight=false,slotsOnly=false,showsIcons=false;
    HozMixerFocusGesture focusGesture;
    double wheelRemainder=0;
    std::optional<trackDrop::Destination> dropPreview;ID blocked;
    struct MixerScrollLook final : LookAndFeel_V4 {
        bool areScrollbarButtonsVisible() override { return false; }
        void drawScrollbar(Graphics &g,ScrollBar &,int x,int y,int w,int h,bool,int start,int size,bool,bool) override {
            g.setColour(Colour::fromFloatRGBA(.12f,.12f,.12f,1));g.fillRoundedRectangle((float)x,y+h/2.f-3,(float)w,6,3);
            g.setColour(Colour(0xff54ff93));g.fillRoundedRectangle((float)start,y+h/2.f-3,(float)size,6,3);
        }
    } scrollLook;
    struct MixerHorizontalScroll final : ScrollBar {
        MixerHorizontalScroll():ScrollBar(false) {}
        void mouseWheelMove(const MouseEvent &event,const MouseWheelDetails &wheel) override {
            if(event.mods.isShiftDown()) Component::mouseWheelMove(event,wheel);
            else ScrollBar::mouseWheelMove(event,wheel);
        }
    } horizontal;
    static constexpr int stripWidth=100,stripStride=stripWidth+3;
    std::unique_ptr<Strip> master;
    struct MixerViewport final : Viewport {
        std::function<void()> moved;
        void visibleAreaChanged(const juce::Rectangle<int> &) override { if (moved) moved(); }
    } viewport;
    Component content;
    OwnedArray<Strip> strips;
    std::vector<ID> ids;
    void timerCallback() override {
        if (isShowing())
            refresh();
    }
};
} // namespace catlive
