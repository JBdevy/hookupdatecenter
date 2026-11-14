#pragma once
#include "Common.h"
#include "Localization.h"
#include "ModalSheet.h"

namespace catlive {
class FullLyricsPanel final : public Component {
    TextEditor editor;
    Label song, instructions, warning;
    TextButton cancel{localization::translate("Cancel")}, create{localization::translate("Create items")};
    std::function<String(String)> apply;
public:
    FullLyricsPanel(String name, std::function<String(String)> save) : apply(std::move(save)) {
        for (auto *view : std::vector<Component *>{&song, &instructions, &editor, &warning, &cancel, &create}) addAndMakeVisible(view);
        song.setText(name, dontSendNotification); song.setFont(theme::font(16));
        instructions.setText(localization::translate("Separate each stanza with two blank lines. Items will fill the whole song equally."), dontSendNotification);
        instructions.setFont(theme::font(12)); instructions.setColour(Label::textColourId, theme::secondary);
        editor.setMultiLine(true, true); editor.setReturnKeyStartsNewLine(true); editor.setScrollbarsShown(true);
        editor.setFont(theme::font(15)); editor.setIndents(8, 8); editor.setName(localization::translate("Full lyrics"));
        warning.setFont(theme::font(12)); warning.setColour(Label::textColourId, Colours::orange);
        cancel.onClick = [this] { ModalSheet::dismiss(*this); };
        create.setColour(TextButton::buttonColourId, theme::green);
        create.onClick = [this] {
            const auto error = apply(editor.getText());
            if (error.isEmpty()) ModalSheet::dismiss(*this);
            else warning.setText(error, dontSendNotification);
        };
    }
    void resized() override {
        auto area = getLocalBounds().reduced(18);
        song.setBounds(area.removeFromTop(26)); instructions.setBounds(area.removeFromTop(42));
        auto buttons = area.removeFromBottom(30);
        cancel.setBounds(buttons.removeFromLeft(90)); create.setBounds(buttons.removeFromRight(130));
        warning.setBounds(area.removeFromBottom(36)); editor.setBounds(area.reduced(0, 6));
    }
    void paint(Graphics &g) override { g.fillAll(theme::panel); }
};
}
