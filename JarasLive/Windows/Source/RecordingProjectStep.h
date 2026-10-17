#pragma once
#include "ModalSheet.h"
namespace catlive {
class RecordingProjectStep final : public Component {
  public:
    explicit RecordingProjectStep(std::function<void(int)> create) : completed(std::move(create)) {
        setComponentID("recordingProjectStep");
        for (auto *button : {&minus, &plus, &next, &cancel}) {
            addAndMakeVisible(*button); button->setWantsKeyboardFocus(false);
        }
        addAndMakeVisible(count);
        count.setComponentID("recordingProjectChannels");
        count.setInputRestrictions(3, "0123456789");
        count.setFont(theme::font(13)); count.setJustification(Justification::centred);
        count.setText("32");
        count.onTextChange = [this] { next.setEnabled(count.getText().getIntValue() >= 1 && count.getText().getIntValue() <= 128); };
        count.onReturnKey = [this] { submit(); };
        minus.onClick = [this] { adjust(-1); }; plus.onClick = [this] { adjust(1); };
        next.setComponentID("recordingProjectContinue");
        next.setColour(TextButton::buttonColourId, theme::green);
        next.setColour(TextButton::textColourOffId, Colours::black);
        next.onClick = [this] { submit(); };
        cancel.onClick = [this] { ModalSheet::dismiss(*this); };
    }
    void paint(Graphics &g) override {
        g.setColour(Colours::white); g.setFont(theme::mediumFont(12));
        g.drawText("Quantidade de canais", 20, 14, getWidth()-40, 25, Justification::centredLeft);
        g.setColour(theme::secondary); g.setFont(theme::font(11));
        g.drawFittedText(String::fromUTF8("Entradas mono sequenciais, todas as pistas armadas,\nsaída Master e monitoramento desligado."),
                        20, 85, getWidth()-40, 48, Justification::centredLeft, 2, 1.f);
    }
    void resized() override {
        minus.setBounds(20, 46, 28, 26); count.setBounds(54, 46, 70, 26); plus.setBounds(130, 46, 28, 26);
        cancel.setBounds(getWidth()-204, 145, 84, 28); next.setBounds(getWidth()-110, 145, 90, 28);
    }
  private:
    TextEditor count;
    TextButton minus{"-"}, plus{"+"}, next{"Continuar"}, cancel{"Cancelar"};
    std::function<void(int)> completed;
    void adjust(int delta) { count.setText(String(jlimit(1, 128, count.getText().getIntValue()+delta))); }
    void submit() {
        const int channels = count.getText().getIntValue();
        if (channels < 1 || channels > 128) return;
        auto callback = completed;
        ModalSheet::dismiss(*this);
        if (callback) callback(channels);
    }
};
}
