#pragma once
#include "StageState.h"

namespace catlive {
class StagePreviewPanel final : public Component {
  public:
    explicit StagePreviewPanel(StageState &value) : state(value) {
        for (int i = 0; i < 6; ++i) {
            auto &button = pages[i];
            button.setButtonText("Blocos " + String(i * 4 + 1) + String::fromUTF8("–") + String(i * 4 + 4));
            button.setColour(TextButton::buttonColourId, Colours::transparentBlack);
            button.setColour(TextButton::buttonOnColourId, Colour(0xff606060));
            button.setColour(TextButton::textColourOnId, Colours::white);
            button.getProperties().set("flat", true);
            button.getProperties().set("fontSize", 12.f);
            button.onClick = [this, i] { state.previewPage = i; refresh(); };
            addAndMakeVisible(button);
        }
        refresh();
        setSize(660, 88);
    }
    void paint(Graphics &g) override {
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(14));
        g.drawText("Preview", 16, 12, getWidth() - 32, 22, Justification::centredLeft);
        g.setColour(Colour(0xff303030));
        g.fillRoundedRectangle(16, 44, getWidth() - 32.f, 28, 5);
    }
    void resized() override {
        const int width = getWidth() - 36;
        for (int i = 0; i < 6; ++i) {
            const int left = 18 + width * i / 6;
            const int right = 18 + width * (i + 1) / 6;
            pages[i].setBounds(left, 46, right - left, 24);
        }
    }
  private:
    StageState &state;
    QuietButton pages[6];
    void refresh() {
        for (int i = 0; i < 6; ++i) pages[i].setToggleState(state.previewPage == i, dontSendNotification);
    }
};
} // namespace catlive
