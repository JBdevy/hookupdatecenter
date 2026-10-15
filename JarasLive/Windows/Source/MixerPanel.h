#pragma once
#include "Session.h"
namespace catlive {
class MixerPanel final : public Component, private Timer {
  public:
    MixerPanel(Session &owner, std::function<void(ID)> effects, std::function<void(ID)> selected,
               std::function<void(String)> failure)
        : session(owner), openEffects(std::move(effects)), selectTrack(std::move(selected)),
          error(std::move(failure)) {
        addAndMakeVisible(viewport);
        viewport.setViewedComponent(&content, false);
        viewport.setScrollBarsShown(false, true);
        viewport.setScrollBarThickness(10);
        viewport.addMouseListener(this, true);
        startTimerHz(24);
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
    void mouseWheelMove(const MouseEvent &, const MouseWheelDetails &wheel) override {
        viewport.setViewPosition(
            jlimit(0, std::max(0, content.getWidth() - viewport.getViewWidth()),
                   viewport.getViewPositionX() -
                       (int)((wheel.deltaX != 0 ? wheel.deltaX : wheel.deltaY) * 320)),
            0);
    }
    int scrollX() const { return viewport.getViewPositionX(); }

  private:
    class Strip final : public Component {
      public:
        Strip(MixerPanel &owner, ID target) : mixer(owner), id(std::move(target)) {
            for (auto *button : {&fx, &mute, &solo, &phase, &record}) {
                addAndMakeVisible(button);
                button->getProperties().set("flat", true);
                button->getProperties().set("fontSize", 11);
                button->setWantsKeyboardFocus(false);
                button->setColour(TextButton::buttonColourId, Colours::white.withAlpha(.15f));
            }
            mute.setColour(TextButton::buttonOnColourId, Colour(0xffff4444));
            solo.setColour(TextButton::buttonOnColourId, theme::yellow);
            fx.onClick = [this] { mixer.openEffects(id); };
            mute.onClick = [this] { command(jaras::CommandKind::mute); };
            solo.onClick = [this] { command(jaras::CommandKind::solo); };
            phase.onClick = [this] { command(jaras::CommandKind::phase); };
            record.setColour(TextButton::buttonOnColourId, Colour(0xffec4848));
            record.onClick = [this] {
                try {
                    mixer.session.cycleRecordArm(id);
                } catch (const std::exception &e) {
                    mixer.error(String::fromUTF8(e.what()));
                }
            };
            addAndMakeVisible(fader);
            fader.setComponentID("mixerFader");
            fader.setRange(0, 2, .001);
            fader.setSliderStyle(Slider::LinearVertical);
            fader.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
            fader.setDoubleClickReturnValue(true, 1);
            fader.setScrollWheelEnabled(false);
            fader.onValueChange = [this] { command(jaras::CommandKind::volume, fader.getValue()); };
            addAndMakeVisible(pan);
            pan.setComponentID("mixerPan");
            pan.setRange(-1, 1, .01);
            pan.setSliderStyle(Slider::LinearHorizontal);
            pan.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
            pan.setDoubleClickReturnValue(true, 0);
            pan.setScrollWheelEnabled(false);
            pan.onValueChange = [this] { command(jaras::CommandKind::pan, pan.getValue()); };
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
                fader.setValue(t->volume, dontSendNotification);
                pan.setValue(t->pan, dontSendNotification);
                mute.setToggleState(t->mute, dontSendNotification);
                solo.setToggleState(t->solo, dontSendNotification);
                phase.setToggleState(t->phaseInverted.value_or(false), dontSendNotification);
                const bool textTrack = jaras::isTeleprompterRole(t->role) || t->role.id == "chords";
                for (auto *c :
                     std::initializer_list<Component *>{&fader, &pan, &mute, &solo, &phase, &fx})
                    c->setVisible(!textTrack);
                fx.setEnabled(t->role.id != "generatedClick" && t->role.id != "timecode");
                record.setVisible(jaras::fixedTrackName(t->role).empty());
                record.setButtonText(mixer.session.recordArm(id) == 2 ? "A" : "REC");
                record.setToggleState(mixer.session.recordingArmed(id), dontSendNotification);
                repaint();
            }
        }
        void paint(Graphics &g) override {
            const auto *t = track();
            if (!t)
                return;
            const auto colour = theme::track(*t);
            g.fillAll(colour.withAlpha(.35f));
            g.setColour(colour);
            g.fillRect(0, 0, getWidth(), 3);
            auto settings = t->fxJSON ? JSON::parse(text(*t->fxJSON)) : var();
            const auto chain = list(get(settings, "inserted"));
            for (int i = 0; i < 3; ++i) {
                g.setColour(Colours::black.withAlpha(.25f));
                g.fillRect(3, 5 + i * 21, getWidth() - 6, 20);
                if (i < chain.size()) {
                    g.setColour(Colours::white);
                    g.setFont(theme::semiboldFont(10));
                    g.drawFittedText(chain[i].toString().upToFirstOccurrenceOf(":", false, false),
                                     7, 5 + i * 21, getWidth() - 14, 20, Justification::centredLeft,
                                     1);
                }
            }
            const int controls = std::max(76, getHeight() - 218), meterTop = controls + 55,
                      meterBottom = getHeight() - 27;
            g.setColour(Colours::black.withAlpha(.45f));
            g.fillRect(70, meterTop, 3, meterBottom - meterTop);
            g.fillRect(75, meterTop, 3, meterBottom - meterTop);
            const float peak = mixer.session.audio.trackPeak(id);
            const auto level = jlimit(0.f, 1.f, (Decibels::gainToDecibels(peak, -60.f) + 60) / 60);
            const int filled = (int)((meterBottom - meterTop) * level);
            g.setColour(peak > 1 ? Colours::red : theme::green);
            g.fillRect(70, meterBottom - filled, 3, filled);
            g.fillRect(75, meterBottom - filled, 3, filled);
            const auto db = t->volume > 0 ? String(Decibels::gainToDecibels(t->volume), 1)
                                          : String::fromUTF8("−∞");
            g.setColour(Colours::white);
            g.setFont(theme::semiboldFont(9));
            g.drawText((t->volume >= 1 ? "+" : "") + db + " dB", 28, controls + 30, 52, 16,
                       Justification::centred);
            g.setFont(theme::semiboldFont(10));
            g.drawFittedText(text(t->name), 3, getHeight() - 24, getWidth() - 6, 20,
                             Justification::centred, 1);
        }
        void resized() override {
            const int y = std::max(76, getHeight() - 218);
            fx.setBounds(4, y, 22, 21);
            mute.setBounds(4, y + 26, 22, 21);
            solo.setBounds(4, y + 52, 22, 21);
            phase.setBounds(4, y + 78, 22, 21);
            record.setBounds(3, y + 104, 25, 21);
            pan.setBounds(31, y, 44, 26);
            fader.setBounds(31, y + 46, 31, std::max(25, getHeight() - y - 73));
        }
        void mouseDown(const MouseEvent &event) override {
            mixer.selectTrack(id);
            if (event.y < 70 || event.mods.isPopupMenu())
                mixer.openEffects(id);
        }

      private:
        MixerPanel &mixer;
        ID id;
        TextButton fx{"FX"}, mute{"M"}, solo{"S"}, phase{String::fromUTF8("Ø")}, record{"REC"};
        Slider fader, pan;
        void command(jaras::CommandKind kind, double value = 0) {
            try {
                mixer.session.command(kind, id, value);
            } catch (const std::exception &e) {
                mixer.error(String::fromUTF8(e.what()));
            }
        }
    };
    Session &session;
    std::function<void(ID)> openEffects, selectTrack;
    std::function<void(String)> error;
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
