#pragma once
#include "ModalSheet.h"
namespace catlive {
class ImportNoticePanel final : public Component {
  public:
    explicit ImportNoticePanel(StringArray warnings) : notes(std::move(warnings)) {
        addAndMakeVisible(viewport); viewport.setViewedComponent(&details, false);
        viewport.setScrollBarsShown(true, false); viewport.setScrollBarThickness(8);
        for (int i = 0; i < notes.size(); ++i) {
            auto number = std::make_unique<Label>(); number->setText(String(i + 1) + ".", dontSendNotification);
            number->setFont(theme::mediumFont(14)); number->setColour(Label::textColourId, theme::yellow);
            number->setJustificationType(Justification::topRight);
            auto label = std::make_unique<Label>(); label->setText(notes[i], dontSendNotification);
            label->setFont(theme::font(14)); label->setJustificationType(Justification::topLeft);
            label->setMinimumHorizontalScale(1); label->setBorderSize(BorderSize<int>(0));
            details.addAndMakeVisible(*number); details.addAndMakeVisible(*label);
            numbers.push_back(std::move(number)); labels.push_back(std::move(label));
        }
        addAndMakeVisible(ok); ok.setComponentID("import-notice-ok");
        ok.onClick = [this] { ModalSheet::dismiss(*this); };
        setComponentID("import-notice");
    }
    void paint(Graphics& g) override {
        g.fillAll(theme::panel);
        g.setColour(theme::secondary); g.setFont(theme::font(14));
        g.drawFittedText(String::fromUTF8("Projeto importado. Confira estes avisos antes de reproduzir."),
                        20, 6, getWidth() - 40, 36, Justification::centredLeft, 2);
        g.setColour(theme::background); g.fillRoundedRectangle(viewport.getBounds().toFloat(), 6);
        g.setColour(theme::secondary); g.setFont(theme::font(12));
        g.drawText(String::fromUTF8("Avisos da importação: ") + String(notes.size()),
                   20, getHeight() - 48, getWidth() - 140, 28, Justification::centredLeft);
    }
    void resized() override {
        viewport.setBounds(20, 48, getWidth() - 40, std::max(40, getHeight() - 114));
        const int width = std::max(100, viewport.getWidth() - 12);
        int y = 12;
        for (size_t i = 0; i < labels.size(); ++i) {
            AttributedString attributed; attributed.setText(notes[(int)i]); attributed.setFont(theme::font(14));
            TextLayout layout; layout.createLayout(attributed, (float)(width - 54));
            const int height = std::max(22, (int)std::ceil(layout.getHeight()) + 4);
            numbers[i]->setBounds(6, y, 28, height); labels[i]->setBounds(42, y, width - 54, height);
            y += height + 12;
        }
        details.setSize(width, std::max(viewport.getHeight(), y));
        ok.setBounds(getWidth() - 108, getHeight() - 48, 88, 30);
    }
    bool keyPressed(const KeyPress& key) override {
        if (key == KeyPress::returnKey) { ModalSheet::dismiss(*this); return true; }
        return false;
    }
    var diagnostics() const {
        auto result = object(); put(result, "count", notes.size());
        put(result, "width", getWidth()); put(result, "height", getHeight());
        put(result, "contentHeight", details.getHeight()); put(result, "viewportHeight", viewport.getHeight());
        put(result, "scrollY", viewport.getViewPositionY()); return result;
    }
  private:
    StringArray notes;
    Component details;
    Viewport viewport;
    std::vector<std::unique_ptr<Label>> labels, numbers;
    TextButton ok{"OK"};
};
}
