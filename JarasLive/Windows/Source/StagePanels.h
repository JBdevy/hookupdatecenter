#pragma once
#include "Localization.h"
#include "StageState.h"
#include "ModalSheet.h"
#include "NoticeAppearancePanel.h"
namespace catlive {
class NoticePanel final : public Component, private Timer {
  public:
    explicit NoticePanel(StageState &s) : state(s) {
        for (auto *b : {&send, &withdraw, &pin, &pinStopped, &save, &image, &removeImage})
            addAndMakeVisible(b);
        for (auto *b : {&withdraw, &pin, &pinStopped, &save, &image, &removeImage}) {
            b->getProperties().set("flat", true);
            b->setColour(TextButton::buttonColourId, Colour(0xff505050));
        }
        send.getProperties().set("flat", true);
        send.setColour(TextButton::buttonColourId, theme::green);
        send.setColour(TextButton::textColourOffId, Colours::black);
        send.onClick = [this] {
            state.sendNotice(editor.getText(), slot < 0 ? Image() : slotImage());
        };
        send.setTooltip("Enviar (Ctrl+Enter)");
        editor.submit = send.onClick;
        withdraw.onClick = [this] { state.clearNotice(); };
        pin.onClick = [this] { state.togglePin(); };
        pinStopped.onClick = [this] {
            state.setPinWhenStopped(!state.pinWhenStopped, editor.getText(), slot < 0 ? Image() : slotImage());
            timerCallback();
        };
        pinStopped.getProperties().set("fontSize", 12.f);
        pinStopped.setColour(TextButton::buttonOnColourId, theme::green);
        pinStopped.setColour(TextButton::textColourOnId, Colours::black);
        addAndMakeVisible(editor);
        editor.setMultiLine(true);
        editor.setReturnKeyStartsNewLine(true);
        editor.setFont(theme::font(18));
        editor.setColour(TextEditor::backgroundColourId, Colour(0xff101010));
        editor.setColour(TextEditor::textColourId, Colours::white);
        editor.setBorder(BorderSize<int>(8));
        editor.setInputRestrictions(500);
        addAndMakeVisible(remaining);
        addAndMakeVisible(count);
        for (int i = 0; i < 4; ++i) {
            auto *b = slots.add(new TextButton(i == 0 ? "Global" : "Recado " + String(i)));
            addAndMakeVisible(b);
            b->getProperties().set("flat", true);
            b->getProperties().set("fontSize", 13.f);
            b->setColour(TextButton::buttonColourId, Colour(0xff333333));
            b->setColour(TextButton::buttonOnColourId, Colour(0xff64b64a));
            b->setColour(TextButton::textColourOnId, Colours::white);
            b->onClick = [this, i] { select(i - 1); };
        }
        save.onClick = [this] {
            if (slot >= 0) {
                auto templates = list(state.preferences.value("jaras.notices.templates"));
                while (templates.size() < 3)
                    templates.add("");
                templates.set(slot, editor.getText());
                state.preferences.set("jaras.notices.templates", templates);
            }
        };
        image.onClick = [this] { chooseImage(); };
        removeImage.onClick = [this] {
            if (slot >= 0)
                state.preferences.set("jaras.notices.image." + String(slot), {});
        };
        select(-1);
        startTimerHz(4);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white);
        g.setFont(theme::font(13));
        g.drawText(localization::translate("Recado"), 16, 92, 76, 26, Justification::centredRight);
    }
    bool keyPressed(const KeyPress &key) override {
        if (retryEditorShortcut(key))
            return true;
        if ((key.getKeyCode() == KeyPress::returnKey || key.getKeyCode() == 10) &&
            key.getModifiers().isCtrlDown()) {
            if (send.isEnabled())
                send.onClick();
            return true;
        }
        return false;
    }
    void resized() override {
        send.setBounds(16, 16, 88, 30);
        withdraw.setBounds(112, 16, 72, 30);
        pin.setBounds(192, 16, 62, 30);
        pinStopped.setBounds(262, 16, std::max(120,getWidth()-342), 30);
        remaining.setBounds(getWidth() - 72, 16, 56, 30);
        for (int i = 0; i < 4; ++i)
            slots[i]->setBounds(100 + i * ((getWidth() - 116) / 4), 92, (getWidth() - 116) / 4, 26);
        editor.setBounds(16, 130, getWidth() - 32, getHeight() - 174);
        count.setBounds(16, getHeight() - 36, 86, 26);
        save.setBounds(getWidth() - 328, getHeight() - 36, 70, 26);
        image.setBounds(getWidth() - 250, getHeight() - 36, 112, 26);
        removeImage.setBounds(getWidth() - 130, getHeight() - 36, 114, 26);
    }

