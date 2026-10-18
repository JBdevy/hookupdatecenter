#pragma once
#include "StageState.h"
#include "ModalSheet.h"

namespace catlive {
// Matches TeleprompterTimerConfiguration: one selected time field, a numeric
// keypad, and the same independent countdown shared by the transport and TP.
class StageTimerSettings final : public Component, private Timer {
  public:
    explicit StageTimerSettings(StageState &value) : state(value) {
        for (int i = 0; i < 3; ++i) {
            fields[i].setName(StringArray{"Horas", "Minutos", "Segundos"}[i]);
            fields[i].onClick = [this, i] { field = i; caret = 0; refresh(); };
            addAndMakeVisible(fields[i]);
        }
        const StringArray titles{"1", "2", "3", "4", "5", "6", "7", "8", "9", "Limpar", "0", String::fromUTF8("⌫")};
        for (int i = 0; i < 12; ++i) {
            keys[i].setButtonText(titles[i]);
            keys[i].setName(titles[i]);
            keys[i].setColour(TextButton::buttonColourId, Colour(0xff505050));
            keys[i].getProperties().set("flat", true);
            keys[i].getProperties().set("cornerRadius", 6.f);
            keys[i].onClick = [this, i] { edit(i); };
            addAndMakeVisible(keys[i]);
        }
        start.onClick = [this] {
            if (!state.running) { state.start(); refresh(); return; }
            const auto runStarted = state.started;
            const SafePointer<StageTimerSettings> safe(this);
            AlertWindow::showOkCancelBox(MessageBoxIconType::QuestionIcon,
                String::fromUTF8("Parar o cronômetro?"),
                String::fromUTF8("O cronômetro será parado e a contagem atual será zerada."),
                "Parar", "Cancelar", this, ModalCallbackFunction::create([safe, runStarted](int result) {
                    if (safe && result && safe->state.running && safe->state.started == runStarted) {
                        safe->state.reset(); safe->refresh();
                    }
                }));
        };
        automatic.onClick = [this] { state.autoStart = !state.autoStart; state.saveTimer(); refresh(); };
        automatic.setTooltip(String::fromUTF8("Iniciar o cronômetro automaticamente quando uma música começar"));
        close.onClick = [this] { ModalSheet::dismiss(*this); };
        for (auto *button : {&start, &automatic, &close}) {
            button->getProperties().set("flat", true);
            button->getProperties().set("cornerRadius", 6.f);
            addAndMakeVisible(button);
        }
        close.setColour(TextButton::buttonColourId, Colour(0xff505050));
        refresh();
        startTimerHz(4);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        const auto display = getLocalBounds().reduced(16).removeFromTop(48).toFloat();
        g.setColour(theme::display); g.fillRoundedRectangle(display, 6);
        g.setColour(theme::green); g.drawRoundedRectangle(display.reduced(.5f), 6, 1);
        const bool expired = state.running && state.seconds() < 0;
        g.setColour(expired ? Colours::red.withAlpha((int)(StageState::now() * 2) % 2 ? .25f : 1.f) : theme::green);
        g.setFont(theme::semiboldFont(30));
        g.drawText(state.timeText(), display, Justification::centred);
    }
    void resized() override {
        const int width = getWidth() - 32;
        for (int i = 0; i < 3; ++i) {
            const int x = 16 + i * (width + 8) / 3;
            fields[i].setBounds(x, 76, (width - 16) / 3, 60);
        }
        const int keyHeight = std::max(26, (getHeight() - 197 - 15) / 4);
        for (int i = 0; i < 12; ++i) {
            const int x = 16 + (i % 3) * (width + 5) / 3;
            keys[i].setBounds(x, 144 + (i / 3) * (keyHeight + 5), (width - 10) / 3, keyHeight);
        }
        const int y = getHeight() - 40;
        start.setBounds(16, y, 62, 24);
        automatic.setBounds(88, y, 88, 24);
        close.setBounds(getWidth() - 82, y, 66, 24);
    }
  private:
    class Field final : public Button {
      public:
        Field() : Button({}) {}
        String digits;
        bool selected = false;
        void paintButton(Graphics &g, bool, bool) override {
            const auto bounds = getLocalBounds().toFloat().reduced(.5f);
            g.setColour(theme::display); g.fillRoundedRectangle(bounds, 6);
            g.setColour(selected ? theme::yellow : theme::line); g.drawRoundedRectangle(bounds, 6, 1);
            g.setColour(Colours::white.withAlpha(isEnabled() ? 1.f : .5f));
            g.setFont(theme::semiboldFont(11));
            g.drawText(localization::translate(getName()), 0, 6, getWidth(), 16, Justification::centred);
            g.setFont(theme::semiboldFont(24));
            g.drawText(digits, 0, 24, getWidth(), 30, Justification::centred);
        }
    };
    StageState &state;
    Field fields[3];
    QuietButton keys[12];
    QuietButton start{"Iniciar"}, automatic{"INIT AUTO"}, close{"Fechar"};
    int field = 0, caret = 0;
    void edit(int key) {
        if (state.running) return;
        const int divisors[]{3600, 60, 1};
        int values[]{state.target / 3600, state.target / 60 % 60, state.target % 60};
        auto digits = String(values[field]).paddedLeft('0', 2);
        if (key == 9) { digits = "00"; caret = 0; }
        else if (key == 11) {
            if (caret > 0) { --caret; digits = digits.replaceSection(caret, 1, "0"); }
        } else {
            const auto digit = key == 10 ? String("0") : String(key + 1);
            if (caret == 2) digits = digits.substring(1) + digit;
            else { digits = digits.replaceSection(caret, 1, digit); ++caret; }
        }
        values[field] = jlimit(0, field == 0 ? 99 : 59, digits.getIntValue());
        state.target = values[0] * divisors[0] + values[1] * divisors[1] + values[2];
        state.saveTimer();
        refresh();
    }
    void refresh() {
        const int values[]{state.target / 3600, state.target / 60 % 60, state.target % 60};
        for (int i = 0; i < 3; ++i) {
            fields[i].digits = String(values[i]).paddedLeft('0', 2);
            fields[i].selected = field == i;
            fields[i].setEnabled(!state.running);
            fields[i].repaint();
        }
        for (auto &key : keys) key.setEnabled(!state.running);
        start.setButtonText(state.running ? "Parar" : "Iniciar");
        start.setColour(TextButton::buttonColourId, state.running ? Colours::red : theme::green);
        start.setColour(TextButton::textColourOffId, state.running ? Colours::white : Colours::black);
        automatic.setColour(TextButton::textColourOffId, state.autoStart ? theme::green : theme::secondary);
        repaint();
    }
    void timerCallback() override { refresh(); }
};
} // namespace catlive
