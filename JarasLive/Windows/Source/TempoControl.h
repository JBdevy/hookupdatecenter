#pragma once
#include "Session.h"
namespace catlive {
class TempoControl final : public Component {
  public:
    TempoControl(Session &owner, std::function<void(String)> report,
                 std::function<void()> tap, std::function<void(String)> map, std::function<void()> reset = {})
        : session(owner), error(std::move(report)), resetTap(std::move(reset)) {
        for (auto *b : {&up, &down}) {
            addAndMakeVisible(b);
            b->getProperties().set("plain", true);
            b->getProperties().set("fontSize", 10);
            b->setWantsKeyboardFocus(false);
        }
        up.onClick = [this] { change(1); };
        down.onClick = [this] { change(-1); };
        up.context = [map](Point<int>) { map("tempoUp"); };
        down.context = [map](Point<int>) { map("tempoDown"); };
        up.setTooltip("Aumentar BPM");
        down.setTooltip("Diminuir BPM");
        addAndMakeVisible(bpm);
        bpm.getProperties().set("plain", true);
        bpm.getProperties().set("fontSize", 15);
        bpm.onClick = std::move(tap);
        bpm.context = [this](Point<int>) { editBPM(); };
        bpm.setTooltip("Tap tempo · Clique direito para editar BPM");
        for (auto *field : {&beats, &unit}) {
            addAndMakeVisible(field);
            field->setFont(theme::font(13));
            field->setJustification(Justification::centred);
            field->setInputRestrictions(2, "0123456789");
            field->setSelectAllWhenFocused(true);
            field->setPopupMenuEnabled(false);
            field->onReturnKey = [this, field] { commitMeter(); field->giveAwayKeyboardFocus(); };
            field->onEscapeKey = [this, field] { refreshMeter(); field->giveAwayKeyboardFocus(); };
            field->onFocusLost = [this] { commitMeter(); };
        }
        beats.setName("Beats per bar");
        unit.setName("Beat unit");
        refresh();
    }
    void refresh() {
        const auto value = session.tempoBPM();
        bpm.setButtonText(String::formatted("%g", value));
        if (!beats.hasKeyboardFocus(false) && !unit.hasKeyboardFocus(false)) refreshMeter();
        repaint();
    }
    void paint(Graphics &g) override {
        g.setColour(Colour(0xff121212));
        g.fillRoundedRectangle(getLocalBounds().toFloat(), 4);
        g.setColour(theme::line);
        g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(.5f), 4, 1);
        if (const auto *song = session.song()) {
            const float scale = getWidth() / 171.f;
            g.setFont(theme::font(13));
            g.setColour(Colours::white);
            g.drawText("/", roundToInt(37 * scale), 0, roundToInt(8 * scale), getHeight(),
                       Justification::centred);
        }
        g.setColour(theme::secondary);
        g.setFont(theme::font(8));
        g.drawText("BPM", signatureWidth(), getHeight() - 14, roundToInt(58 * getWidth() / 171.f),
                   11, Justification::centred);
    }
    void resized() override {
        const float scale = getWidth() / 171.f;
        beats.setBounds(roundToInt(4 * scale), 8, roundToInt(30 * scale), getHeight() - 16);
        unit.setBounds(roundToInt(48 * scale), 8, roundToInt(30 * scale), getHeight() - 16);
        bpm.setBounds(signatureWidth(), 3, roundToInt(58 * scale), getHeight() - 16);
        up.setBounds(roundToInt(142 * scale), 4, roundToInt(25 * scale), 16);
        down.setBounds(roundToInt(142 * scale), getHeight() - 20, roundToInt(25 * scale), 16);
    }

  private:
    Session &session;
    std::function<void(String)> error;
    std::function<void()> resetTap;
    QuietButton up{"+"}, down{String::fromUTF8("−")}, bpm;
    TextEditor beats, unit;
    void refreshMeter() {
        const auto *song = session.song();
        beats.setText(String(song ? song->beatsPerBar : 4), false);
        unit.setText(String(song ? song->beatUnit : 4), false);
    }
    void commitMeter() {
        const auto *song = session.song();
        if (!song) { refreshMeter(); return; }
        const int numerator = beats.getText().getIntValue(), denominator = unit.getText().getIntValue();
        const bool validUnit = denominator > 0 && denominator <= 64 && (denominator & (denominator - 1)) == 0;
        const int nextBeats = numerator >= 1 && numerator <= 32 ? numerator : song->beatsPerBar;
        const int nextUnit = validUnit ? denominator : song->beatUnit;
        if (nextBeats != song->beatsPerBar || nextUnit != song->beatUnit)
            apply(session.tempoBPM(), nextBeats, nextUnit);
        refreshMeter();
    }
    void editBPM() {
        auto *dialog = new AlertWindow("BPM", "", MessageBoxIconType::NoIcon, this);
        dialog->addTextEditor("bpm", bpm.getButtonText(), "BPM");
        dialog->getTextEditor("bpm")->setPopupMenuEnabled(false);
        dialog->addButton("Aplicar", 1, KeyPress(KeyPress::returnKey));
        dialog->addButton("Cancelar", 0, KeyPress(KeyPress::escapeKey));
        dialog->enterModalState(true, ModalCallbackFunction::create(
            [safe = SafePointer<TempoControl>(this), dialog](int result) {
                if (!safe || result != 1) return;
                const auto value = dialog->getTextEditorContents("bpm").replaceCharacter(',', '.').getDoubleValue();
                if (std::isfinite(value) && value >= 60 && value <= 300) safe->apply(value, 0, 0);
                else if (safe->error) safe->error("Informe um BPM entre 60 e 300.");
            }), true);
    }
    int signatureWidth() const { return roundToInt(81 * getWidth() / 171.f); }
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
