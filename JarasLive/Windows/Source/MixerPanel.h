#pragma once
#include "Localization.h"
#include "Session.h"
#include "TrackInstrumentArtwork.h"
#include "GainFader.h"
#include "MeterDisplay.h"
#include "FXChain.h"
#include "InstrumentAssets.h"
#include "TrackDrop.h"
#include "SpecialTrackControls.h"
#include "RecordingOptionsPanel.h"
#include "MixerSlotLayout.h"
#include "InlineMixerTrackName.h"
#include "VST3Catalog.h"
#include "ModalSheet.h"
namespace catlive {
struct MixerScrollLook final : LookAndFeel_V4 {
    bool areScrollbarButtonsVisible() override { return false; }
    void drawScrollbar(Graphics &g, ScrollBar &, int x, int y, int width, int height,
                       bool vertical, int start, int size, bool, bool) override {
        g.setColour(theme::scrollRail);
        if (vertical) g.fillRoundedRectangle(x + width / 2.f - 3, (float)y, 6, (float)height, 3);
        else g.fillRoundedRectangle((float)x, y + height / 2.f - 3, (float)width, 6, 3);
        g.setColour(Colour(0xff54ff93));
        if (vertical) g.fillRoundedRectangle(x + width / 2.f - 3, (float)start, 6, (float)size, 3);
        else g.fillRoundedRectangle((float)start, y + height / 2.f - 3, (float)size, 6, 3);
    }
};

class MixerPanel final : public Component, public DragAndDropContainer, private Timer, private ScrollBar::Listener {
  public:
    MixerPanel(Session &owner, std::function<void(ID,String)> effects, std::function<void(ID, ModifierKeys)> selected,
               std::function<void(String)> failure, std::function<void(ID, bool)> chainAction,
               std::function<bool(ID)> isSelected, std::function<void(ID,Point<int>)> contextMenu, std::function<void(ID,String)> specialCallback = {},
               std::function<bool(ID)> visible = {}, std::function<ID()> focus = {})
        : session(owner), openEffects(std::move(effects)), selectTrack(std::move(selected)),
          error(std::move(failure)), changeEffects(std::move(chainAction)), selectedTrack(std::move(isSelected)), openContextMenu(std::move(contextMenu)),specialAction(std::move(specialCallback)),isTrackVisible(std::move(visible)),focusedTrack(std::move(focus)) {
        masterRight = bool(focusedTrack);
        master=std::make_unique<Strip>(*this,ID{});addAndMakeVisible(*master);
        viewport.setComponentID("mixerTracksViewport");horizontal.setComponentID("mixerHorizontalScroll");
        addAndMakeVisible(viewport);

        viewport.setViewedComponent(&content, false);
        content.doubleClicked = [this](const MouseEvent &event) {
            if (addTrackInEmptyArea && event.mods.isLeftButtonDown() && !event.mods.isAnyModifierKeyDown() &&
                event.x >= strips.size() * stripStride)
                addTrackInEmptyArea();
        };
        // Wheel events bubble from the controls to this panel exactly once.
        // The hidden Viewport scrollbar must not apply a second wheel delta.
        viewport.setScrollBarsShown(false, false, false, false);
        addChildComponent(horizontal);horizontal.setVisible(!focusedTrack);horizontal.setAutoHide(false);
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
    static constexpr int focusWidth() { return 2 * masterStripWidth + 10; }
    void resized() override {
        const int inset = focusedTrack ? 5 : 0;
        const int stripTop = focusedTrack ? inset : 20;
        const int stripHeight = std::max(1, getHeight() - stripTop - inset);
        const int innerWidth = std::max(0, getWidth() - 2 * inset);
        const int masterWidth = focusedTrack ? (strips.isEmpty() ? innerWidth : innerWidth / 2) : masterStripWidth;
        const int trackStart = inset + (masterRight ? 0 : masterWidth + 3);
        const int trackWidth = std::max(0, innerWidth - masterWidth - (focusedTrack ? 0 : 3));
        master->setBounds(masterRight?std::max(inset,getWidth()-inset-masterWidth):inset,stripTop,masterWidth,stripHeight);
        horizontal.setBounds(trackStart+4,5,std::max(0,trackWidth-8),14);
        viewport.setBounds(trackStart,stripTop,trackWidth,stripHeight);
        const int trailingSpace = focusedTrack ? 0 : (stripStride * 3 + 1) / 2;
        content.setSize(focusedTrack ? trackWidth : std::max(viewport.getWidth(), strips.size() * stripStride + trailingSpace),
                        std::max(1, viewport.getHeight()));
        for (int i = 0; i < strips.size(); ++i)
            strips[i]->setBounds(i * stripStride, 0, focusedTrack ? trackWidth : stripWidth, content.getHeight());
        syncScroll();
    }
    void setMasterRight(bool right) {
        if(masterRight==right)return;
        masterRight=right;resized();repaint();
    }
    void revealTrack(const ID &id) {
        const auto at = std::find(ids.begin(), ids.end(), id);
        if (at == ids.end()) return;
        const int index = int(at - ids.begin());
        const int left = index * stripStride, right = left + stripWidth;
        const auto visible = viewport.getViewArea();
        if (left < visible.getX()) viewport.setViewPosition(left, 0);
        else if (right > visible.getRight()) viewport.setViewPosition(std::max(0, right - visible.getWidth()), 0);
        refreshVisible(); syncScroll();
    }
    std::function<void()> addTrackInEmptyArea;
    std::function<void(const ID &, jaras::CommandKind)> mapControl;
    void setStripeOnly(bool enabled) {
        if (stripeOnly == enabled) return;
        stripeOnly = enabled;
        repaint();
    }
    void refresh() {
        std::vector<ID> wanted;
        if (focusedTrack) {
            lastFocusedTrack = focusedTrack();
            if (const auto *song = session.song(); song && !lastFocusedTrack.empty() &&
                std::any_of(song->tracks.begin(), song->tracks.end(), [&](const auto &track) { return track.id == lastFocusedTrack; }))
                wanted.push_back(lastFocusedTrack);
        } else if (const auto *song = session.song()) {
            for (const auto &track : song->tracks)
                if ((jaras::fixedTrackName(track.role).empty() || track.role.id == "generatedClick")&&
                    (!isTrackVisible||isTrackVisible(track.id)))
                    wanted.push_back(track.id);
        }
        if (wanted != ids) {
            std::map<ID, std::unique_ptr<Strip>> retained;
            for (int index = strips.size(); --index >= 0;)
                retained.emplace(ids[size_t(index)], std::unique_ptr<Strip>(strips.removeAndReturn(index)));
            ids = std::move(wanted);
            for (const auto &id : ids) {
                const auto found = retained.find(id);
                if (found != retained.end()) strips.add(found->second.release());
                else {
                    auto *strip = strips.add(new Strip(*this, id));
                    content.addAndMakeVisible(strip);
                }
            }
            resized();
            repaint();
        }
        refreshVisible();
        syncScroll();
    }
    void refreshVisible() {
        master->refresh();
        const auto visible = viewport.getViewArea();
        const int first = std::max(0, visible.getX() / stripStride);
        const int end = std::min(strips.size(), (visible.getRight() + stripStride - 1) / stripStride);
        for (int index = first; index < end; ++index) {
            auto *strip = strips[index];
            if (strip->getBounds().intersects(visible)) {
                strip->ensureControlLayout();
                strip->refresh();
            }
        }
    }
    void mouseWheelMove(const MouseEvent &event, const MouseWheelDetails &wheel) override {
        if (master->getLocalBounds().contains(event.getEventRelativeTo(master.get()).getPosition())) {
            master->scrollEffects(event.getEventRelativeTo(master.get()),wheel);return;
        }
        const auto point = event.getEventRelativeTo(&content).getPosition();
        const int index = point.x < 0 ? -1 : point.x / stripStride;
        if (isPositiveAndBelow(index, strips.size())) {
            auto *strip = strips[index];
            const auto local = event.getEventRelativeTo(strip);
            if (strip->getLocalBounds().contains(local.getPosition()) && strip->scrollEffects(local, wheel)) return;
        }
        if (focusedTrack) return;
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
    class SendCalloutLook final : public LookAndFeel_V4 {
    public:
        void drawCallOutBoxBackground(CallOutBox &, Graphics &g, const Path &path, Image &) override {
            DropShadow(Colours::black.withAlpha(.4f), 5, {0, 2}).drawForPath(g, path);
            g.setColour(theme::lightDarkPanel); g.fillPath(path);
            g.setColour(Colour(0xff494949)); g.strokePath(path, PathStrokeType(1.f));
        }
    };
    class SendPicker final : public Component {
    public:
        struct Destination { ID id; String name; bool enabled; bool current; };
        static constexpr int blockSize = 20, rowHeight = 21, headingHeight = 28;
        SendPicker(const std::vector<Destination> &rows, const std::function<void(ID)> &choose) {
            viewport.setViewedComponent(&content, false);
            viewport.setScrollBarsShown(true, true);
            viewport.setScrollBarThickness(10);
            viewport.setComponentID("sendDestinationViewport");
            addAndMakeVisible(viewport);
            for (size_t row = 0; row < rows.size(); ++row) {
                if (row % blockSize == 0) {
                    auto *label = headers.add(new Label());
                    label->setText(String(int(row + 1)) + String::fromUTF8("–") + String(int(std::min(rows.size(), row + blockSize))), dontSendNotification);
                    label->setFont(theme::semiboldFont(12));
                    content.addAndMakeVisible(label);
                }
                const auto &entry = rows[row];
                const auto number = row < 9 ? "0" + String(int(row + 1)) : String(int(row + 1));
                auto *button = buttons.add(new TextButton(number + "  " + entry.name));
                button->setComponentID("sendDestination:" + text(entry.id));
                button->getProperties().set("flat", true);
                button->getProperties().set("buttonJustification", (int)Justification::centredLeft);
                button->setTooltip(entry.name);
                button->setToggleState(entry.current, dontSendNotification);
                button->setColour(TextButton::buttonColourId, row % 2 ? theme::lightDarkDisplay : theme::lightDarkPanel);
                button->setColour(TextButton::buttonOnColourId, theme::green.withAlpha(.25f));
                button->setEnabled(entry.enabled);
                button->onClick = [this, choose, id = entry.id] {
                    if (auto* popup = findParentComponentOfClass<CallOutBox>()) popup->dismiss();
                    MessageManager::callAsync([choose, id] { choose(id); });
                };
                content.addAndMakeVisible(button);
            }
        }
        void resized() override {
            viewport.setBounds(getLocalBounds().reduced(10));
            const int visibleColumns = std::max(1, std::min(3, headers.size()));
            const int width = std::max(1, (viewport.getWidth() - (visibleColumns - 1) * 8) / visibleColumns);
            const int columns = headers.size();
            const int height = headingHeight + std::min(blockSize, buttons.size()) * rowHeight;
            content.setSize(width * columns + std::max(0, columns - 1) * 8, height);
            for (int i = 0; i < columns; ++i) headers[i]->setBounds(i * (width + 8), 0, width, headingHeight);
            for (int i = 0; i < buttons.size(); ++i)
                buttons[i]->setBounds((i / blockSize) * (width + 8), headingHeight + (i % blockSize) * rowHeight, width, rowHeight);
        }
    private:
        Component content;
        Viewport viewport;
        OwnedArray<Label> headers;
        OwnedArray<TextButton> buttons;
    };
    class Strip final : public Component, public DragAndDropTarget {
      public:
        Strip(MixerPanel &owner, ID target) : mixer(owner), id(std::move(target)) {
            setComponentID(id.empty()?"mixerMaster":"mixerStrip:"+text(id));
            masterPresentation.name="Main";masterPresentation.role.id="other";
            fx.setComponentID("mixerFX");mute.setComponentID("mixerMute");solo.setComponentID("mixerSolo");
            record.setComponentID("mixerRecord");
            mono.setComponentID("mixerMono");mono.getProperties().set("icon","mono");
            mono.setWantsKeyboardFocus(false);
            mono.setColour(TextButton::buttonOnColourId,theme::display);
            mono.setColour(TextButton::textColourOnId,theme::green);
            mono.onClick=[this]{command(jaras::CommandKind::masterMono);};addChildComponent(mono);
            peak=std::make_unique<meterDisplay::PeakReadout>([this]{return mixer.session.audio.heldPeak(id);},[this]{mixer.session.audio.clearPeak(id);});addAndMakeVisible(*peak);
            for (auto *button : {&fx, &mute, &solo, &record, &monitor, &phase}) {
                if (button != &phase || !id.empty()) addAndMakeVisible(button);
                button->getProperties().set("flat", true);
                button->getProperties().set("fontSize", 11);
                button->setWantsKeyboardFocus(false);
                button->setColour(TextButton::buttonColourId, theme::trackControl);
            }
            mute.setColour(TextButton::buttonOnColourId, Colour(0xffff4444));
            solo.setColour(TextButton::buttonOnColourId, theme::yellow);
            if (id.empty()) {
                for (auto *button : {&fx, &mute, &solo}) {
                    button->getProperties().set("macMasterControl", true);
                    button->setColour(TextButton::textColourOffId, Colours::white);
                    button->setColour(TextButton::textColourOnId, Colours::black);
                }
                mute.setColour(TextButton::buttonOnColourId, Colour(0xffff4245));
                mono.getProperties().set("flat", true);
                mono.setColour(TextButton::buttonColourId, Colours::transparentBlack);
                mono.setColour(TextButton::buttonOnColourId, Colours::transparentBlack);
                mono.setColour(TextButton::textColourOffId, Colours::white);
            }
            record.setColour(TextButton::textColourOffId, Colour(0xffff4444));
            record.setColour(TextButton::textColourOnId, Colours::black);
            phase.setComponentID("mixerPhase");
            phase.setTooltip(localization::translate("Invert polarity"));
            phase.setColour(TextButton::buttonOnColourId, theme::yellow);
            phase.setColour(TextButton::textColourOnId, Colours::black);
            phase.onClick = [this] { command(jaras::CommandKind::phase); };
            monitor.setComponentID("mixerInputMonitor");
            monitor.setTooltip(localization::translate("Input monitoring"));
            monitor.setColour(TextButton::buttonOnColourId, theme::green);
            monitor.setColour(TextButton::textColourOnId, Colours::black);
            monitor.onClick = [this] {
                if (auto *t = track()) try { mixer.session.setTrackInputMonitoring(id, !t->inputMonitoring.value_or(false)); }
                catch (const std::exception &e) { mixer.error(String::fromUTF8(e.what())); }
            };
            fx.onClick = [this] { mixer.openEffects(id,{}); };
            fxchain::bind(fx, mixer.session, id, [this](bool remove) { mixer.changeEffects(id, remove); });
            mute.onClick = [this] { command(jaras::CommandKind::mute); };
            solo.onClick = [this] { command(jaras::CommandKind::solo); };
            mute.context = [this](Point<int>) { if (mixer.mapControl) mixer.mapControl(id, jaras::CommandKind::mute); };
            solo.context = [this](Point<int>) { if (mixer.mapControl) mixer.mapControl(id, jaras::CommandKind::solo); };
            fader.mapControl = [this] { if (mixer.mapControl) mixer.mapControl(id, jaras::CommandKind::volume); };
            mute.modifiedClick = [this](ModifierKeys mods) {
                if (id.empty() || !mods.isCtrlDown()) return false;
                command(jaras::CommandKind::mute, 0, true);
                return true;
            };
            solo.modifiedClick = [this](ModifierKeys mods) {
                if (id.empty() || !mods.isCtrlDown()) return false;
                command(jaras::CommandKind::solo, 0, true);
                return true;
            };
            record.setColour(TextButton::buttonOnColourId, Colour(0xffff1f1f));
            record.onClick = [this] {
                try {
                    mixer.session.cycleRecordArm(id, selection(), ModifierKeys::getCurrentModifiers().isShiftDown());
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
            addChildComponent(teleprompterPatch);
            teleprompterPatch.setWantsKeyboardFocus(false);
            teleprompterPatch.getProperties().set("fontSize", 10);
            teleprompterPatch.onClick = [this] { if(mixer.specialAction)mixer.specialAction(id,"patch"); };
            addAndMakeVisible(pan);
            pan.setComponentID("mixerPan");
            pan.setRange(-1, 1, .01);
            pan.setSliderStyle(Slider::RotaryHorizontalVerticalDrag);
            pan.getProperties().set("footerPan", true);
            pan.getProperties().set("panValueTooltip", true);
            pan.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
            pan.setDoubleClickReturnValue(true, 0);
            pan.onDragStart = [this] { mixer.session.beginMixerGesture(jaras::CommandKind::pan,id); };
            pan.onDragEnd = [this] { mixer.session.endMixerGesture(); };
            pan.onValueChange = [this] { command(jaras::CommandKind::pan, pan.getValue()); };
            special=std::make_unique<SpecialTrackControls>(mixer.session,id,[this](ID id,String action){if(mixer.specialAction)mixer.specialAction(id,action);});addAndMakeVisible(*special);
            addChildComponent(rename);
            rename.navigate = [this](int direction) { mixer.navigateRename(id, direction); };
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
            const int blinkPhase = id.empty() && mixer.session.project().masterMute
                ? int(int64(Time::getMillisecondCounterHiRes() / 500.0) % 2) : -1;
            if (masterMuteBlinkPhase != blinkPhase) { masterMuteBlinkPhase = blinkPhase; repaint(); }
            peak->refresh();
            if(id.empty()) {
                const auto &project=mixer.session.project();
                masterPresentation.volume=project.masterVolume;masterPresentation.pan=project.masterPan;
                masterPresentation.mute=project.masterMute;masterPresentation.solo=project.masterSolo;
                masterPresentation.color=theme::mixerStripeSurface.getARGB() & 0xffffffu;
                if (masterPresentation.fxJSON != project.masterFXJSON) {
                    masterPresentation.fxJSON = project.masterFXJSON;
                    cachedFXRevision = ~uint64(0);
                }
                mono.setToggleState(project.masterMono,dontSendNotification);
                mono.setTooltip(project.masterMono ? String::fromUTF8("Mono - Alternar para estéreo")
                                                  : String::fromUTF8("Estéreo - Alternar para mono"));
            }
            if (const auto *t = track()) {
                const auto volume = mixer.session.trackDisplayVolume(id,t->volume);
                const bool shownMute = mixer.session.trackDisplayMute(id,t->mute), shownSolo = mixer.session.trackDisplaySolo(id,t->solo);
                const auto selected = !id.empty() && mixer.selectedTrack(id);
                const auto levels = mixer.session.audio.meterLevels(id);
                if (fader.isVisible() && fader.isVertical()) {
                    fader.setMeterLevels(levels);
                    fader.setGainReduction(mixer.session.audio.gainReduction(id));
                }
                if (teleprompterPatch.isVisible() && compactMeterRepaint.update(levels))
                    repaint(compactMeterBounds());
                if (lastRevision == mixer.session.revision && lastSelection == selected &&
                    lastVolume == volume && lastMute == shownMute && lastSolo == shownSolo && lastLocked == mixer.session.trackFaderLocked(id)) {
                    return;
                }
                lastRevision = mixer.session.revision; lastSelection = selected;
                lastVolume = volume; lastMute = shownMute; lastSolo = shownSolo; lastLocked = mixer.session.trackFaderLocked(id);
                fader.setValue(volume,dontSendNotification);
                fader.setEnabled(!mixer.session.trackFaderLocked(id));
                monitor.setEnabled(!t->receivesMain());
                monitor.setToggleState(!t->receivesMain() && t->inputMonitoring.value_or(false), dontSendNotification);
                pan.setValue(t->pan, dontSendNotification);
                mute.setToggleState(shownMute, dontSendNotification);
                solo.setToggleState(shownSolo, dontSendNotification);
                phase.setToggleState(t->phaseInverted.value_or(false), dontSendNotification);
                record.setButtonText(mixer.session.recordArm(id) == 2 ? "A" : "");
                record.getProperties().set("icon", mixer.session.recordArm(id) == 2 ? "" : "record.circle");
                record.setToggleState(mixer.session.recordingArmed(id), dontSendNotification);
                const auto &settings = slotSettings();
                firstSlot = jlimit(0, maximumFirstSlot(), firstSlot);
                firstOutput = jlimit(0, maximumFirstOutput(), firstOutput);
                fx.setColour(TextButton::textColourOffId, fxchain::colour(settings, id.empty()));
                resized();repaint();
            }
        }
        void paintOverChildren(Graphics &g) override {
            const auto bounds = getLocalBounds().toFloat();
            if (!id.empty() || !mixer.session.project().masterMute) return;
            const bool bright = masterMuteBlinkPhase == 0;
            g.setColour(Colour(0xffff3b30).withAlpha(bright ? .28f : .04f));
            g.fillRoundedRectangle(bounds, 5);
            g.setColour(Colour(0xffff3b30).withAlpha(bright ? 1.f : .25f));
            g.drawRoundedRectangle(bounds.reduced(1), 5, 2);
        }
        void paint(Graphics &g) override {
            const auto *t = track();
            if (!t)
                return;
            const auto colour = theme::track(*t);
            const bool selected = mixer.selectedTrack(id);
            const bool stripeOnly = mixer.stripeOnly && !id.empty();
            const bool neutralSurface = stripeOnly || id.empty();
            const auto bounds = getLocalBounds().toFloat().reduced(.5f);
            const auto nameInk = neutralSurface ? theme::surfaceText(theme::mixerStripeSurface) : Colours::white;
            g.setColour(neutralSurface ? theme::trackStripeSurface(stripeOnly && selected) : colour.withAlpha(selected ? .42f : .30f));
            g.fillRoundedRectangle(bounds, 5.f);
            if (!neutralSurface) {
                g.setColour(colour);
                g.fillRoundedRectangle(2.f, 0.f, (float)std::max(1, getWidth() - 4), 2.f, 1.f);
            }
            if (teleprompterPatch.isVisible() && compactMeterBounds().contains(g.getClipBounds())) {
                meterDisplay::compactRail(g, compactMeterBounds().toFloat(), mixer.session.audio.meterLevels(id));
                return;
            }
            const auto &settings = slotSettings();
            const auto chain = list(get(settings, "inserted"));
            const auto geometry = layout();
            if (jaras::fixedTrackName(t->role).empty() && !geometry.slots.isEmpty()) {
                Graphics::ScopedSaveState saved(g);g.reduceClipRegion(geometry.slots.withWidth(getWidth()-4));
                for (int i = 0; i < visibleSlots(); ++i) {
                    const auto bounds=geometry.slots.withY(geometry.slots.getY()+i*21).withHeight(19).toFloat();
                    const int slot=firstSlot+i;
                    if (slot < chain.size()) {
                        const auto effect = chain[slot].toString();
                        paintSlot(g, bounds, effectTitle(settings, effect),
                            fxchain::enabled(settings, effect) ? SlotTone::effectEnabled : SlotTone::effectBypassed);
                    } else paintSlot(g, bounds, {}, SlotTone::empty);
                    if (effectDropSlot==slot || hoveredSlot==slot) {
                        g.setColour(effectDropSlot==slot ? theme::green.withAlpha(.3f) : Colours::white.withAlpha(.09f));
                        g.fillRoundedRectangle(bounds, 5.f);
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
            const int bypassTop = geometry.bypass.getY();
            const int bypassHeight = geometry.bypass.getHeight();
            if (bypassHeight > 0 && jaras::fixedTrackName(t->role).empty()) {
                g.setColour(theme::line);
                g.drawHorizontalLine(bypassTop, 3.f, float(getWidth()-3));
                g.drawHorizontalLine(bypassTop + MixerSlotSections::bypassRowHeight - 1, 3.f, float(getWidth()-3));
                if (bypassHeight > MixerSlotSections::bypassRowHeight)
                    g.drawHorizontalLine(geometry.bypass.getBottom() - 1, 3.f, float(getWidth()-3));
                auto button = juce::Rectangle<float>(3.f, float(bypassTop+3), float(getWidth()-6), 19.f);
                paintSlot(g, button, "By All Fx", fxchain::stripBypassed(settings) ? SlotTone::bypassActive : SlotTone::routed);
                if (bypassHeight > MixerSlotSections::bypassRowHeight)
                    paintSlot(g, button.translated(0, MixerSlotSections::bypassRowHeight - 2), "By Fx Session", flag(settings, "sessionFXBypassed") ? SlotTone::bypassActive : SlotTone::routed);
            }
            if (!geometry.sends.isEmpty())
                paintSlot(g, geometry.sends.toFloat(), "Sends", SlotTone::empty);
            if(!geometry.outputs.isEmpty()) {
                const auto outputs = outputPatches();
                const auto sends = sendSlots();
                const size_t populated = sends.empty() ? 0 : sends.size() - 1;
                const auto count = int(outputs.size() + populated);
                Graphics::ScopedSaveState saved(g);g.reduceClipRegion(geometry.outputs.withWidth(getWidth()-4));
                const int rows = std::min(count - firstOutput, (geometry.outputs.getHeight() + 20) / 21);
                for(int i=0;i<rows;++i) {
                    const auto bounds=geometry.outputs.withY(geometry.outputs.getY()+i*21).withHeight(19).toFloat();
                    const size_t index = size_t(firstOutput + i);
                    if (index < populated) {
                        const auto &slot = sends[index + 1];
                        String name = "Sends";
                        if (slot.destination && mixer.session.song()) {
                            for (const auto &row : mixer.session.song()->tracks)
                                if (row.id == *slot.destination) { name = text(row.name); break; }
                        }
                        paintSlot(g, bounds, name, slot.destination ? SlotTone::routed : SlotTone::empty);
                        continue;
                    }
                    const auto &output = outputs[index - populated];
                    const String title=output.firstChannel==-2?"M-group":output.firstChannel==-1?localization::translate("None"):
                        output.firstChannel==0?"Main":String(output.firstChannel)+(output.channelCount==2?"+"+String(output.firstChannel+1):String{});
                    paintSlot(g, bounds, title, output.firstChannel == -1 ? SlotTone::empty : SlotTone::routed);
                }
                if(maximumFirstOutput()>0) {
                    const float height=(float)geometry.outputs.getHeight(),thumb=std::min(height,height*height/std::max(1.f,float(count*21-2)));
                    const float y=geometry.outputs.getY()+(height-thumb)*firstOutput/maximumFirstOutput();
                    g.setColour(theme::green.withAlpha(.15f));g.fillRoundedRectangle(getWidth()-3.f,(float)geometry.outputs.getY(),2,height,1);
                    g.setColour(theme::green);g.fillRoundedRectangle(getWidth()-3.f,y,2,thumb,1);
                }
            }
            const int controls = geometry.controlsY;
            if (teleprompterPatch.isVisible())
                meterDisplay::compactRail(g, compactMeterBounds().toFloat(), mixer.session.audio.meterLevels(id));
            if (fader.isVisible() && fader.isVertical()) drawFaderScale(g);
            const auto shownVolume = mixer.session.trackDisplayVolume(id,t->volume);
            const auto db = shownVolume > 0 ? String(Decibels::gainToDecibels(shownVolume), 1)
                                          : String::fromUTF8("−∞");
            g.setColour(Colours::white);
            if (jaras::fixedTrackName(t->role).empty()) {
                g.setFont(theme::mediumFont(8));
                g.drawText(mixerPanText(t->pan),
                           28+controlsOffset(), controls, 52, 10, Justification::centred);
            }
            g.setFont(theme::semiboldFont(8));
            if (peak->isVisible())
                g.drawText((shownVolume >= 1 ? "+" : "") + db + " dB", gainReadoutBounds(), Justification::centred);
            g.setColour(nameInk);g.setFont(theme::semiboldFont(10));
            g.drawFittedText(text(t->name), geometry.name, Justification::centred, 1, 1.f);
            const int labelEnd = geometry.name.getBottom();
            g.setColour(Colours::white.withAlpha(.22f));
            g.drawHorizontalLine(labelEnd, 4.f, (float)getWidth() - 4.f);
            if (!id.empty()) if (const auto* song = mixer.session.song()) {
                const auto index = trackTree::index(*song, id);
                if (index < song->tracks.size()) {
                    g.setColour(stripeOnly ? nameInk : Colours::white.withAlpha(.8f));
                    g.setFont(theme::semiboldFont(11));
                    g.drawText(String(int(index) + 1).paddedLeft('0', 2), 3, labelEnd + 1, getWidth() - 6, 13,
                        Justification::centred);
                    if (stripeOnly) {
                        g.setColour(colour);
                        g.fillRoundedRectangle(4.f, float(labelEnd + 14), float(std::max(1, getWidth() - 8)),
                                               float(theme::hozMixerStripeHeight), 1.f);
                    }
                }
            }
            if (t && !id.empty() && geometry.controlsHeight >= 158) {
                const int leading = mixer.focusedTrack ? 6 : 2;
                const int maxSide = mixer.focusedTrack ? 40 : getWidth() * 2 / 5;
                const int end = geometry.controlsY + geometry.controlsHeight - 8;
                const int controlsBottom = phase.isVisible() ? phase.getBottom() : solo.getBottom();
                const int scaleStart = roundToInt(fader.getBounds().getCentreX() - meterDisplay::railThickness / 2 - 1) - 26;
                const int side = jmin(maxSide, end - controlsBottom - 3, scaleStart - leading - 2);
                if (side >= 16)
                    trackIcons::draw(g, t->instrumentIcon, juce::Rectangle<int>(leading, end - side, side, side).toFloat());
            }
        }
        void ensureControlLayout() { if(controlLayoutPending)resized(); }
        void resized() override {
            // Keep every strip's exact bounds, but only lay out controls that
            // can be seen. Scrolling repairs pending controls synchronously
            // before the viewport paints the newly exposed strips.
            controlLayoutPending=true;
            if(!id.empty() && !getBounds().intersects(mixer.viewport.getViewArea()))return;
            controlLayoutPending=false;
            const auto *t=track();const bool standard=t&&jaras::fixedTrackName(t->role).empty();
            const bool teleprompter=t&&jaras::isTeleprompterRole(t->role);
            const bool textTrack=teleprompter||(t&&t->role.id=="chords");
            fx.setVisible(standard);record.setVisible(standard&&!id.empty());monitor.setVisible(standard&&!id.empty()&&t->role.id!="vinhetas");pan.setVisible(standard);mono.setVisible(id.empty());fader.setVisible(teleprompter||(!textTrack&&t&&t->role.id!="programChange"));mute.setVisible(standard||(t&&(t->role.id=="timecode"||t->role.id=="generatedClick"||t->role.id=="programChange")));solo.setVisible(mute.isVisible());
            phase.setVisible(monitor.isVisible());
            const auto faderStyle = teleprompter ? Slider::RotaryVerticalDrag : Slider::LinearVertical;
            if(fader.getSliderStyle()!=faderStyle)fader.setSliderStyle(faderStyle);
            teleprompterPatch.setVisible(teleprompter);
            const auto geometry=layout();
            rename.layoutIn(geometry.name);
            firstSlot=jlimit(0,maximumFirstSlot(),firstSlot);
            const int y=geometry.controlsY,available=geometry.controlsHeight;
            if(special){special->setVisible(!standard&&!teleprompter);special->setBounds((getWidth()-47)/2,y,47,t&&t->role.id=="programChange"?72:21);special->refresh();}
            const int buttonRows = phase.isVisible() ? 6 : 4;
            const int iconSpace = !id.empty() && trackIcons::contains(t ? t->instrumentIcon : std::nullopt) && available >= 158 ? (mixer.focusedTrack ? 48 : getWidth() * 2 / 5 + 8) : 0;
            const int gap = jlimit(2, 5, (available - 12 - iconSpace - 21 * buttonRows) / buttonRows);
            const int buttonHeight = jlimit(12, 21, (available - 12 - iconSpace - buttonRows * gap) / buttonRows);
            const int step=buttonHeight+gap;
            peak->setVisible(!textTrack&&t&&t->role.id!="programChange");
            fx.setBounds(4,y,22,buttonHeight);
            mute.setBounds(4,y+(standard?step:25),22,buttonHeight);
            solo.setBounds(4,y+(standard?2*step:25+step),22,buttonHeight);
            mono.setBounds(4,y+3*step,22,buttonHeight);
            record.setBounds(3,y+3*step,25,buttonHeight);
            monitor.setBounds(4,y+4*step,22,buttonHeight);
            phase.setBounds(4,y+5*step,22,buttonHeight);
            const int faderOffset = jlimit(standard ? 49 : 38, standard ? 60 : 49, available - 115);
            const int panSize = jlimit(14, 24, faderOffset - 34);
            pan.setBounds(54+controlsOffset()-panSize/2,y+10,panSize,panSize);
            if(teleprompter) {
                teleprompterPatch.setBounds((getWidth()-44)/2,y,44,21);
                fader.setBounds(43+controlsOffset(),y+24,24,24);
            } else {
                fader.setBounds(39 + controlsOffset() + (id.empty() ? 0 : 6), y + faderOffset, 31, std::max(1,available-faderOffset));
                const auto gain = gainReadoutBounds();
                peak->setBounds(gain.getX(), gain.getY() - 12, gain.getWidth(), 12);
            }
        }
        void mouseMove(const MouseEvent &event) override { const int next=slotAt(event.getPosition());if(next!=hoveredSlot){hoveredSlot=next;repaint();} }
        void mouseExit(const MouseEvent &) override {hoveredSlot=-1;repaint();}
        void mouseDown(const MouseEvent &event) override {
            dragging = false; pressedPower = false; pressedEffect.clear(); pressedSlot = slotAt(event.getPosition());
            const auto geometry = layout();
            const auto button = geometry.bypass.withY(geometry.bypass.getY()+3).withHeight(19);
            auto *row = track();
            const bool sessionButton = geometry.bypass.getHeight() > MixerSlotSections::bypassRowHeight &&
                button.translated(0, MixerSlotSections::bypassRowHeight - 2).contains(event.getPosition());
            if (geometry.bypass.contains(event.getPosition()) && row && jaras::fixedTrackName(row->role).empty() &&
                (button.contains(event.getPosition()) || sessionButton)) {
                pendingSelection = false;
                if (event.mods.isLeftButtonDown()) {
                    try { fxchain::toggleStripBypass(mixer.session, id, sessionButton); }
                    catch (const std::exception &e) { mixer.error(String::fromUTF8(e.what())); }
                }
                return;
            }
            pressedOutput=geometry.sends.contains(event.getPosition()) || outputIndexAt(event.getPosition()) >= 0;
            if (pressedOutput) {
                pendingSelection = false;
                if (event.mods.isPopupMenu()) {
                    pressedOutput = false;
                    if (const auto slot = sendAt(event.getPosition())) showSendMenu(*slot);
                }
                return;
            }
            if (pressedSlot >= 0) {
                const auto settings = fxchain::settings(mixer.session, id);
                const auto chain = list(get(settings, "inserted"));
                if (pressedSlot < chain.size()) {
                    pressedEffect = chain[pressedSlot].toString();
                    pressedPower = powerBounds(pressedSlot).contains(event.getPosition());
                }
                if (event.mods.isPopupMenu()) { showEffectMenu(pressedEffect); pressedSlot=-1; pressedEffect.clear(); }
                return;
            }
            if (id.empty()) {
                if(event.mods.isPopupMenu())mixer.openContextMenu(id,event.getScreenPosition());
                return;
            }
            pendingSelection=mixer.selectedTrack(id)&&event.mods.isLeftButtonDown()&&!event.mods.isShiftDown()&&!event.mods.isCtrlDown()&&!event.mods.isPopupMenu();
            if(!pendingSelection)mixer.selectTrack(id, event.mods);
            if (event.mods.isPopupMenu()) mixer.openContextMenu(id,event.getScreenPosition());
            else dragging=event.mods.isLeftButtonDown();
        }

        void mouseDoubleClick(const MouseEvent &event) override {
            if (event.mods.isLeftButtonDown() && !event.mods.isAnyModifierKeyDown() &&
                layout().name.contains(event.getPosition())) beginRename();
        }
        void confirmRename() { rename.confirm(); }
        void beginRename() {
            const auto *t = track();
            const auto *song = mixer.session.song();
            const auto bounds = layout().name;
            if (id.empty() || !t || !song || !canRenameMixerTrack(*t)) return;
            dragging = pendingSelection = false;
            rename.open(bounds, text(t->name),
                [panel = Component::SafePointer<MixerPanel>(&mixer), project = mixer.session.project().id,
                 songID = song->id, target = id](String name) {
                    if (!panel || panel->session.project().id != project || !panel->session.song() ||
                        panel->session.song()->id != songID) return;
                    try { panel->session.renameTrack(target, name); panel->refresh(); }
                    catch (const std::exception &e) { panel->error(String::fromUTF8(e.what())); }
                });
        }

        void mouseDrag(const MouseEvent &e) override {
            if (!pressedPower && !id.empty() && pressedEffect.isNotEmpty() && e.mods.isLeftButtonDown() && e.getDistanceFromDragStart() > 8) {
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
                pendingSelection=false;dragging=false;std::set<ID> selected;for(const auto &t:mixer.session.song()->tracks)if(mixer.selectedTrack(t.id))selected.insert(t.id);mixer.startDragging(trackDrop::description(mixer.session.project(),*mixer.session.song(),id,selected),this);
            }
        }
        void mouseUp(const MouseEvent &e) override {
            if(pressedOutput) {
                pressedOutput=false;
                if (e.getDistanceFromDragStart() <= 8 && !e.mods.isPopupMenu()) {
                    if (const auto slot = sendAt(e.getPosition())) showSendMenu(*slot);
                    else if (outputIndexAt(e.getPosition()) >= 0 && mixer.specialAction) mixer.specialAction(id, "patch");
                }
                return;
            }
            if(pendingSelection&&e.getDistanceFromDragStart()<=8)mixer.selectTrack(id,e.mods);
            pendingSelection=false;
            if (pressedSlot >= 0 && !e.mods.isPopupMenu() && e.getDistanceFromDragStart() <= 8) {
                if (pressedPower) {
                    if (powerBounds(pressedSlot).contains(e.getPosition())) changeEffect(pressedEffect, false);
                } else if (e.mods.isAltDown() || e.mods.isShiftDown()) {
                    if (pressedEffect.isNotEmpty()) changeEffect(pressedEffect,e.mods.isAltDown());
                } else mixer.openEffects(id,pressedEffect.isEmpty() ? String("Library") : pressedEffect);
            }
            dragging = false; pressedPower = false; pressedSlot = -1; pressedEffect.clear();
        }
        bool isInterestedInDragSource(const SourceDetails &d) override {
            if (isLibraryEffectDrag(d.description)) return id.empty() || (track() && jaras::fixedTrackName(track()->role).empty());
            if(id.empty()) return false;
            if (isEffectDrag(d.description)) return track() && jaras::fixedTrackName(track()->role).empty();
            return mixer.session.song()&&!trackDrop::source(d.description,mixer.session.project(),*mixer.session.song()).empty();
        }
        void itemDragEnter(const SourceDetails &d) override {itemDragMove(d);}
        void itemDragMove(const SourceDetails &d) override {
            const bool library = isLibraryEffectDrag(d.description);
            if (library || isEffectDrag(d.description)) {
                effectDropSlot = slotAt(d.localPosition);
                mixer.dropPreview.reset(); mixer.blocked.clear(); repaint(); return;
            }
            if(id.empty()) return;
            if(!mixer.session.song())return;
            mixer.dropPreview=trackDrop::resolve(*mixer.session.song(),trackDrop::sources(d.description,mixer.session.project(),*mixer.session.song()),id,d.localPosition.x>getWidth()/2,d.localPosition.y<16);
            mixer.blocked=mixer.dropPreview?ID{}:id;mixer.repaint();
        }
        void itemDragExit(const SourceDetails &) override {effectDropSlot=-1;mixer.dropPreview.reset();mixer.blocked.clear();mixer.repaint();repaint();}
        void itemDropped(const SourceDetails &d) override {
            const bool library = isLibraryEffectDrag(d.description);
            if (library || isEffectDrag(d.description)) {
                const int slot = slotAt(d.localPosition); itemDragExit(d);
                if (slot < 0 || !isInterestedInDragSource(d)) return;
                const auto chain = list(get(fxchain::settings(mixer.session, id), "inserted"));
                try {
                    const auto before = isPositiveAndBelow(slot, chain.size()) ? chain[slot].toString() : String();
                    if (library)
                        mixer.session.insertLibraryEffect(id, str(d.description, "identity"), str(d.description, "preset"), before);
                    else mixer.session.copyEffect(utf8(str(d.description,"source")), str(d.description,"effect"), id, before);
                } catch (const std::exception &e) { mixer.error(String::fromUTF8(e.what())); }
                refresh(); return;
            }
            if(id.empty()) return;
            itemDragMove(d);const auto destination=mixer.dropPreview;const ID song=mixer.session.song()?mixer.session.song()->id:ID{};itemDragExit(d);
            if(destination)try{mixer.session.editTrackHierarchy(song,[&](jaras::Song &s){trackDrop::apply(s,*destination,trackDrop::sources(d.description,mixer.session.project(),s));});}catch(const std::exception &e){mixer.error(String::fromUTF8(e.what()));}
        }
        bool scrollEffects(const MouseEvent &event, const MouseWheelDetails &wheel) {
            if(!event.mods.isShiftDown() && std::abs(wheel.deltaY)>=std::abs(wheel.deltaX) && wheel.deltaY!=0 &&
               layout().outputs.withWidth(getWidth()-4).contains(event.getPosition()) && maximumFirstOutput()>0) {
                firstOutput=jlimit(0,maximumFirstOutput(),firstOutput+(wheel.deltaY<0?1:-1));repaint();return true;
            }
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
        bool controlLayoutPending=false;
        int masterMuteBlinkPhase = -1;
        jaras::Track masterPresentation; // View state only; Master is never added to the song's tracks.
        uint64 lastRevision = ~uint64(0);
        bool lastSelection = false, lastLocked = false, lastMute = false, lastSolo = false;
        double lastVolume = -1;
        meterDisplay::RepaintState compactMeterRepaint;
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
        void drawFaderScale(Graphics& g) {
            // Use JUCE's actual thumb travel, including the look-and-feel insets.
            const auto position = [this](int db) {
                const double gain = db == -60 ? 0. : std::pow(10., db / 20.);
                return fader.getY() + fader.getPositionOfValue(gain);
            };
            const float travel = position(-60) - position(12);
            if (travel < 12.f) return;
            constexpr std::array<int, 17> priority{0,-60,12,-24,-40,-12,-6,-18,-30,-50,6,-3,-9,-15,-21,-35,-45};
            std::array<float, priority.size()> labelY{};
            size_t used = 0;
            const int minorStep = travel >= 216.f ? 1 : travel >= 72.f ? 3 : 6;
            const int right = roundToInt(fader.getBounds().getCentreX() - meterDisplay::railThickness / 2 - 1);
            for (int db : priority) {
                const auto y = position(db);
                if (std::any_of(labelY.begin(), labelY.begin() + used, [y](float other) { return std::abs(other-y) < 9.5f; }))
                    continue;
                labelY[used++] = y;
                g.setColour(Colours::white.withAlpha(.82f));
                g.setFont(theme::font(8));
                g.drawText(db > 0 ? "+" + String(db) : String(std::abs(db)), right-26, roundToInt(y)-5,
                           19, 10, Justification::centredRight, false);
            }
            for (int db = -60; db <= 12; ++db) {
                const auto y = position(db);
                const bool labelled = std::find(labelY.begin(), labelY.begin()+used,y) != labelY.begin()+used;
                if (!labelled && db % minorStep != 0) continue;
                g.setColour(Colours::white.withAlpha(labelled ? .63f : .32f));
                g.drawHorizontalLine(roundToInt(y), float(right - (db==0 ? 6 : labelled ? 4 : 2)), float(right));
            }
        }
        juce::Rectangle<int> gainReadoutBounds() const {
            return {fader.getBounds().getCentreX() - 21, fader.getY() - 11, 42, 10};
        }
        int controlsOffset() const { return 17 + std::max(0,(getWidth()-stripWidth)/2); }
        juce::Rectangle<int> compactMeterBounds() const {
            auto bounds = fader.getBounds();
            return {32 + controlsOffset(), bounds.getY(), 8, bounds.getHeight()};
        }
        bool dragging=false;
        int pressedSlot=-1, effectDropSlot=-1, firstSlot=0, hoveredSlot=-1;
        int firstOutput=0;
        bool pressedOutput=false, pressedPower=false;
        String pressedEffect;
        friend struct MasterMixerTests;
        bool pendingSelection=false;
        friend struct HozMixerFocusTests;
        std::vector<jaras::OutputPatch> outputPatches() const {
            if(!id.empty()){const auto* value=track();return value?value->outputPatches():std::vector<jaras::OutputPatch>{};}
            const auto& p=mixer.session.project();if(p.masterOutputs)return *p.masterOutputs;
            std::vector<jaras::OutputPatch> result{p.masterPatch.value_or(jaras::OutputPatch{1,2})};
            if(p.masterSecondaryPatch)result.push_back(*p.masterSecondaryPatch);return result;
        }
        struct SendSlot {
            size_t slot;
            std::optional<ID> destination;
        };
        std::vector<SendSlot> sendSlots() const {
            const auto *row = track();
            if (id.empty()) {
                std::vector<const jaras::Track*> receivers;
                if (const auto *song = mixer.session.song())
                    for (const auto &target : song->tracks) if (target.receivesMain()) receivers.push_back(&target);
                std::stable_sort(receivers.begin(), receivers.end(), [](auto *a, auto *b) {
                    return a->routing->mainSendOrder.value_or(-1) < b->routing->mainSendOrder.value_or(-1);
                });
                std::vector<SendSlot> result{{receivers.size(), {}}};
                for (auto *target : receivers) result.push_back({result.size() - 1, target->id});
                return result;
            }
            if (!row || !jaras::fixedTrackName(row->role).empty()) return {};
            std::vector<SendSlot> result;
            const auto *routes = row->routing ? &row->routing->transmitters : nullptr;
            if (routes) for (size_t i = 0; i < routes->size(); ++i) {
                if ((*routes)[i]) result.push_back({i, (*routes)[i]});
            }
            const size_t next = result.empty() ? 0 : result.back().slot + 1;
            result.insert(result.begin(), {next, {}});
            return result;
        }
        int outputRowCount() const {
            if (id.empty()) {
                const auto &project = mixer.session.project();
                const auto *song = mixer.session.song();
                const int receivers = song ? int(std::count_if(song->tracks.begin(), song->tracks.end(), [](const auto &t) { return t.receivesMain(); })) : 0;
                return 1 + receivers + (project.masterOutputs ? int(project.masterOutputs->size()) : 1 + int(project.masterSecondaryPatch.has_value()));
            }
            const auto *row = track();
            if (!row) return 0;
            int count = row->outputs ? int(row->outputs->size()) : 1 + int(row->secondaryPatch.has_value());
            if (jaras::fixedTrackName(row->role).empty()) {
                ++count; // The empty Sends slot.
                if (row->routing) for (const auto &destination : row->routing->transmitters)
                    if (destination) ++count;
            }
            return count;
        }
        bool hasSends() const {
            return id.empty() || (track() && jaras::fixedTrackName(track()->role).empty());
        }
        int outputIndexAt(Point<int> position) const {
            const auto bounds = layout().outputs;
            if (!bounds.contains(position) || (position.y - bounds.getY()) % 21 >= 19) return -1;
            const int row = firstOutput + (position.y - bounds.getY()) / 21;
            return row < outputRowCount() - int(hasSends()) ? row : -1;
        }
        std::optional<SendSlot> sendAt(Point<int> position) const {
            const auto slots = sendSlots();
            if (slots.empty()) return {};
            if (layout().sends.contains(position)) return slots.front();
            const int index = outputIndexAt(position);
            if (index < 0 || size_t(index + 1) >= slots.size()) return {};
            return slots[size_t(index + 1)];
        }
        void updateSend(const SendSlot &slot, std::optional<ID> destination,
                        std::optional<jaras::TrackSendTap> tap = {}) {
            if (!mixer.session.song() || (id.empty() && mixer.session.audio.isRecording())) return;
            const auto activeSong = mixer.session.song()->id;
            try {
                mixer.session.editTrackSettings([&](jaras::Project &project) {
                    for (auto &song : project.songs) {
                        if (song.id != activeSong) continue;
                        if (id.empty()) {
                            if (tap || slot.destination == destination) return;
                            jaras::Track *previous = nullptr, *target = nullptr;
                            int maxOrder = -1;
                            for (auto &row : song.tracks) {
                                if (row.receivesMain()) maxOrder = std::max(maxOrder, row.routing->mainSendOrder.value_or(-1));
                                if (slot.destination == row.id && row.receivesMain()) previous = &row;
                                if (destination == row.id && !row.receivesMain() && jaras::fixedTrackName(row.role).empty()) target = &row;
                            }
                            if ((slot.destination && !previous) || (destination && !target)) return;
                            const int order = previous ? previous->routing->mainSendOrder.value_or(maxOrder + 1) : maxOrder + 1;
                            if (previous) {
                                previous->routing->mainReceiveSlot.reset();
                                previous->routing->mainSendOrder.reset();
                            }
                            if (target) {
                                if (!target->routing) target->routing = jaras::TrackRouting{{}, {}};
                                auto &routing = *target->routing;
                                const auto free = std::find(routing.receives.begin(), routing.receives.end(), std::nullopt);
                                routing.mainReceiveSlot = int(free - routing.receives.begin());
                                if (free == routing.receives.end()) routing.receives.emplace_back();
                                routing.mainSendOrder = order;
                                target->inputMonitoring = false;
                                if (target->recordingChannels == 0) target->recordingChannels = 2;
                            }
                            return;
                        }
                        auto source = std::find_if(song.tracks.begin(), song.tracks.end(), [&](const auto &row) { return row.id == id; });
                        if (source == song.tracks.end()) continue;
                        if (!source->routing) source->routing = jaras::TrackRouting{{}, {}};
                        auto &routing = *source->routing;
                        auto &sends = routing.transmitters;
                        if (!tap && destination) {
                            const auto target = std::find_if(song.tracks.begin(), song.tracks.end(),
                                [&](const auto &row) { return row.id == *destination; });
                            if (target == song.tracks.end() || target->id == id || !jaras::fixedTrackName(target->role).empty() ||
                                (slot.destination != destination && std::find(sends.begin(), sends.end(), destination) != sends.end())) return;
                        }
                        if (sends.size() <= slot.slot) sends.resize(slot.slot + 1);
                        const auto before = sends[slot.slot];
                        if (before != slot.destination) return;
                        if (tap && destination) {
                            if (*tap == jaras::TrackSendTap::postFader) routing.sendTaps.erase(*destination);
                            else routing.sendTaps[*destination] = *tap;
                            return;
                        }
                        if (before == destination) return;
                        if (before) routing.sendTaps.erase(*before);
                        sends[slot.slot] = destination;
                        for (auto &row : song.tracks) {
                            if (before && row.id == *before && row.routing)
                                for (auto &receive : row.routing->receives) if (receive == id) receive.reset();
                            if (!destination || row.id != *destination) continue;
                            if (!row.routing) row.routing = jaras::TrackRouting{{}, {}};
                            auto &receive = row.routing->receives;
                            if (std::find(receive.begin(), receive.end(), id) != receive.end()) continue;
                            const auto free = std::find_if(receive.begin(), receive.end(), [&](const auto &entry) {
                                return !entry && row.routing->mainReceiveSlot != int(&entry - receive.data());
                            });
                            if (free == receive.end()) receive.push_back(id);
                            else *free = id;
                        }
                        return;
                    }
                }, true);
            } catch (const std::exception &error) {
                mixer.error(String::fromUTF8(error.what()));
            }
        }
        void showSendMenu(const SendSlot &slot) {
            const auto *source = track();
            const auto *song = mixer.session.song();
            if (!source || !song) return;
            if (!slot.destination) { showSendPicker(slot); return; }
            using Tap = jaras::TrackSendTap;
            constexpr std::array<Tap, 4> modes{Tap::preFX, Tap::postFX, Tap::preFader, Tap::postFader};
            constexpr std::array<const char *, 4> titles{"Pre-FX", "Post-FX", "Pre-Fader", "Post-Fader"};
            PopupMenu menu;
            const auto current = source->routing ? source->routing->sendTap(*slot.destination) : Tap::postFader;
            if (!id.empty()) for (size_t i = 0; i < modes.size(); ++i) menu.addItem(int(i) + 1, titles[i], true, modes[i] == current);
            menu.addItem(5, localization::translate("Remove send"));
            menu.addSeparator();
            menu.addItem(6, localization::translate("Change destination"));
            menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea(juce::Rectangle<int>(Desktop::getMousePosition().x, Desktop::getMousePosition().y, 1, 1)),
                [safe = Component::SafePointer<Strip>(this), slot, modes](int choice) {
                    if (!safe || choice == 0) return;
                    if (choice <= 4) safe->updateSend(slot, slot.destination, modes[size_t(choice - 1)]);
                    else if (choice == 5) safe->updateSend(slot, {});
                    else if (choice == 6) safe->showSendPicker(slot);
                });
        }
        void showSendPicker(const SendSlot &slot) {
            const auto *source = track();
            const auto *song = mixer.session.song();
            if (!source || !song) return;
            std::vector<SendPicker::Destination> rows;
            for (const auto &row : song->tracks) {
                const bool current = slot.destination == row.id;
                const bool alreadyRouted = id.empty() ? row.receivesMain() : source->routing &&
                    std::find(source->routing->transmitters.begin(), source->routing->transmitters.end(), row.id) != source->routing->transmitters.end();
                rows.push_back({row.id, text(row.name), row.id != id && jaras::fixedTrackName(row.role).empty() && (!alreadyRouted || current), current});
            }
            const auto project = mixer.session.project().id, songID = song->id;
            auto picker = std::make_unique<SendPicker>(rows, [safe = Component::SafePointer<Strip>(this), project, songID, slot](ID destination) {
                if (safe && safe->mixer.session.project().id == project && safe->mixer.session.song() &&
                    safe->mixer.session.song()->id == songID) safe->updateSend(slot, destination);
            });
            const int columns = std::min(3, (int(rows.size()) + SendPicker::blockSize - 1) / SendPicker::blockSize);
            if (auto *host = getTopLevelComponent()) {
                picker->setSize(std::min(std::max(1, host->getWidth() - 48), std::max(1, columns) * 210 + 26),
                                std::min(std::max(1, host->getHeight() - 64), SendPicker::headingHeight +
                                         std::min(int(rows.size()), SendPicker::blockSize) * SendPicker::rowHeight + 34));
                const auto anchor = host->getLocalArea(this, layout().sends);
                static SendCalloutLook look;
                auto &popup = CallOutBox::launchAsynchronously(std::move(picker), anchor, host);
                popup.setLookAndFeel(&look);
                popup.setDismissalMouseClicksAreAlwaysConsumed(true);
            }
        }
        int maximumFirstOutput() const {
            const int height=layout().outputs.getHeight();
            return height<=0?0:std::max(0,outputRowCount()-int(hasSends())-std::max(1,(height+2)/21));
        }
        struct StripLayout { juce::Rectangle<int> slots,name,outputs,bypass,sends;int controlsY=0,controlsHeight=0; };
        StripLayout layout() const {
            const int height=std::max(1,getHeight());
            const auto sections=[&](int slots,int nameY,int controlsY,int controls) {
                const MixerSlotSections areas(slots, 1, id.empty());
                const int header = hasSends() ? std::min(21, areas.outputs) : 0;
                const int routingY = 13 + slots - areas.outputs;
                return StripLayout{{3,13,std::max(0,getWidth()-6),areas.plugins},
                    {3,nameY,std::max(0,getWidth()-6),std::min(22,std::max(0,height-nameY))},
                    {3,routingY+header,std::max(0,getWidth()-6),areas.outputs-header},
                    {3,13+areas.plugins,std::max(0,getWidth()-6),areas.divider},
                    {3,routingY,std::max(0,getWidth()-6),header>=19?19:0},controlsY,controls};
            };
            // Match FooterMixerStrip: the docked panel hides FX at 255 pt and below.
            // The 22 pt allowance accounts for the Mac host's inset/chrome beyond
            // this strip's bounds; growth above the threshold belongs to FX slots.
            if (!mixer.focusedTrack && height <= 253) {
                const int controlsY = 4;
                const int controls = std::min(205, std::max(0, height - controlsY - 4 - 40));
                return sections(0, controlsY + controls + 4, controlsY, controls);
            }
            const int inner=std::max(0,height-22);
            const int controls=std::min(205,std::max(100,inner-40-(mixer.focusedTrack ? 87 : 0)));
            const int slots=std::max(0,inner-controls-40);
            return sections(slots,13+slots+controls+4,13+slots,controls);
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
            if ((track() && !jaras::fixedTrackName(track()->role).empty()) || !bounds.contains(point))return -1;
            const int slot=firstSlot+(point.y-bounds.getY())/21;
            return slot<totalSlots()?slot:-1;
        }
        bool isEffectDrag(const var &description) const {
            return str(description,"type")=="catlive-fx-copy" && str(description,"project")==text(mixer.session.project().id);
        }
        bool isLibraryEffectDrag(const var &description) const {
            return str(description, "type") == "catlive-library-effect" && str(description, "project") == text(mixer.session.project().id);
        }
        static constexpr int powerWidth = 19;
        juce::Rectangle<int> powerBounds(int slot) const {
            const auto viewport = layout().slots;
            const int y = viewport.getY() + (slot - firstSlot) * 21;
            return viewport.getIntersection({viewport.getX(), y, powerWidth, 19});
        }
        enum class SlotTone { empty, routed, effectEnabled, effectBypassed, bypassActive };
        static void paintSlot(Graphics& g, juce::Rectangle<float> bounds, const String& title, SlotTone tone) {
            const bool enabled = tone == SlotTone::effectEnabled;
            const bool hasEffect = enabled || tone == SlotTone::effectBypassed;
            const auto level = int(theme::mixerStripeSurface.getRed()) - (tone == SlotTone::empty ? 11 : 0);
            const auto gray = [](int value) { return Colour(uint8(value), uint8(value), uint8(value)); };
            const Colour top = tone == SlotTone::bypassActive ? Colour(0xffffdf61) : hasEffect ? Colour(enabled ? 0xff26503b : 0xff693235) : gray(level + 6);
            const Colour bottom = tone == SlotTone::bypassActive ? Colour(0xffe2ae25) : hasEffect ? Colour(enabled ? 0xff163b2a : 0xff4c2023) : gray(level - 6);
            const Colour border = tone == SlotTone::bypassActive ? Colour(0xffffe990) : hasEffect ? Colour(enabled ? 0xff438a60 : 0xffa35357) : gray(level + 18);
            g.setGradientFill(ColourGradient(top, bounds.getX(), bounds.getY(), bottom, bounds.getX(), bounds.getBottom(), false));
            g.fillRoundedRectangle(bounds, 5.f);
            g.setColour(border);
            g.drawRoundedRectangle(bounds.reduced(.375f), 4.625f, .75f);
            if (hasEffect) {
                const auto button = bounds.removeFromLeft(float(powerWidth)).reduced(3.f, 2.f);
                g.setColour(Colours::white.withAlpha(.13f));
                g.fillRoundedRectangle(button, 3.f);
                g.setColour(gray(244));
                const auto center = button.getCentre();
                Path glyph;
                glyph.addCentredArc(center.x, center.y + .4f, 3.3f, 3.3f, 0,
                                    MathConstants<float>::pi * .25f, MathConstants<float>::pi * 1.75f, true);
                glyph.startNewSubPath(center.x, center.y - 4.1f);
                glyph.lineTo(center.x, center.y - .15f);
                g.strokePath(glyph, PathStrokeType(1.f, PathStrokeType::curved, PathStrokeType::rounded));
            }
            if (title.isEmpty()) return;
            g.setColour(tone == SlotTone::bypassActive ? Colours::black : gray(244));
            g.setFont(theme::semiboldFont(10));
            g.drawFittedText(title, bounds.reduced(hasEffect ? 3.f : 5.f, 0.f).toNearestInt(), Justification::centred, 1, 1.f);
        }
        static String effectTitle(const var &settings, const String &key) {
            for (const auto &plugin : list(get(settings,"externalPlugins"))) if (key=="External:"+str(plugin,"id")) return str(plugin,"name");
            auto kind = key;
            auto parameters = settings;
            for (const auto &instance : list(get(settings, "instances"))) {
                if (key == "Native:" + str(instance, "id") || key == "Instance:" + str(instance, "id")) {
                    kind = str(instance, "kind");
                    parameters = get(instance, "settings");
                    break;
                }
            }
            const auto instrument = str(parameters, "instrumentID");
            return kind == "Instruments" && instrument.isNotEmpty() ? instrumentAssets::name(instrument) : kind;
        }
        void showEffectMenu(String key) {
            PopupMenu menu;
            const auto &catalog = VST3Catalog::shared();
            StringArray categories{"All", "Native"};
            categories.addArray(libraryPluginCategories(catalog));
            std::vector<String> identities;
            for (const auto &category : categories) {
                PopupMenu submenu;
                const auto add = [&](const String &name, const String &identity) {
                    identities.push_back(identity);
                    submenu.addItem(9 + (int)identities.size(), name);
                };
                for (const auto &[name, type] : libraryNativePlugins())
                    if (category == "All" || category == "Native" || category == type)
                        add(name == "Limiter" ? "CatLive Limiter" : name, "native:" + name);
                if (category != "Native")
                    for (const auto &plugin : favoritePluginMatches(catalog, {}, category == "All" ? String() : category, {}, true, false))
                        add(str(plugin, "name"), "vst3:" + str(plugin, "classID"));
                menu.addSubMenu(localization::translate(category), submenu);
            }
            if (key.isNotEmpty()) {
                const auto settings = fxchain::settings(mixer.session, id);
                menu.addSeparator();
                menu.addItem(1, "Bypass", true, !fxchain::enabled(settings, key));
                menu.addItem(2, localization::translate("Remover"));
            }
            const auto project = mixer.session.project().id;
            const ID song = mixer.session.song() ? mixer.session.song()->id : ID{};
            menu.showMenuAsync(PopupMenu::Options().withTargetComponent(this),
                [safe=Component::SafePointer<Strip>(this), key, identities = std::move(identities), project, song](int result) {
                if (!safe || result == 0 || safe->mixer.session.project().id != project ||
                    !safe->mixer.session.song() || safe->mixer.session.song()->id != song) return;
                if (result <= 2) safe->changeEffect(key, result == 2);
                else if (result >= 10 && size_t(result - 10) < identities.size()) {
                    try { safe->mixer.session.insertLibraryEffect(safe->id, identities[size_t(result - 10)], {}, key); }
                    catch (const std::exception &e) { safe->mixer.error(String::fromUTF8(e.what())); }
                }
            });
        }
        void changeEffect(const String &key,bool remove) {
            auto settings=fxchain::settings(mixer.session,id).clone();
            auto chain=list(get(settings,"inserted"));
            if (!chain.contains(var(key))) return;
            if(!remove) fxchain::setEnabled(settings,key,!fxchain::enabled(settings,key));
            else {
                chain.removeAllInstancesOf(var(key));put(settings,"inserted",chain);
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
        TextButton teleprompterPatch{"Patch"};
        QuietButton fx{"FX"}, mute{"M"}, solo{"S"}, record{"REC"}, monitor{"I"}, phase{String::fromUTF8("Ø")}, mono;
        GainFader fader;
        ParameterSlider pan;
        InlineMixerTrackName rename;
        std::set<ID> selection() const {
            std::set<ID> targets{id};
            if (mixer.selectedTrack(id))
                if (const auto *song = mixer.session.song())
                    for (const auto &t : song->tracks) if (mixer.selectedTrack(t.id)) targets.insert(t.id);
            return targets;
        }
        void command(jaras::CommandKind kind, double value = 0, bool clearAll = false) {
            try {
                if(id.empty()) mixer.session.command(kind,{},value);
                else mixer.session.mixerCommand(kind,id,clearAll ? std::set<ID>{} : selection(),value,clearAll);
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
    std::function<ID()> focusedTrack;
    ID lastFocusedTrack;
    bool masterRight=false,stripeOnly=false;
    double wheelRemainder=0;
    std::optional<trackDrop::Destination> dropPreview;ID blocked;
    MixerScrollLook scrollLook;
    struct MixerHorizontalScroll final : ScrollBar {
        MixerHorizontalScroll():ScrollBar(false) {}
        void mouseWheelMove(const MouseEvent &event,const MouseWheelDetails &wheel) override {
            if(event.mods.isShiftDown()) Component::mouseWheelMove(event,wheel);
            else ScrollBar::mouseWheelMove(event,wheel);
        }
    } horizontal;
    static constexpr int stripWidth=100,stripStride=stripWidth+3,masterStripWidth=stripWidth*5/4;
    std::unique_ptr<Strip> master;
    struct MixerViewport final : Viewport {
        std::function<void()> moved;
        void mouseWheelMove(const MouseEvent &event,const MouseWheelDetails &wheel) override {
            Component::mouseWheelMove(event,wheel);
        }
        void visibleAreaChanged(const juce::Rectangle<int> &) override { if (moved) moved(); }
    } viewport;
    struct MixerTrackArea final : Component {
        std::function<void(const MouseEvent &)> doubleClicked;
        void mouseDoubleClick(const MouseEvent &event) override { if (doubleClicked) doubleClicked(event); }
    } content;
    OwnedArray<Strip> strips;
    void navigateRename(const ID &source, int direction) {
        const auto *song = session.song();
        const auto from = std::find(ids.begin(), ids.end(), source);
        if (!song || from == ids.end()) return;
        const int start = int(from - ids.begin());
        for (int index = start + direction; index >= 0 && index < (int)ids.size(); index += direction) {
            const ID target = ids[(size_t)index];
            const auto track = trackTree::index(*song, target);
            if (track >= song->tracks.size() || !canRenameMixerTrack(song->tracks[track])) continue;
            strips[start]->confirmRename();
            selectTrack(target, {});
            revealTrack(target);
            strips[index]->beginRename();
            return;
        }
    }
    std::vector<ID> ids;
    void timerCallback() override {
        if (isShowing()) {
            // Structure changes have a revision; audio level changes do not.
            // Avoid rebuilding the track ID list on every meter tick.
            if (structureRevision != session.revision || (focusedTrack && focusedTrack() != lastFocusedTrack)) {
                refresh(); structureRevision = session.revision;
            } else refreshVisible();
        }
    }
    uint64 structureRevision = ~uint64(0);
};
} // namespace catlive