  private:
    StageState &state;
    int slot = -1;
    String global;
    String cachedImageData;
    Image cachedImage;
    struct NoticeEditor final : TextEditor {
        std::function<void()> submit;
        bool keyPressed(const KeyPress &key) override {
            if (key.getModifiers().isCtrlDown() &&
                (key.getKeyCode() == KeyPress::returnKey || key.getKeyCode() == 10)) {
                if (submit)
                    submit();
                return true;
            }
            return TextEditor::keyPressed(key);
        }
    } editor;
    TextButton send{localization::translate("Enviar")}, withdraw{localization::translate("Retirar")}, pin{localization::translate("Fixar")}, save{localization::translate("Salvar")},
        pinStopped{localization::translate("Pin while transport is stopped")}, image{"Add imagem"}, removeImage{"Remover imagem"};
    OwnedArray<TextButton> slots;
    Label remaining, count;
    std::unique_ptr<FileChooser> chooser;
    Image slotImage() {
        const auto encoded =
            state.preferences.value("jaras.notices.image." + String(slot)).toString();
        if (encoded == cachedImageData)
            return cachedImage;
        cachedImageData = encoded;
        cachedImage = {};
        MemoryBlock data;
        if (data.fromBase64Encoding(encoded))
            cachedImage = ImageFileFormat::loadFrom(data.getData(), data.getSize());
        return cachedImage;
    }
    void select(int index) {
        if (slot < 0)
            global = editor.getText();
        slot = index;
        auto templates = list(state.preferences.value("jaras.notices.templates"));
        editor.setText(slot < 0                  ? global
                       : slot < templates.size() ? templates[slot].toString()
                                                 : String());
        for (int i = 0; i < slots.size(); ++i)
            slots[i]->setToggleState(i == slot + 1, dontSendNotification);
        for (auto *b : {&save, &image, &removeImage})
            b->setVisible(slot >= 0);
        localization::panel(*this);
    }
    void chooseImage() {
        if (slot < 0)
            return;
        chooser = std::make_unique<FileChooser>(localization::translate("Imagem"), File(), "*.png;*.jpg;*.jpeg;*.bmp", true);
        chooser->launchAsync(
            FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles,
            [safe = SafePointer<NoticePanel>(this), index = slot](const FileChooser &fc) {
                if (!safe || !fc.getResult().existsAsFile())
                    return;
                auto image = ImageFileFormat::loadFrom(fc.getResult());
                if (!image.isValid())
                    return;
                const double scale =
                    std::min(1., 1920. / std::max(image.getWidth(), image.getHeight()));
                image = image.rescaled((int)(image.getWidth() * scale),
                                       (int)(image.getHeight() * scale));
                MemoryOutputStream out;
                JPEGImageFormat format;
                format.setQuality(.85f);
                format.writeImageToStream(image, out);
                safe->state.preferences.set("jaras.notices.image." + String(index),
                                            out.getMemoryBlock().toBase64Encoding());
            });
    }
    void timerCallback() override {
        remaining.setText(String((int)std::ceil(state.remaining())) + "s", dontSendNotification);
        count.setText(String(editor.getText().length()) + " / 500", dontSendNotification);
        withdraw.setEnabled(state.noticeActive());
        pin.setToggleState(state.pinned, dontSendNotification);
        pinStopped.setToggleState(state.pinWhenStopped, dontSendNotification);
        send.setEnabled(editor.getText().trim().isNotEmpty() || slot >= 0 && slotImage().isValid());
        removeImage.setVisible(slot >= 0 && slotImage().isValid());
    }
};
class StageConfigPanel final : public Component {
  public:
    StageConfigPanel(StageState &s, int target, std::function<void()> timerAction)
        : state(s), index(target), configureTimer(std::move(timerAction)) {
        for (int i = 0; i < 3; ++i) {
            auto *b =
                tabs.add(new TextButton(i == 2 ? "Recados" : "Teleprompter " + String(i + 1)));
            addAndMakeVisible(b);
            b->getProperties().set("flat", true);
            b->getProperties().set("fontSize", 13.f);
            b->setColour(TextButton::buttonColourId, Colour(0xff333333));
            b->setColour(TextButton::buttonOnColourId, Colour(0xff64b64a));
            b->setColour(TextButton::textColourOnId, Colours::white);
            b->onClick = [this, i] {
                index = i + 1;
                build();
            };
        }
        for (auto *b : {&night, &day, &timer, &close})
            addAndMakeVisible(b);
        for (auto *b : {&night, &day}) {
            b->getProperties().set("flat", true);
            b->getProperties().set("fontSize", 13.f);
            b->setColour(TextButton::buttonColourId, Colour(0xff333333));
            b->setColour(TextButton::buttonOnColourId, Colour(0xff64b64a));
            b->setColour(TextButton::textColourOnId, Colours::white);
        }
        for (auto *b : {&timer, &close}) {
            b->getProperties().set("flat", true);
            b->setColour(TextButton::buttonColourId, Colour(0xff505050));
        }
        night.onClick = [this] {
            state.selectPreset(index, "night");
            build();
        };
        day.onClick = [this] {
            state.selectPreset(index, "day");
            build();
        };
        timer.onClick = configureTimer;
        close.onClick = [this] {
            if (findParentComponentOfClass<ModalSheet>())
                ModalSheet::dismiss(*this);
            else if (auto *window = findParentComponentOfClass<DocumentWindow>())
                window->setVisible(false);
        };
        addAndMakeVisible(headerClose);
        headerClose.getProperties().set("plain", true);
        headerClose.getProperties().set("icon", "close");
        headerClose.onClick = close.onClick;
        addAndMakeVisible(viewport);
        viewport.setViewedComponent(&content, false);
        viewport.setScrollBarsShown(true, false);
        build();
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(14));
        g.drawText(localization::translate(index == 3 ? "Messages" : "Teleprompter settings"), 16,
                   64, getWidth() - 32, 30, Justification::centredLeft);
        g.setFont(theme::font(13));
        g.drawText("Teleprompter", getWidth() / 2 - 222, 12, 88, 24, Justification::centredRight);
        if (index != 3)
            g.drawText("Preset", getWidth() / 2 - 98, 106, 50, 24, Justification::centredRight);
    }
    void resized() override {
        for (int i = 0; i < tabs.size(); ++i)
            tabs[i]->setBounds(getWidth() / 2 - 130 + i * 116, 12, 116, 24);
        headerClose.setBounds(getWidth() - 50, 60, 36, 36);
        night.setBounds(getWidth() / 2 - 40, 106, 62, 24);
        day.setBounds(getWidth() / 2 + 22, 106, 62, 24);
        const int top = index == 3 ? 110 : 142;
        viewport.setBounds(16, top, getWidth() - 32, getHeight() - top - 48);
        content.setSize(viewport.getWidth() - 10, contentHeight);
        if (noticeSettings)
            noticeSettings->setBounds(0, 0, content.getWidth(), contentHeight);
        for (int i = 0; i < cards.size(); ++i) {
            const auto info = positions[(size_t)i];
            const int width = (content.getWidth() - 24) / 2;
            cards[i]->setBounds(8 + info.x * (width + 8), info.y, width, info.h);
        }
        for (int i = 0; i < headings.size(); ++i)
            headings[i]->setBounds(10, headingY[(size_t)i], content.getWidth() - 20, 24);
        timer.setBounds(16, getHeight() - 38, 220, 26);
        close.setBounds(getWidth() - 82, getHeight() - 38, 66, 26);
    }

  private:
    StageState &state;
    int index = 1, contentHeight = 0;
    std::function<void()> configureTimer;
    OwnedArray<TextButton> tabs;
    TextButton night{localization::translate("NOITE")}, day{localization::translate("DIA")}, timer{localization::translate(String::fromUTF8("Configurações do cronômetro"))},
        close{"Fechar"}, headerClose{"Fechar"};
    Viewport viewport;
    class SectionContent final : public Component {
      public:
        std::vector<std::pair<int, int>> groups;
        void paint(Graphics &g) override {
            g.setColour(theme::background);
            for (const auto &group : groups)
                g.fillRoundedRectangle(0, (float)group.first, (float)getWidth(),
                                       (float)group.second, 6);
        }
    } content;
    std::unique_ptr<NoticeAppearancePanel> noticeSettings;
    OwnedArray<Component> cards;
    OwnedArray<Label> headings;
    std::vector<int> headingY;
    struct Position {
        int x, y, h;
    };
    std::vector<Position> positions;
    var current() const {
        return index == 3 ? state.preferences.value("jaras.notices.appearance", object())
                          : state.settings(index);
    }
    void change(String key, var value) {
        if (index != 3) {
            state.set(index, key, value);
            return;
        }
        auto p = current().clone();
        put(p, Identifier(key), value);
        state.preferences.set("jaras.notices.appearance", p);
    }
    class Card final : public Component {
      public:
        Card(StageConfigPanel &p, var definition)
            : parent(p), field(std::move(definition)), key(str(field, "id")),
              kind(str(field, "kind")) {
            addAndMakeVisible(label);
            label.setText(localization::translate(str(field, "title")), dontSendNotification);
            label.setFont(theme::font(13));
            const auto settings = parent.current();
            if (kind == "color") {
                addAndMakeVisible(swatch);
                swatch.getProperties().set("colourWell", true);
                swatch.setColour(
                    TextButton::buttonColourId,
                    StageState::colour(settings, key, (uint32)num(field, "default", 0xffffff)));
                swatch.onClick = [this] {
                    const auto safe = Component::SafePointer<Card>(this);
                    auto selector = std::make_unique<Picker>(
                        swatch.findColour(TextButton::buttonColourId), [safe](Colour c) {
                            if (safe) {
                                safe->parent.change(safe->key, (int)(c.getARGB() & 0xffffffu));
                                safe->swatch.setColour(TextButton::buttonColourId, c);
                            }
                        });
                    CallOutBox::launchAsynchronously(std::move(selector), swatch.getScreenBounds(),
                                                     nullptr);
                };
            } else if (kind == "range") {
                addAndMakeVisible(slider);
                slider.setRange(num(field, "min", 25), num(field, "max", 200), 5);
                slider.setSliderStyle(Slider::LinearHorizontal);
                slider.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
                slider.getProperties().set("stageScale", true);
                slider.setTextValueSuffix("%");
                slider.setValue(num(settings, Identifier(key), num(field, "default", 100)),
                                dontSendNotification);
                slider.onValueChange = [this] {
                    parent.change(key, slider.getValue());
                    repaint();
                };
            } else if (kind == "toggle") {
                addAndMakeVisible(toggle);
                toggle.setToggleState(flag(settings, Identifier(key), flag(field, "default")),
                                      dontSendNotification);
                toggle.onClick = [this] { parent.change(key, toggle.getToggleState()); };
            } else {
                addAndMakeVisible(choice);
                const auto selected = str(settings, Identifier(key), str(field, "default"));
                int n = 1;
                for (const auto &option : list(get(field, "options"))) {
                    choice.addItem(localization::translate(str(option, "label")), n);
                    if (selected == str(option, "value"))
                        choice.setSelectedId(n, dontSendNotification);
                    ++n;
                }
                choice.onChange = [this] {
                    auto options = list(get(field, "options"));
                    if (choice.getSelectedId() > 0)
                        parent.change(key, str(options[choice.getSelectedId() - 1], "value"));
                };
            }
        }
        void paint(Graphics &g) override {
            g.setColour(theme::display);
            g.fillRoundedRectangle(getLocalBounds().toFloat(), 6);
            g.setColour(theme::line);
            g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(.5f), 6, 1);
            if (kind == "range") {
                g.setColour(Colours::white);
                g.setFont(theme::font(13));
                g.drawText(String((int)slider.getValue()) + "%", getWidth() - 68, 6, 58, 24,
                           Justification::centredRight);
            }
        }
        void resized() override {
            label.setBounds(8, 6,
                            getWidth() - (kind == "color" || kind == "range" ? 72
                                          : kind == "toggle"                 ? 44
                                                                             : 16),
                            kind == "range" || kind == "choice" ? 24 : getHeight() - 12);
            swatch.setBounds(getWidth() - 54, 15, 44, 22);
            slider.setBounds(8, 34, getWidth() - 16, 28);
            toggle.setBounds(getWidth() - 36, 10, 30, 28);
            choice.setBounds(10, 36, getWidth() - 20, 26);
        }

      private:
        class Picker final : public Component {
          public:
            Picker(Colour c, std::function<void(Colour)> f) : commit(std::move(f)) {
                addAndMakeVisible(selector);
                addAndMakeVisible(apply);
                selector.setCurrentColour(c);
                apply.onClick = [this] {
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
            ColourSelector selector;
            TextButton apply{localization::translate("Aplicar")};
            std::function<void(Colour)> commit;
        };
        StageConfigPanel &parent;
        var field;
        String key, kind;
        Label label;
        TextButton swatch;
        ParameterSlider slider;
        ToggleButton toggle;
        ComboBox choice;
    };
    void build() {
        cards.clear();
        noticeSettings.reset();
        content.groups.clear();
        headings.clear();
        headingY.clear();
        positions.clear();
        for (int i = 0; i < tabs.size(); ++i)
            tabs[i]->setToggleState(index == i + 1, dontSendNotification);
        night.setVisible(index != 3);
        day.setVisible(index != 3);
        night.setToggleState(state.preset(index) == "night", dontSendNotification);
        day.setToggleState(state.preset(index) == "day", dontSendNotification);
        auto fields = list(JSON::parse(
            String::fromUTF8(BinaryData::StageFields_json, BinaryData::StageFields_jsonSize)));
        if (index == 3) {
            noticeSettings = std::make_unique<NoticeAppearancePanel>(state);
            content.addAndMakeVisible(*noticeSettings);
            contentHeight = 400;
            viewport.setViewPosition(0, 0);
            resized();
            repaint();
            return;
        }
        int y = 0;
        for (auto type : {"color", "range", "choice", "toggle"}) {
            const int groupStart = y;
            const String group = String(type) == "color"    ? "Colors"
                                 : String(type) == "range"  ? "Scales"
                                 : String(type) == "choice" ? "Fonts and positions"
                                                            : "Display";
            auto *heading = headings.add(new Label());
            content.addAndMakeVisible(heading);
            heading->setText(localization::translate(group), dontSendNotification);
            heading->setFont(theme::semiboldFont(12));
            heading->setColour(Label::textColourId, theme::green);
            headingY.push_back(y + 5);
            y += 35;
            int n = 0;
            const int height = String(type) == "color" || String(type) == "toggle" ? 48 : 70;
            for (auto field : fields)
                if (str(field, "kind") == type) {
                    auto *card = cards.add(new Card(*this, field));
                    content.addAndMakeVisible(card);
                    positions.push_back({n % 2, y + (n / 2) * (height + 8), height});
                    ++n;
                }
            y += (n + 1) / 2 * (height + 8) + 2;
            content.groups.push_back({groupStart, y - groupStart});
            y += 12;
        }
        contentHeight = y;
        viewport.setViewPosition(0, 0);
        resized();
        repaint();
    }
};
} // namespace catlive
