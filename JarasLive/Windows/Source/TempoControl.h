#pragma once
#include "Session.h"
namespace catlive {
class TempoControl final : public Component {
  public:
    TempoControl(Session &owner, std::function<void(String)> report)
        : session(owner), error(std::move(report)) {
        for (auto *b : {&up, &down}) {
            addAndMakeVisible(b);
            b->getProperties().set("plain", true);
            b->getProperties().set("fontSize", 15);
            b->setWantsKeyboardFocus(false);
        }
        up.onClick = [this] { change(1); };
        down.onClick = [this] { change(-1); };
        up.setTooltip("Aumentar BPM");
        down.setTooltip("Diminuir BPM");
        addAndMakeVisible(bpm);
        bpm.setFont(theme::semiboldFont(16));
        bpm.setJustificationType(Justification::centred);
        bpm.setEditable(false, true, false);
        bpm.setColour(Label::textColourId, Colours::white);
        bpm.onTextChange = [this] {
            if (updating)
                return;
            const double value = bpm.getText().replaceCharacter(',', '.').getDoubleValue();
            if (value < 60 || value > 300) {
                refresh();
                return;
            }
            apply(value, 0, 0);
        };
        refresh();
    }
    void refresh() {
        updating = true;
        if (const auto *song = session.song())
            bpm.setText(String(song->bpm, song->bpm == std::floor(song->bpm) ? 0 : 1),
                        dontSendNotification);
        updating = false;
        repaint();
    }
    void paint(Graphics &g) override {
        g.setColour(Colour(0xff121212));
        g.fillRoundedRectangle(getLocalBounds().toFloat(), 4);
        g.setColour(theme::line);
        g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(.5f), 4, 1);
        if (const auto *song = session.song()) {
            const float scale = getWidth() / 171.f;
            g.setColour(theme::line);
            for (float x : {4.f, 48.f})
                g.drawRoundedRectangle(x * scale, 8, 30 * scale, getHeight() - 16.f, 4, 1);
            g.setFont(theme::font(13));
            g.setColour(Colours::white);
            g.drawText(String(song->beatsPerBar), roundToInt(4 * scale), 0,
                       roundToInt(30 * scale), getHeight(), Justification::centred);
            g.drawText("/", roundToInt(37 * scale), 0, roundToInt(8 * scale), getHeight(),
                       Justification::centred);
            g.drawText(String(song->beatUnit), roundToInt(48 * scale), 0,
                       roundToInt(30 * scale), getHeight(), Justification::centred);
        }
        g.setColour(theme::secondary);
        g.setFont(theme::font(8));
        g.drawText("BPM", signatureWidth(), getHeight() - 14, roundToInt(58 * getWidth() / 171.f),
                   11, Justification::centred);
    }
    void resized() override {
        const float scale = getWidth() / 171.f;
        bpm.setBounds(signatureWidth(), 3, roundToInt(58 * scale), getHeight() - 16);
        up.setBounds(roundToInt(142 * scale), 4, roundToInt(25 * scale), 16);
        down.setBounds(roundToInt(142 * scale), getHeight() - 20, roundToInt(25 * scale), 16);
    }
    void mouseDown(const MouseEvent &e) override {
        if (e.x >= signatureWidth())
            return;
        PopupMenu menu;
        for (int beats : {2, 3, 4, 5, 6, 7, 8, 9, 12}) {
            PopupMenu units;
            for (int unit : {2, 4, 8, 16})
                units.addItem(beats * 100 + unit, String(beats) + " / " + String(unit), true,
                              session.song() && session.song()->beatsPerBar == beats &&
                                  session.song()->beatUnit == unit);
            menu.addSubMenu(String(beats), units);
        }
        menu.showMenuAsync(PopupMenu::Options().withTargetComponent(this),
                           [safe = SafePointer<TempoControl>(this)](int result) {
                               if (safe && result && safe->session.song())
                                   safe->apply(safe->session.song()->bpm, result / 100,
                                               result % 100);
                           });
    }

  private:
    Session &session;
    std::function<void(String)> error;
    TextButton up{"+"}, down{String::fromUTF8("−")};
    Label bpm;
    bool updating = false;
    int signatureWidth() const { return roundToInt(81 * getWidth() / 171.f); }
    void change(int delta) {
        if (const auto *song = session.song())
            apply(jlimit(60., 300., song->bpm + delta), 0, 0);
    }
    void apply(double value, int beats, int unit) {
        try {
            if (const auto *song = session.song())
                session.configureTiming(value, beats ? beats : song->beatsPerBar,
                                        unit ? unit : song->beatUnit,
                                        song->timeSettings.value_or(jaras::ProjectTimeSettings{}));
        } catch (const std::exception &e) {
            if (error)
                error(String::fromUTF8(e.what()));
        }
        refresh();
    }
};
} // namespace catlive
