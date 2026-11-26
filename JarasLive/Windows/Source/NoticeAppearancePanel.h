#pragma once
#include "Localization.h"
#include "StageState.h"
namespace catlive {
class NoticeAppearancePanel final : public Component {
  public:
    explicit NoticeAppearancePanel(StageState &value) : state(value) {
        auto settings = state.preferences.value("jaras.notices.appearance", object());
        const char *keys[]{"window1", "window2", "emojiEnabled"};
        const StringArray titles{"Exibir no TP-1", "Exibir no TP-2", "Exibir emoji"};
        for (int i = 0; i < 3; ++i) {
            addAndMakeVisible(toggles[i]);
            toggles[i].setButtonText(titles[i]);
            toggles[i].setToggleState(flag(settings, keys[i], i != 2), dontSendNotification);
            toggles[i].onClick = [this, i, key = String(keys[i])] {
                change(key, toggles[i].getToggleState());
            };
        }
        addAndMakeVisible(font);
        StringArray families{"Arial",    "Georgia", "Impact",       "Menlo",
                             "Segoe UI", "Tahoma",  "Trebuchet MS", "Verdana"};
        const auto selected = str(settings, "font", "Arial");
        families.addIfNotAlreadyThere(selected);
        families.sort(true);
        font.addItemList(families, 1);
        font.setSelectedId(families.indexOf(selected) + 1, dontSendNotification);
        font.onChange = [this] { change("font", font.getText()); };
        addAndMakeVisible(scale);
        scale.setRange(50, 100, 1);
        scale.setSliderStyle(Slider::LinearHorizontal);
        scale.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
        scale.getProperties().set("stageScale", true);
        scale.setValue(num(settings, "scale", 100), dontSendNotification);
        scale.onValueChange = [this] {
            change("scale", scale.getValue());
            repaint();
        };
        const char *colourKeys[]{"text", "background", "flash"};
        const uint32 defaults[]{0xffffff, 0, 0xffdc52};
        for (int i = 0; i < 3; ++i) {
            addAndMakeVisible(wells[i]);
            wells[i].getProperties().set("colourWell", true);
            wells[i].setColour(TextButton::buttonColourId,
                               StageState::colour(settings, colourKeys[i], defaults[i]));
            wells[i].onClick = [this, i, key = String(colourKeys[i])] {
                const auto safe = SafePointer<NoticeAppearancePanel>(this);
                auto picker = std::make_unique<Picker>(
                    wells[i].findColour(TextButton::buttonColourId),
                    [safe, i, key](Colour colour) {
                        if (safe) {
                            safe->change(key, (int)(colour.getARGB() & 0xffffffu));
                            safe->wells[i].setColour(TextButton::buttonColourId, colour);
                        }
                    });
                CallOutBox::launchAsynchronously(std::move(picker), wells[i].getScreenBounds(),
                                                 nullptr);
            };
        }
        addAndMakeVisible(emoji);
        emoji.setText(str(settings, "emoji", String::fromUTF8("⚠️")), false);
        emoji.setFont(Font(FontOptions("Segoe UI Emoji", 14, Font::plain).withPointHeight(14)));
        emoji.setInputRestrictions(8);
        emoji.onTextChange = [this] { change("emoji", emoji.getText()); };
        localization::panel(*this);
    }
    void paint(Graphics &g) override {
        g.setColour(Colours::white);
        g.setFont(theme::font(13));
        g.drawText("Font", 16, 74, 36, 24, Justification::centredLeft);
        g.drawText(String::fromUTF8("Escala da letra: ") + String((int)scale.getValue()) + "%", 16,
                   110, getWidth() - 32, 24, Justification::centredLeft);
        const StringArray titles{"Cor da letra", "Cor de fundo", "Cor do pisca"};
        for (int i = 0; i < 3; ++i)
            g.drawText(titles[i], 16, 170 + i * 36, 90, 26, Justification::centredLeft);
    }
    void resized() override {
        toggles[0].setBounds(16, 16, getWidth() - 32, 24);
        toggles[1].setBounds(16, 44, getWidth() - 32, 24);
        font.setBounds(52, 74, 134, 24);
        scale.setBounds(16, 138, getWidth() - 32, 26);
        for (int i = 0; i < 3; ++i)
            wells[i].setBounds(104, 172 + i * 36, 46, 22);
        toggles[2].setBounds(16, 276, getWidth() - 32, 24);
        emoji.setBounds(16, 308, getWidth() - 32, 24);
    }

  private:
    StageState &state;
    ToggleButton toggles[3];
    ComboBox font;
    ParameterSlider scale;
    TextButton wells[3];
    TextEditor emoji;
    void change(const String &key, var value) {
        auto settings = state.preferences.value("jaras.notices.appearance", object()).clone();
        put(settings, Identifier(key), value);
        state.preferences.set("jaras.notices.appearance", settings);
    }
    class Picker final : public Component {
      public:
        Picker(Colour colour, std::function<void(Colour)> commit) {
            addAndMakeVisible(selector);
            addAndMakeVisible(apply);
            selector.setCurrentColour(colour);
            apply.onClick = [this, commit] {
                commit(selector.getCurrentColour());
                if (auto *box = findParentComponentOfClass<CallOutBox>())
                    box->dismiss();
            };
            setSize(290, 330);
        }
        void resized() override {
            selector.setBounds(0, 0, getWidth(), getHeight() - 40);
            apply.setBounds(getWidth() - 94, getHeight() - 32, 84, 26);
        }

      private:
        ColourSelector selector;
        TextButton apply{localization::translate("Aplicar")};
    };
};
} // namespace catlive
