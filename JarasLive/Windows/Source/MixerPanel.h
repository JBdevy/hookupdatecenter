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
#include "HozMixerView.h"
#include "Automation.h"
#include "InlineMixerTrackName.h"
#include "VST3Catalog.h"
#include "ModalSheet.h"
#include <array>
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
                event.x >= columns() * channelStride())
                addTrackInEmptyArea();
        };
        if (!focusedTrack) configureToolbar();
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
        g.fillAll(theme::mixerPanelBackground());
        g.setColour(theme::line);
        g.drawHorizontalLine(0, 0, (float)getWidth());
        if (!focusedTrack) {
            g.setColour(Colour(theme::background == theme::darkBackground ? 0xff292929 : 0xff393939));
            for (const auto &group : {viewButtons[0].getBounds(), viewButtons[1].getBounds().getUnion(viewButtons[3].getBounds()),
                     viewButtons[4].getBounds().getUnion(viewButtons[7].getBounds()),
                     viewButtons[8].getBounds().getUnion(viewButtons[9].getBounds())})
                g.fillRoundedRectangle(group.expanded(2, 1).toFloat(), 6);
        }
    }
    static constexpr int focusWidth(bool hasSelectedTrack) { return (hasSelectedTrack ? 2 : 1) * masterStripWidth + 10; }
    static constexpr int minimumHeight() { return 303; }
    HozMixerView viewOptions() const { return mixerView; }
    std::function<void(HozMixerView)> viewOptionsChanged;
    void setViewOptions(HozMixerView options) {
        const bool geometryChanged = mixerView.wide != options.wide;
        for (auto *strip : strips)
            if (mixerView.componentMask(strip->id) != options.componentMask(strip->id))
                strip->controlLayoutPending = true;
        mixerView = std::move(options);
        refreshToolbar();
        if (geometryChanged) resized();
        refresh();
    }
    void resized() override {
        const int inset = focusedTrack ? 5 : 0;
        const int stripTop = focusedTrack ? inset : 20 + toolbarHeight;
        const int stripHeight = std::max(1, getHeight() - stripTop - inset);
        const int innerWidth = std::max(0, getWidth() - 2 * inset);
        const int masterWidth = focusedTrack ? (strips.isEmpty() ? innerWidth : innerWidth / 2) : masterStripWidth;
        const int trackStart = inset + (masterRight ? 0 : masterWidth + 3);
        const int trackWidth = std::max(0, innerWidth - masterWidth - (focusedTrack ? 0 : 3));
        master->setBounds(masterRight?std::max(inset,getWidth()-inset-masterWidth):inset,stripTop,masterWidth,stripHeight);
        if (!focusedTrack) layoutToolbar();
        horizontal.setBounds(trackStart+4,toolbarHeight+5,std::max(0,trackWidth-8),14);
        viewport.setBounds(trackStart,stripTop,trackWidth,stripHeight);
        const int stride = channelStride();
        const int trailingSpace = focusedTrack ? 0 : (stride * 3 + 1) / 2;
        content.setSize(focusedTrack ? trackWidth : std::max(viewport.getWidth(), columns() * stride + trailingSpace),
                        std::max(1, viewport.getHeight()));
        for (int i = 0; i < strips.size(); ++i)
            strips[i]->setBounds(i * stride, 0, focusedTrack ? trackWidth : channelWidth(), content.getHeight());
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
        const int left = index * channelStride(), right = left + channelWidth();
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
    void setVUStyle(meterDisplay::VUStyle style) {
        if (vuStyle == style) return;
        vuStyle = style;
        master->setVUStyle(style);
        for (auto* strip : strips) strip->setVUStyle(style);
    }
    void refresh() {
        std::vector<ID> wanted;
        if (const auto *song = session.song()) refreshRoutingChannels(*song);
        if (focusedTrack) {
            lastFocusedTrack = focusedTrack();
            if (const auto *song = session.song(); song && !lastFocusedTrack.empty() &&
                std::any_of(song->tracks.begin(), song->tracks.end(), [&](const auto &track) { return track.id == lastFocusedTrack; }))
                wanted.push_back(lastFocusedTrack);
        } else if (const auto *song = session.song()) {
            const HozMixerTrackFilter filter(*song, mixerView);
            for (const auto &track : song->tracks)
                if (filter.includes(track) && (!isTrackVisible || isTrackVisible(track.id)))
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
        const int stride = channelStride();
        const int first = std::max(0, visible.getX() / stride);
        const int end = std::min(columns(), (visible.getRight() + stride - 1) / stride);
        for (int index = first; index < end; ++index) {
            auto *strip = strips[index];
            if (!strip->getBounds().intersects(visible)) continue;
            strip->ensureControlLayout();
            strip->refresh();
        }
    }
    void mouseWheelMove(const MouseEvent &event, const MouseWheelDetails &wheel) override {
        if (master->getLocalBounds().contains(event.getEventRelativeTo(master.get()).getPosition())) {
            master->scrollEffects(event.getEventRelativeTo(master.get()),wheel);return;
        }
        const auto point = event.getEventRelativeTo(&content).getPosition();
        const int index = point.x < 0 ? -1 : point.x / channelStride();
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
    static constexpr int toolbarHeight = 30;
    HozMixerView mixerView;
    struct RoutingChannel { String label; String name; };
    ID routingSong;
    uint64 routingRevision = ~uint64(0);
    std::map<ID, RoutingChannel> routingChannels;
    std::map<ID, std::vector<RoutingChannel>> busInputs;

    void refreshRoutingChannels(const jaras::Song &song) {
        if (routingSong == song.id && routingRevision == session.revision) return;
        routingSong = song.id;
        routingRevision = session.revision;
        routingChannels.clear();
        busInputs.clear();
        std::map<ID, size_t> trackOrder;
        for (size_t i = 0; i < song.tracks.size(); ++i) {
            const auto &track = song.tracks[i];
            trackOrder.emplace(track.id, i);
            routingChannels.try_emplace(track.id, RoutingChannel{"Ch - " + String(int(i + 1)), text(track.name)});
        }
        if (focusedTrack) return;
        std::map<ID, std::set<size_t>> sources;
        HozMixerTrackFilter::forEachConnection(song, [&](const jaras::Track &source, const ID &destination) {
            sources[destination].insert(trackOrder.at(source.id));
        });
        for (const auto &track : song.tracks) {
            const auto found = sources.find(track.id);
            if (found == sources.end() && !track.receivesMain()) continue;
            auto &rows = busInputs[track.id];
            if (track.receivesMain()) rows.push_back({"Main", "Main"});
            if (found != sources.end())
                for (size_t index : found->second) rows.push_back(routingChannels.at(song.tracks[index].id));
        }
    }

    static constexpr std::array<const char *, 8> toolbarLabels{
        "Components", "Hoz Mixer All", "Tracks", "Groups", "Audio", "MIDI", "Sends", "Bus"};
    struct MixerViewButton final : Button {
        MixerViewButton() : Button(String()) {}
        int columns = 0;
        bool menu = false;
        void paintButton(Graphics &g, bool hover, bool down) override {
            const auto box = getLocalBounds().toFloat();
            const bool selected = getToggleState();
            if (selected || hover || down) {
                g.setColour(selected ? theme::green : Colours::white.withAlpha(.10f));
                g.fillRoundedRectangle(box, 4);
            }
            g.setColour(selected ? Colours::black : Colours::white);
            if (columns) {
                const juce::Rectangle<float> icon(box.getCentreX()-8, box.getCentreY()-6.5f, 16, 13);
                g.drawRoundedRectangle(icon, 1.5f, 1.1f);
                for (int i = 1; i < columns; ++i)
                    g.drawVerticalLine(roundToInt(icon.getX() + icon.getWidth() * i / columns), icon.getY(), icon.getBottom());
            } else {
                g.setFont(theme::semiboldFont(11));
                auto textBox = getLocalBounds();
                if (menu) {
                    const auto arrow = textBox.removeFromRight(17).toFloat().getCentre();
                    Path path;
                    path.startNewSubPath(arrow.x - 3, arrow.y - 1);
                    path.lineTo(arrow.x, arrow.y + 2);
                    path.lineTo(arrow.x + 3, arrow.y - 1);
                    g.strokePath(path, PathStrokeType(1.2f));
                }
                g.drawFittedText(getName(), textBox, Justification::centred, 1, 0.6f);
            }
        }
    };
    std::array<MixerViewButton, 10> viewButtons;
    int channelWidth() const { return mixerView.wide ? masterStripWidth : stripWidth; }
    int channelStride() const { return channelWidth() + 3; }
    int columns() const { return strips.size(); }
    void configureToolbar() {
        for (size_t i = 0; i < viewButtons.size(); ++i) {
            auto &button = viewButtons[i];
            const auto label = localization::translate(i < toolbarLabels.size() ? toolbarLabels[i] : i == 8 ? "Standard channels" : "Wide channels");
            button.setName(label);
            button.setTitle(label);
            button.setComponentID("hozMixerView:" + String(int(i)));
            button.setWantsKeyboardFocus(false);
            if (i >= 8) {
                button.columns = i == 8 ? 3 : 2;
                button.setTooltip(label);
            }
            button.onClick = [this, i] {
                if (i == 0) {
                    PopupMenu menu;
                    addComponents(menu, {});
                    menu.showMenuAsync(PopupMenu::Options().withTargetComponent(&viewButtons[0]),
                                       [](int) {});
                    return;
                }
                auto options = mixerView;
                if (i < 4) options.scope = static_cast<HozMixerScope>(i - 1);
                else if (i < 8) options.signals ^= 1 << (i - 4);
                else options.wide = i == 9;
                changeViewOptions(options);
            };
            addAndMakeVisible(button);
        }
        viewButtons[0].menu = true;
        refreshToolbar();
    }
    void changeViewOptions(HozMixerView options) {
        if (viewOptionsChanged) viewOptionsChanged(options);
        else setViewOptions(options);
    }
    class ComponentOption final : public PopupMenu::CustomComponent {
    public:
        ComponentOption(String title, bool visible, std::function<bool()> action)
            : PopupMenu::CustomComponent(false), label(std::move(title)), checked(visible), change(std::move(action)) {}
        void getIdealSize(int &width, int &height) override { width = 156; height = 24; }
        void paint(Graphics &g) override {
            auto line = getLocalBounds().reduced(6, 0);
            if (isItemHighlighted()) {
                g.setColour(Colours::white.withAlpha(.08f)); g.fillRoundedRectangle(line.toFloat(), 4);
            }
            auto mark = line.removeFromLeft(17);
            g.setFont(theme::semiboldFont(12));
            if (checked) {
                g.setColour(theme::green); g.drawText(String::fromUTF8("✓"), mark, Justification::centred);
            }
            g.setColour(Colours::white);
            g.drawText(label, line, Justification::centredLeft);
        }
        void mouseUp(const MouseEvent &event) override {
            if (!getLocalBounds().contains(event.getPosition())) return;
            checked = change();
            repaint();
        }
    private:
        String label;
        bool checked;
        std::function<bool()> change;
    };
  public:
    void addComponents(PopupMenu &menu, const ID &track, int commandBase = 1) {
        const auto mask = track.empty() ? mixerView.hiddenComponents : mixerView.componentMask(track);
        for (size_t index = 0; index < std::size(HozMixerView::componentTitles); ++index) {
            const int bit = 1 << index;
            const auto title = localization::translate(HozMixerView::componentTitles[index]);
            const bool visible = (mask & bit) == 0;
            menu.addCustomItem(commandBase + int(index), std::make_unique<ComponentOption>(title, visible,
                [safe = SafePointer<MixerPanel>(this), track, bit, visible] {
                    if (!safe) return visible;
                    auto next = safe->mixerView;
                    if (track.empty()) next.hiddenComponents ^= bit;
                    else next.toggleComponent(track, bit);
                    const bool checked = ((track.empty() ? next.hiddenComponents : next.componentMask(track)) & bit) == 0;
                    safe->changeViewOptions(std::move(next));
                    return checked;
                }), nullptr, title);
        }
    }
  private:
    void refreshToolbar() {
        for (int i = 1; i < 4; ++i)
            viewButtons[i].setToggleState(static_cast<int>(mixerView.scope) == i - 1, dontSendNotification);
        for (int i = 4; i < 8; ++i)
            viewButtons[i].setToggleState((mixerView.signals & (1 << (i - 4))) != 0, dontSendNotification);
        viewButtons[8].setToggleState(!mixerView.wide, dontSendNotification);
        viewButtons[9].setToggleState(mixerView.wide, dontSendNotification);
    }
    void layoutToolbar() {
        auto bar = getLocalBounds().removeFromTop(toolbarHeight).reduced(6, 3);
        auto widths = bar.removeFromRight(67);
        viewButtons[8].setBounds(widths.removeFromLeft(32));
        viewButtons[9].setBounds(widths.removeFromRight(32));
        bar.removeFromRight(6);
        const int leftGap = bar.getWidth() >= 420 ? 20 : 7;
        const int middleGap = bar.getWidth() >= 420 ? 16 : 6;
        const auto font = theme::semiboldFont(11);
        std::array<int, toolbarLabels.size()> widthsByLabel {};
        int requiredWidth = 0;
        for (size_t i = 0; i < toolbarLabels.size(); ++i) {
            widthsByLabel[i] = int(std::ceil(GlyphArrangement::getStringWidth(font, viewButtons[i].getName()))) + (i == 0 ? 28 : 16);
            requiredWidth += widthsByLabel[i];
        }
        const float scale = jlimit(0.f, 1.f, float(bar.getWidth() - leftGap - middleGap - 2 * (int)toolbarLabels.size()) / requiredWidth);
        for (size_t i = toolbarLabels.size(); i-- > 4;) {
            viewButtons[i].setBounds(bar.removeFromRight(int(widthsByLabel[i] * scale)));
            bar.removeFromRight(2);
        }
        bar.removeFromRight(middleGap);
        for (size_t i = 0; i < 4; ++i) {
            if (i == 1) bar.removeFromLeft(leftGap);
            viewButtons[i].setBounds(bar.removeFromLeft(int(widthsByLabel[i] * scale)));
            bar.removeFromLeft(2);
        }
    }
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
    class Strip final : public Component, public DragAndDropTarget, public TooltipClient {
      public:
        Strip(MixerPanel &owner, ID target) : mixer(owner), id(std::move(target)) {
            vu.setStyle(mixer.vuStyle);
            if (!mixer.focusedTrack) addAndMakeVisible(vu);
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
            addChildComponent(hozPatch);
            addChildComponent(hozEnvelope);
            for (auto *button : {&hozPatch, &hozEnvelope}) {
                button->getProperties().set("flat", true);
                button->getProperties().set("fontSize", 10);
                button->setWantsKeyboardFocus(false);
            }
            hozPatch.onClick = [this] { if (mixer.specialAction) mixer.specialAction(id, "patch"); };
            hozEnvelope.setTitle(localization::translate("Envelope"));
            hozEnvelope.getProperties().set("icon", "automationLanes");
            hozEnvelope.setColour(TextButton::buttonOnColourId, theme::green);
            hozEnvelope.setColour(TextButton::textColourOnId, Colours::black);
            hozEnvelope.onClick = [this] { if (mixer.specialAction) mixer.specialAction(id, "envelope"); };
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
                vu.refresh(mixer.session.audio.meterVUMean(id));
                fader.setLinked(t->stereoLinkPartner.has_value());
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
            if (libraryEffectOverStrip) {
                g.setColour(theme::green.withAlpha(.65f));
                g.drawRoundedRectangle(bounds.reduced(1), 5, 2);
            }
            if (!id.empty() || !mixer.session.project().masterMute) return;
            const bool bright = masterMuteBlinkPhase == 0;
            g.setColour(Colour(0xffff3b30).withAlpha(bright ? .28f : .04f));
            g.fillRoundedRectangle(bounds, 5);
            g.setColour(Colour(0xffff3b30).withAlpha(bright ? 1.f : .25f));
            g.drawRoundedRectangle(bounds.reduced(1), 5, 2);
        }
        void setVUStyle(meterDisplay::VUStyle style) { vu.setStyle(style); }
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
                const auto &incoming = busRows();
                const size_t populated = sends.empty() ? 0 : sends.size() - 1;
                const MixerRoutingRows routing{int(populated + outputs.size()) + busRowCount(), hasBus() ? int(populated) : -1};
                Graphics::ScopedSaveState saved(g);g.reduceClipRegion(geometry.outputs.withWidth(getWidth()-4));
                const int top = geometry.outputs.getY() - routing.viewportTop(firstOutput);
                if (routing.busIndex >= firstOutput) {
                    g.setColour(Colours::white.withAlpha(.22f));
                    g.drawHorizontalLine(top + routing.rowTop(routing.busIndex) - 5,
                                         float(geometry.outputs.getX()), float(geometry.outputs.getRight()));
                }
                for (int i = firstOutput; i < routing.count; ++i) {
                    const int y = top + routing.rowTop(i);
                    if (y >= geometry.outputs.getBottom()) break;
                    const auto bounds = geometry.outputs.withY(y).withHeight(MixerRoutingRows::rowHeight).toFloat();
                    const auto row = size_t(i);
                    if (row < populated) {
                        const auto &slot = sends[row + 1];
                        const auto channel = slot.destination ? mixer.routingChannels.find(*slot.destination) : mixer.routingChannels.end();
                        paintSlot(g, bounds, channel == mixer.routingChannels.end() ? "—" : channel->second.label, SlotTone::routed);
                        continue;
                    }
                    const auto index = row - populated;
                    if (hasBus() && index == 0) {
                        paintSlot(g, bounds, "Bus", SlotTone::empty);
                        continue;
                    }
                    if (index < size_t(busRowCount())) {
                        paintSlot(g, bounds, incoming[index - 1].label, SlotTone::routed, true);
                        continue;
                    }
                    const auto &output = outputs[index - size_t(busRowCount())];
                    const String title=output.firstChannel==-2?"M-group":output.firstChannel==-1?localization::translate("None"):
                        output.firstChannel==0?"Main":String(output.firstChannel)+(output.channelCount==2?"+"+String(output.firstChannel+1):String{});
                    paintSlot(g, bounds, title, output.firstChannel == -1 ? SlotTone::empty : SlotTone::routed);
                }
                if (const int maximum = routing.maximumFirstRow(geometry.outputs.getHeight()); maximum > 0) {
                    const float height = float(geometry.outputs.getHeight());
                    const float thumb = std::min(height, height * height / std::max(1.f, float(routing.contentHeight())));
                    const float y = geometry.outputs.getY() + (height - thumb) * firstOutput / maximum;
                    g.setColour(theme::green.withAlpha(.15f));g.fillRoundedRectangle(getWidth()-3.f,(float)geometry.outputs.getY(),2,height,1);
                    g.setColour(theme::green);g.fillRoundedRectangle(getWidth()-3.f,y,2,thumb,1);
                }
            }
            if (teleprompterPatch.isVisible())
                meterDisplay::compactRail(g, compactMeterBounds().toFloat(), mixer.session.audio.meterLevels(id));
            if (fader.isVisible() && fader.isVertical()) drawFaderScale(g);
            const auto shownVolume = mixer.session.trackDisplayVolume(id,t->volume);
            const auto db = shownVolume > 0 ? String(Decibels::gainToDecibels(shownVolume), 1)
                                          : String::fromUTF8("−∞");
            g.setColour(Colours::white);
            if (pan.isVisible()) {
                g.setFont(theme::mediumFont(8));
                g.drawText(mixerPanText(t->pan),
                           pan.getX() - (52 - pan.getWidth()) / 2, pan.getY() - 10, 52, 10, Justification::centred);
            }
            if (fader.isVisible() && fader.isVertical()) {
                const auto value = (shownVolume >= 1 ? "+" : "") + db;
                const String unit = " dB";
                const auto valueFont = theme::semiboldFont(9.5f);
                const auto unitFont = theme::mediumFont(7.5f);
                const auto valueWidth = GlyphArrangement::getStringWidth(valueFont, value);
                const auto unitWidth = GlyphArrangement::getStringWidth(unitFont, unit);
                const auto bounds = gainReadoutBounds().toFloat();
                const float left = bounds.getCentreX() - (valueWidth + unitWidth) / 2.f;
                const int baseline = roundToInt(bounds.getCentreY() + (valueFont.getAscent() - valueFont.getDescent()) / 2.f);
                g.setFont(valueFont);
                g.drawSingleLineText(value, roundToInt(left), baseline);
                g.setColour(Colour(0xffa1aab4));
                g.setFont(unitFont);
                g.drawSingleLineText(unit, roundToInt(left + valueWidth), baseline);
            }
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
                        const int colorTop = labelEnd + 14;
                        if (mixer.focusedTrack) {
                            g.fillRoundedRectangle(4.f, float(colorTop), float(std::max(1, getWidth() - 8)),
                                                   float(theme::hozMixerStripeHeight), 1.f);
                        } else {
                            Graphics::ScopedSaveState scope(g);
                            const auto footer = getLocalBounds().withTrimmedTop(colorTop);
                            if (g.reduceClipRegion(footer)) g.fillRoundedRectangle(bounds, 5.f);
                        }
                    }
                }
            }
            if (t && !id.empty() && shows(HozMixerView::icon) && geometry.controlsHeight >= 158) {
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
        void ensureControlLayout() {
            if (!controlLayoutPending) return;
            resized();
            if (!controlLayoutPending) repaint();
        }
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
            const bool normal = standard && !id.empty();
            const bool metronome = t && t->role.id == "generatedClick";
            const bool muteSolo = standard || (t && (t->role.id == "timecode" || metronome || t->role.id == "programChange"));
            fx.setVisible(standard && shows(HozMixerView::fx));
            record.setVisible(normal && shows(HozMixerView::rec));
            monitor.setVisible(normal && t->role.id != "vinhetas" && shows(HozMixerView::inputMonitor));
            pan.setVisible(standard && shows(HozMixerView::pan));
            mono.setVisible(id.empty());
            fader.setVisible((teleprompter || (!textTrack && t && t->role.id != "programChange")) && shows(HozMixerView::fader));
            mute.setVisible(muteSolo && shows(HozMixerView::mute));
            solo.setVisible(muteSolo && shows(HozMixerView::solo));
            phase.setVisible(normal && t->role.id != "vinhetas" && shows(HozMixerView::phase));
            vu.setVisible(!mixer.focusedTrack && shows(HozMixerView::vu));
            hozPatch.setVisible(!mixer.focusedTrack && (normal || metronome) && shows(HozMixerView::patch));
            hozEnvelope.setVisible(!mixer.focusedTrack && normal && automation::trackSupportsLanes(*t) && shows(HozMixerView::envelope));
            if (hozEnvelope.isVisible()) hozEnvelope.setToggleState(!automation::visible(*t).isEmpty(), dontSendNotification);
            const auto faderStyle = teleprompter ? Slider::RotaryVerticalDrag : Slider::LinearVertical;
            if(fader.getSliderStyle()!=faderStyle)fader.setSliderStyle(faderStyle);
            teleprompterPatch.setVisible(teleprompter && shows(HozMixerView::patch));
            const auto geometry=layout();
            rename.layoutIn(geometry.name);
            if (vu.isVisible())
                vu.setBounds(4, geometry.controlsY - meterDisplay::vuStripHeight - 2, std::max(0, getWidth() - 8), meterDisplay::vuStripHeight);
            firstSlot=jlimit(0,maximumFirstSlot(),firstSlot);
            const bool extra = hozPatch.isVisible() || hozEnvelope.isVisible() || (metronome && !mixer.focusedTrack && shows(HozMixerView::insert));
            const int y = geometry.controlsY + (extra ? 23 : 0);
            const int available = std::max(0, geometry.controlsHeight - (extra ? 23 : 0));
            if (extra) {
                hozPatch.setBounds((getWidth() - 81) / 2, geometry.controlsY, 34, 20);
                hozEnvelope.setBounds((getWidth() - 9) / 2, geometry.controlsY, 26, 20);
            }
            if (special) {
                const bool compactInsert = metronome && !mixer.focusedTrack;
                if (metronome) special->setMixerMetronomeInsertOnly(compactInsert);
                special->setVisible(!standard && !teleprompter && (!compactInsert || shows(HozMixerView::insert)));
                special->setBounds(compactInsert ? (getWidth() - 5) / 2 : (getWidth() - 47) / 2,
                    compactInsert ? geometry.controlsY : y, 44, t && t->role.id == "programChange" ? 72 : 21);
                special->refresh();
            }
            const int buttonRows = phase.isVisible() ? 6 : 4;
            const int iconSpace = !id.empty() && shows(HozMixerView::icon) && trackIcons::contains(t ? t->instrumentIcon : std::nullopt) && available >= 158 ? (mixer.focusedTrack ? 48 : getWidth() * 2 / 5 + 8) : 0;
            const int gap = jlimit(2, 5, (available - 12 - iconSpace - 21 * buttonRows) / buttonRows);
            const int buttonHeight = jlimit(12, 21, (available - 12 - iconSpace - buttonRows * gap) / buttonRows);
            const int step=buttonHeight+gap;
            peak->setVisible(!textTrack && t && t->role.id != "programChange" && shows(HozMixerView::peak));
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
                fader.setBounds(45 + controlsOffset(), y + faderOffset, 31, std::max(1,available-faderOffset));
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
                    if (busHeaderAt(event.getPosition())) showRoutePicker({}, true, event.getPosition());
                    else if (const auto slot = sendAt(event.getPosition())) showSendMenu(*slot);
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
            const auto *item = track();
            if (!item || !canRenameMixerTrack(*item) || !event.mods.isLeftButtonDown() ||
                event.mods.isAnyModifierKeyDown()) return;
            const auto space = layout().name;
            const int width = roundToInt(std::ceil(GlyphArrangement::getStringWidth(theme::semiboldFont(10), text(item->name))));
            if (space.withSizeKeepingCentre(std::min(width, space.getWidth()), space.getHeight())
                    .contains(event.getPosition())) beginRename();
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
            if (!pressedPower && pressedEffect.isNotEmpty() && e.mods.isLeftButtonDown() && e.getDistanceFromDragStart() > 8) {
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
                const auto released = e.getPosition();
                if (e.getDistanceFromDragStart() <= 8 && !e.mods.isPopupMenu() && mixer.specialAction &&
                    (layout().sends.contains(released) || outputIndexAt(released) >= 0))
                    mixer.specialAction(id, "patch");
                return;
            }
            if(pendingSelection&&e.getDistanceFromDragStart()<=8)mixer.selectTrack(id,e.mods);
            pendingSelection=false;
            if (pressedSlot >= 0 && !e.mods.isPopupMenu() && e.getDistanceFromDragStart() <= 8) {
                if (e.mods.isAltDown() || e.mods.isShiftDown()) {
                    if (pressedEffect.isNotEmpty()) changeEffect(pressedEffect,e.mods.isAltDown());
                } else if (pressedPower) {
                    if (powerBounds(pressedSlot).contains(e.getPosition())) changeEffect(pressedEffect, false);
                } else mixer.openEffects(id,pressedEffect.isEmpty() ? String("Library") : pressedEffect);
            }
            dragging = false; pressedPower = false; pressedSlot = -1; pressedEffect.clear();
        }
        bool isInterestedInDragSource(const SourceDetails &d) override {
            if (isLibraryEffectDrag(d.description) || isEffectDrag(d.description))
                return id.empty() || (track() && jaras::fixedTrackName(track()->role).empty());
            if(id.empty()) return false;
            return mixer.session.song()&&!trackDrop::source(d.description,mixer.session.project(),*mixer.session.song()).empty();
        }
        void itemDragEnter(const SourceDetails &d) override {itemDragMove(d);}
        void itemDragMove(const SourceDetails &d) override {
            const bool library = isLibraryEffectDrag(d.description);
            if (library || isEffectDrag(d.description)) {
                effectDropSlot = slotAt(d.localPosition);
                libraryEffectOverStrip = library && effectDropSlot < 0;
                mixer.dropPreview.reset(); mixer.blocked.clear(); repaint(); return;
            }
            if(id.empty()) return;
            if(!mixer.session.song())return;
            mixer.dropPreview=trackDrop::resolve(*mixer.session.song(),trackDrop::sources(d.description,mixer.session.project(),*mixer.session.song()),id,d.localPosition.x>getWidth()/2,d.localPosition.y<16);
            mixer.blocked=mixer.dropPreview?ID{}:id;mixer.repaint();
        }
        void itemDragExit(const SourceDetails &) override {effectDropSlot=-1;libraryEffectOverStrip=false;mixer.dropPreview.reset();mixer.blocked.clear();mixer.repaint();repaint();}
        void itemDropped(const SourceDetails &d) override {
            const bool library = isLibraryEffectDrag(d.description);
            if (library || isEffectDrag(d.description)) {
                const int slot = slotAt(d.localPosition); itemDragExit(d);
                if ((!library && slot < 0) || !isInterestedInDragSource(d)) return;
                auto settings = fxchain::settings(mixer.session, id);
                auto chain = list(get(settings, "inserted"));
                try {
                    const auto before = isPositiveAndBelow(slot, chain.size()) ? chain[slot].toString() : String();
                    if (library) {
                        mixer.session.insertLibraryEffect(id, str(d.description, "identity"), str(d.description, "preset"), before);
                    } else {
                        const auto source = utf8(str(d.description, "source"));
                        const auto effect = str(d.description, "effect");
                        if (source != id) {
                            mixer.session.copyEffect(source, effect, id, before);
                        } else if (effect != before && chain.contains(var(effect))) {
                            chain.removeFirstMatchingValue(var(effect));
                            chain.insert(before.isEmpty() ? chain.size() : chain.indexOf(var(before)), effect);
                            put(settings, "inserted", chain);
                            mixer.session.configureEffects(id, settings);
                        }
                    }
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
        friend class MixerPanel;
        bool shows(int component) const {
            return id.empty() || mixer.focusedTrack || (mixer.mixerView.componentMask(id) & component) == 0;
        }
        MixerPanel &mixer;
        ID id;
        bool controlLayoutPending=false;
        int masterMuteBlinkPhase = -1;
        jaras::Track masterPresentation; // View state only; Master is never added to the song's tracks.
        uint64 lastRevision = ~uint64(0);
        bool lastSelection = false, lastLocked = false, lastMute = false, lastSolo = false;
        double lastVolume = -1;
        meterDisplay::RepaintState compactMeterRepaint;
        meterDisplay::ClassicVU vu;
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
            // Track - I and the expanded mixer have a 128-point reference travel on Mac.
            // The compact Hoz Mixer reserves more room for its footer and uses 114.
            const double labelTravel = std::min<double>(travel, mixer.focusedTrack || layout().slots.getHeight() > 0 ? 128. : 114.);
            const auto fraction = [](int db) { return 1. - (db + 60.) / 72.; };
            std::array<int, priority.size()> labels{};
            size_t used = 0;
            const int minorStep = travel >= 216.f ? 1 : travel >= 72.f ? 3 : 6;
            const int right = roundToInt(fader.getBounds().getCentreX() - meterDisplay::railThickness / 2 - 1);
            for (int db : priority) {
                const auto y = position(db);
                if (std::any_of(labels.begin(), labels.begin() + used, [&](int other) { return std::abs(fraction(db)-fraction(other))*labelTravel < 9.5; }))
                    continue;
                labels[used++] = db;
                g.setColour(Colours::white.withAlpha(.82f));
                g.setFont(theme::font(8));
                const auto text = db == -60 ? String::fromUTF8("−∞") : db > 0 ? "+" + String(db) : String(std::abs(db));
                g.drawText(text, right-26, roundToInt(y)-5,
                           19, 10, Justification::centredRight, false);
            }
            for (int db = -60; db <= 12; ++db) {
                const auto y = position(db);
                const bool labelled = std::find(labels.begin(), labels.begin()+used,db) != labels.begin()+used;
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
        bool libraryEffectOverStrip = false;
        int firstOutput=0;
        bool pressedOutput=false, pressedPower=false;
        String pressedEffect;
        friend struct MasterMixerTests;
        bool pendingSelection=false;
        friend struct HozMixerFocusTests;
        std::vector<jaras::OutputPatch> outputPatches() const {
            if (!shows(HozMixerView::outputs)) return {};
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
            if (!hasSends()) return {};
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
        const std::vector<RoutingChannel> &busRows() const {
            static const std::vector<RoutingChannel> empty;
            const auto found = mixer.busInputs.find(id);
            return found != mixer.busInputs.end() ? found->second : empty;
        }
        bool hasBus() const {
            const auto *row = track();
            return !id.empty() && !mixer.focusedTrack && hasSends() && row && row->role.id != "vinhetas";
        }
        int busRowCount() const { return hasBus() ? int(busRows().size()) + 1 : 0; }
        bool busHeaderAt(Point<int> position) const {
            return hasBus() && outputIndexAt(position) == populatedSendCount();
        }
        int populatedSendCount() const {
            if (!hasSends()) return 0;
            if (id.empty()) {
                const auto *song = mixer.session.song();
                return song ? int(std::count_if(song->tracks.begin(), song->tracks.end(),
                    [](const auto &row) { return row.receivesMain(); })) : 0;
            }
            const auto *row = track();
            return row && row->routing ? int(std::count_if(row->routing->transmitters.begin(),
                row->routing->transmitters.end(), [](const auto &destination) { return destination.has_value(); })) : 0;
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
            int count = busRowCount() + populatedSendCount() + int(hasSends());
            if (shows(HozMixerView::outputs))
                count += row->outputs ? int(row->outputs->size()) : 1 + int(row->secondaryPatch.has_value());
            return count;
        }
        bool hasSends() const {
            return shows(HozMixerView::sendSlots) &&
                (id.empty() || (track() && jaras::fixedTrackName(track()->role).empty()));
        }
        int outputIndexAt(Point<int> position) const {
            const auto bounds = layout().outputs;
            if (!bounds.contains(position)) return -1;
            return routingRows().rowAt(position.y - bounds.getY(), firstOutput);
        }
        MixerRoutingRows routingRows() const {
            return {outputRowCount() - int(hasSends()), hasBus() ? populatedSendCount() : -1};
        }
        std::optional<SendSlot> sendAt(Point<int> position) const {
            const auto slots = sendSlots();
            if (slots.empty()) return {};
            if (layout().sends.contains(position)) return slots.front();
            const int index = outputIndexAt(position);
            if (index < 0 || size_t(index + 1) >= slots.size()) return {};
            return slots[size_t(index + 1)];
        }
        String getTooltip() override {
            const auto position = getMouseXYRelative();
            const auto row = outputIndexAt(position);
            if (row < 0) return {};
            if (const auto send = sendAt(position); send && send->destination) {
                const auto channel = mixer.routingChannels.find(*send->destination);
                return channel == mixer.routingChannels.end() ? String{} : channel->second.name;
            }
            const auto incoming = row - populatedSendCount() - 1;
            if (incoming >= 0 && incoming < int(busRows().size())) return busRows()[size_t(incoming)].name;
            return {};
        }
        void updateSend(const SendSlot &slot, std::optional<ID> destination,
                        std::optional<jaras::TrackSendTap> tap = {}, std::optional<ID> sender = {}) {
            const auto sourceID = sender.value_or(id);
            if (!mixer.session.song() || mixer.session.audio.isRecording()) return;
            const auto activeSong = mixer.session.song()->id;
            try {
                mixer.session.editTrackSettings([&](jaras::Project &project) {
                    for (auto &song : project.songs) {
                        if (song.id != activeSong) continue;
                        if (sourceID.empty()) {
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
                        auto source = std::find_if(song.tracks.begin(), song.tracks.end(), [&](const auto &row) { return row.id == sourceID; });
                        if (source == song.tracks.end()) continue;
                        if (!source->routing) source->routing = jaras::TrackRouting{{}, {}};
                        auto &routing = *source->routing;
                        auto &sends = routing.transmitters;
                        if (!tap && destination) {
                            const auto target = std::find_if(song.tracks.begin(), song.tracks.end(),
                                [&](const auto &row) { return row.id == *destination; });
                            if (target == song.tracks.end() || target->id == sourceID || !jaras::fixedTrackName(target->role).empty() ||
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
                        if (before) {
                            routing.sendTaps.erase(*before);
                            routing.sendGains.erase(*before);
                        }
                        sends[slot.slot] = destination;
                        for (auto &row : song.tracks) {
                            if (before && row.id == *before && row.routing)
                                for (auto &receive : row.routing->receives) if (receive == sourceID) receive.reset();
                            if (!destination || row.id != *destination) continue;
                            if (!row.routing) row.routing = jaras::TrackRouting{{}, {}};
                            auto &receive = row.routing->receives;
                            if (std::find(receive.begin(), receive.end(), sourceID) != receive.end()) continue;
                            const auto free = std::find_if(receive.begin(), receive.end(), [&](const auto &entry) {
                                return !entry && row.routing->mainReceiveSlot != int(&entry - receive.data());
                            });
                            if (free == receive.end()) receive.push_back(sourceID);
                            else *free = sourceID;
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
            showRoutePicker(slot, false, layout().sends.getCentre());
        }
        void showRoutePicker(const SendSlot &slot, bool receive, Point<int> point) {
            const auto *source = track();
            const auto *song = mixer.session.song();
            if (!source || !song) return;
            std::set<ID> routed;
            if (!id.empty()) HozMixerTrackFilter::forEachConnection(*song, [&](const auto &from, const ID &to) {
                if (receive && to == id) routed.insert(from.id);
                if (!receive && from.id == id) routed.insert(to);
            });
            std::vector<SendPicker::Destination> rows;
            for (const auto &row : song->tracks) {
                const bool current = slot.destination == row.id;
                const bool alreadyRouted = id.empty() ? row.receivesMain() : routed.count(row.id) != 0;
                rows.push_back({row.id, text(row.name), row.id != id && jaras::fixedTrackName(row.role).empty() && (!alreadyRouted || current), current});
            }
            const auto project = mixer.session.project().id, songID = song->id;
            auto picker = std::make_unique<SendPicker>(rows, [safe = Component::SafePointer<Strip>(this), project, songID, slot, receive](ID other) {
                const auto *current = safe ? safe->mixer.session.song() : nullptr;
                if (!current || safe->mixer.session.project().id != project || current->id != songID) return;
                if (!receive) { safe->updateSend(slot, other); return; }
                const auto sender = std::find_if(current->tracks.begin(), current->tracks.end(),
                    [&](const auto &row) { return row.id == other; });
                if (sender == current->tracks.end() || !jaras::fixedTrackName(sender->role).empty()) return;
                bool exists = false;
                HozMixerTrackFilter::forEachConnection(*current, [&](const auto &from, const ID &to) {
                    if (from.id == other && to == safe->id) exists = true;
                });
                if (exists) return;
                const auto next = sender->routing ? sender->routing->transmitters.size() : size_t(0);
                safe->updateSend({next, {}}, safe->id, {}, other);
            });
            const int columns = std::min(3, (int(rows.size()) + SendPicker::blockSize - 1) / SendPicker::blockSize);
            if (auto *host = getTopLevelComponent()) {
                picker->setSize(std::min(std::max(1, host->getWidth() - 48), std::max(1, columns) * 210 + 26),
                                std::min(std::max(1, host->getHeight() - 64), SendPicker::headingHeight +
                                         std::min(int(rows.size()), SendPicker::blockSize) * SendPicker::rowHeight + 34));
                const auto bounds = layout();
                const auto routing = routingRows();
                const auto busY = bounds.outputs.getY() + routing.rowTop(routing.busIndex) - routing.viewportTop(firstOutput);
                const auto area = receive ? bounds.outputs.withY(busY).withHeight(MixerRoutingRows::rowHeight).getIntersection(bounds.outputs) : bounds.sends;
                const auto anchor = host->getLocalArea(this, area.isEmpty() ? juce::Rectangle<int>(point.x, point.y, 1, 1) : area);
                static SendCalloutLook look;
                auto &popup = CallOutBox::launchAsynchronously(std::move(picker), anchor, host);
                popup.setLookAndFeel(&look);
                popup.setDismissalMouseClicksAreAlwaysConsumed(true);
            }
        }
        int maximumFirstOutput() const {
            return routingRows().maximumFirstRow(layout().outputs.getHeight());
        }
        struct StripLayout { juce::Rectangle<int> slots,name,outputs,bypass,sends;int controlsY=0,controlsHeight=0; };
        StripLayout layout() const {
            const int height=std::max(1,getHeight());
            const int vuHeight = mixer.focusedTrack || !shows(HozMixerView::vu) ? 0 : meterDisplay::vuStripHeight + 2;
            const auto sections=[&](int slots,int nameY,int controlsY,int controls) {
                const MixerSlotSections areas(slots, 1, id.empty(), !mixer.focusedTrack);
                const int header = hasSends() ? std::min(21, areas.outputs) : 0;
                const int routingY = 13 + slots - areas.outputs;
                return StripLayout{{3,13,std::max(0,getWidth()-6),shows(HozMixerView::fx) ? areas.plugins : 0},
                    {3,nameY,std::max(0,getWidth()-6),std::min(22,std::max(0,height-nameY))},
                    {3,routingY+header,std::max(0,getWidth()-6),areas.outputs-header},
                    {3,13+areas.plugins,std::max(0,getWidth()-6),shows(HozMixerView::fx) ? areas.divider : 0},
                    {3,routingY,std::max(0,getWidth()-6),header>=19?19:0},controlsY,controls};
            };
            const int inner=std::max(0,height-22-vuHeight);
            const int controls=std::min(205,std::max(100,inner-40));
            const int slots=std::max(0,inner-controls-40);
            // Grow the controls until the strip has enough room for a full FX row.
            if (!mixer.focusedTrack && slots < MixerRoutingRows::rowHeight) {
                const int controlsY = 4 + vuHeight;
                const int compactControls = std::min(205, std::max(0, height - controlsY - 4 - 40));
                return sections(0, controlsY + compactControls + 4, controlsY, compactControls);
            }
            return sections(slots,13+slots+vuHeight+controls+4,13+slots+vuHeight,controls);
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
        static void paintSlot(Graphics& g, juce::Rectangle<float> bounds, const String& title, SlotTone tone, bool receivedBus = false) {
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
            if (receivedBus) {
                const auto center = bounds.removeFromRight(13.f).getCentre();
                Path arrow;
                arrow.startNewSubPath(center.x + 3.f, center.y - 4.f);
                arrow.lineTo(center.x + 3.f, center.y + 2.f);
                arrow.lineTo(center.x - 3.f, center.y + 2.f);
                arrow.startNewSubPath(center.x - 1.f, center.y);
                arrow.lineTo(center.x - 3.f, center.y + 2.f);
                arrow.lineTo(center.x - 1.f, center.y + 4.f);
                g.setColour(theme::green);
                g.strokePath(arrow, PathStrokeType(1.f, PathStrokeType::curved, PathStrokeType::rounded));
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
        TextButton hozPatch{"Patch"}, hozEnvelope;
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
    meterDisplay::VUStyle vuStyle = meterDisplay::VUStyle::purple;
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
    static constexpr int stripWidth=100,masterStripWidth=stripWidth*5/4;
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
