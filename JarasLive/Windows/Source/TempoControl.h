#pragma once
#include "Session.h"
#include "TempoEditing.h"
#include "Localization.h"
namespace catlive {
class TempoControl final : public Component {
  public:
    TempoControl(Session &owner, std::function<void(String)> report,
                 std::function<void()> tap, std::function<void(String)> map, std::function<void()> reset = {})
        : session(owner), error(std::move(report)), resetTap(std::move(reset)) {
        for (auto *b : {&up, &down}) {
            addAndMakeVisible(b);
            b->getProperties().set("plain", true);
            b->getProperties().set("fontSize", 15);
            b->setWantsKeyboardFocus(false);
        }
        up.onClick = [this] { change(1); };
        down.onClick = [this] { change(-1); };
        up.context = [map](Point<int>) { map("tempoUp"); };
        down.context = [map](Point<int>) { map("tempoDown"); };
        up.setTooltip("Aumentar BPM");
        down.setTooltip("Diminuir BPM");
        addAndMakeVisible(bpm);
        bpm.setComponentID("bpmReadout");
        bpm.getProperties().set("plain", true);
        bpm.getProperties().set("fontSize", 15);
        bpm.onClick = std::move(tap);
        bpm.context = [this](Point<int>) { editBPM(); };
        bpm.setTooltip("Tap tempo · Clique direito para editar BPM");
        addChildComponent(bpmInput);
        bpmInput.setComponentID("bpmValue");
        bpmInput.setName("BPM");
        bpmInput.setFont(theme::semiboldFont(14));
        bpmInput.setJustification(Justification::centred);
        bpmInput.setIndents(0, 0);
        bpmInput.setBorder(BorderSize<int>(1));
        bpmInput.setSelectAllWhenFocused(true);
        bpmInput.setInputRestrictions(8, "0123456789.,");
        bpmInput.setPopupMenuEnabled(false);
        bpmInput.onReturnKey = [this] { finishBPM(true); };
        bpmInput.onEscapeKey = [this] { closeBPM(); };
        bpmInput.onFocusLost = [this] { finishBPM(false); };
        for (auto *field : {&beats, &unit}) {
            addAndMakeVisible(field);
            field->setFont(theme::font(13));
            field->setJustification(Justification::centred);
            field->setIndents(0, 0);
            field->setBorder(BorderSize<int>(2));
            field->setInputRestrictions(2, "0123456789");
            field->setSelectAllWhenFocused(true);
            field->setPopupMenuEnabled(false);
            field->onReturnKey = [this, field] { commitMeter(); field->giveAwayKeyboardFocus(); };
            field->onEscapeKey = [this, field] { refreshMeter(); field->giveAwayKeyboardFocus(); };
            field->onFocusLost = [this, field] {
                auto &other = field == &beats ? unit : beats;
                if (!other.hasKeyboardFocus(false)) commitMeter();
            };
        }
        beats.setName("Beats per bar");
        unit.setName("Beat unit");
        refresh();
    }
    void retainTempoAfterMixerChange() {
        if(tempoRevision+1==session.revision)tempoRevision=session.revision;
    }
    void refresh() {
        const auto value = session.tempoBPM();
        if (bpmInput.isVisible() && !session.tempoInputAllowed()) closeBPM();
        bpm.setButtonText(String::formatted("%g", value));
        const auto *song = session.song();
        const auto *part = song ? tempoEditing::region(*song, session.transport()) : nullptr;
        const ID regionID = part ? part->id : ID{};
        if (tempoRevision != session.revision || tempoRegion != regionID) {
            tempoRevision = session.revision; tempoRegion = regionID;
            tempoNeedsRender = song && tempoEditing::needsRender(*song, part);
        }
        const auto colour = tempoNeedsRender ? theme::yellow : Colours::white;
        bpm.setColour(TextButton::textColourOffId, colour);
        bpm.setColour(TextButton::textColourOnId, colour);
        const bool meterAllowed = session.meterInputAllowed();
        beats.setReadOnly(!meterAllowed); unit.setReadOnly(!meterAllowed);
        if (!meterAllowed || (!beats.hasKeyboardFocus(false) && !unit.hasKeyboardFocus(false))) refreshMeter();
        const bool hasSong = song != nullptr;
        if (!shownSong || *shownSong != hasSong) { shownSong = hasSong; repaint(); }
    }
    void paint(Graphics &g) override {
        if (session.song()) {
            const float scale = getWidth() / 179.f;
            g.setFont(theme::font(13));
            g.setColour(Colours::white);
            g.drawText("/", roundToInt(27 * scale), 0, roundToInt(8 * scale), getHeight(),
                       Justification::centred);
        }
        g.setColour(theme::secondary);
        g.setFont(theme::font(8));
        g.drawText("BPM", bpm.getX(), bpm.getBottom() - 1, bpm.getWidth(),
                   9, Justification::centred);
    }
    void resized() override {
        constexpr int stepWidth = 28, stepHeight = 28;
        const float scale = getWidth() / 179.f;
        const int centerY = (getHeight() - 23) / 2;
        const int stepY = (getHeight() - stepHeight) / 2;
        beats.setBounds(roundToInt(1 * scale), centerY, roundToInt(24 * scale), 23);
        unit.setBounds(roundToInt(37 * scale), centerY, roundToInt(24 * scale), 23);
        down.setBounds(roundToInt(65 * scale), stepY, roundToInt(stepWidth * scale), stepHeight);
        bpm.setBounds(roundToInt(94 * scale), std::max(0, (getHeight() - 26) / 2), roundToInt(55 * scale), 18);
        bpmInput.setBounds(bpm.getBounds());
        up.setBounds(roundToInt(150 * scale), stepY, roundToInt(stepWidth * scale), stepHeight);
    }

