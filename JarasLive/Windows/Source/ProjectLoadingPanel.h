#pragma once
#include "Common.h"
namespace catlive {
class ProjectLoadingPanel final : public Component {
    Label title, stage;
    double amount = -1;
    ProgressBar progress{amount};
public:
    explicit ProjectLoadingPanel(const String &name) {
        setComponentID("projectLoading");
        title.setText(name, dontSendNotification); title.setFont(theme::font(13, true));
        stage.setFont(theme::font(12));
        for (auto *label : {&title, &stage}) { label->setJustificationType(Justification::centred); addAndMakeVisible(*label); }
        progress.setPercentageDisplay(false); addAndMakeVisible(progress);
        update(String::fromUTF8("Carregando projeto…"), -1);
    }
    void update(const String &text, double value) { stage.setText(text, dontSendNotification); amount = value; repaint(); }
    String status() const { return stage.getText(); }
    void resized() override {
        title.setBounds(20, 12, getWidth()-40, 24);
        stage.setBounds(20, 46, getWidth()-40, 24);
        progress.setBounds(32, 84, getWidth()-64, 6);
    }
};
}