  private:
    Session &session;
    std::function<void(String)> error;
    std::function<void()> resetTap;
    QuietButton up{"+"}, down{String::fromUTF8("−")}, bpm;
    TextEditor beats, unit, bpmInput;
    uint64 tempoRevision = std::numeric_limits<uint64>::max();
    ID tempoRegion;
    bool tempoNeedsRender = false;
    std::optional<bool> shownSong;
    void refreshMeter() {
        const auto [numerator, denominator] = session.transportMeter();
        beats.setText(String(numerator), false);
        unit.setText(String(denominator), false);
    }
    void commitMeter() {
        if (!session.meterInputAllowed()) { refreshMeter(); return; }
        const auto [activeBeats, activeUnit] = session.transportMeter();
        const int numerator = beats.getText().getIntValue(), denominator = unit.getText().getIntValue();
        const bool validUnit = denominator > 0 && denominator <= 64 && (denominator & (denominator - 1)) == 0;
        const int nextBeats = numerator >= 1 && numerator <= 32 ? numerator : activeBeats;
        const int nextUnit = validUnit ? denominator : activeUnit;
        if (nextBeats != activeBeats || nextUnit != activeUnit)
            apply(session.tempoBPM(), nextBeats, nextUnit);
        refreshMeter();
    }
    void editBPM() {
        if (!session.tempoInputAllowed() || bpmInput.isVisible()) return;
        bpmInput.setText(bpm.getButtonText(), false);
        bpm.setVisible(false);
        bpmInput.setVisible(true);
        bpmInput.grabKeyboardFocus();
        bpmInput.selectAll();
    }
    void closeBPM() {
        bpmInput.setVisible(false);
        bpm.setVisible(true);
    }
    void finishBPM(bool keepInvalidOpen) {
        if (!bpmInput.isVisible()) return;
        const auto text = bpmInput.getText().replaceCharacter(',', '.').toStdString();
        size_t consumed = 0;
        double value = 0;
        try { value = std::stod(text, &consumed); } catch (const std::exception &) {}
        if (!session.tempoInputAllowed() || consumed != text.size() || !std::isfinite(value) || value < 60 || value > 300) {
            if (keepInvalidOpen && error) error(localization::translate("Enter a BPM between 60 and 300."));
            else closeBPM();
            return;
        }
        closeBPM();
        apply(value, 0, 0);
    }

    void change(int delta) {
        if (const auto *song = session.song())
            apply(jlimit(60., 300., session.tempoBPM() + delta), 0, 0);
    }
    void apply(double value, int beats, int unit) {
        try {
            if (resetTap) resetTap();
            if (beats == 0 && unit == 0) session.setTempo(value);
            else if (const auto *song = session.song())
                session.setMeter(beats ? beats : song->beatsPerBar, unit ? unit : song->beatUnit);
        } catch (const std::exception &e) {
            if (error)
                error(String::fromUTF8(e.what()));
        }
        refresh();
    }
};
} // namespace catlive
