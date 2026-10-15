#pragma once
#include "ActionBindings.h"
#include "Localization.h"
namespace catlive {
class ActionsPage final : public Component, private ChangeListener {
  public:
    explicit ActionsPage(ActionBindings &value, bool mappingsOnly = false,
                         std::function<String(int)> trackDescription = {})
        : actions(value), describeTrack(std::move(trackDescription)), onlyMappings(mappingsOnly) {
        actions.addChangeListener(this);
        setWantsKeyboardFocus(true);
        addAndMakeVisible(viewport);
        viewport.setViewedComponent(&rows, false);
        viewport.setScrollBarsShown(true, false);
        const StringArray names{"Transporte", "Volume", "Mute", "Solo", "Setlist", "Atalhos"};
        for (int i = 0; i < names.size(); ++i) {
            auto *b = tabs.add(new TextButton(names[i]));
            addAndMakeVisible(b);
            b->getProperties().set("flat", true);
            b->getProperties().set("fontSize", 12);
            b->setColour(TextButton::buttonOnColourId, theme::green.withAlpha(.18f));
            b->setColour(TextButton::textColourOnId, theme::green);
            b->onClick = [this, i] {
                category = i;
                if (i == 1)
                    kind = "midi";
                if (i == 5)
                    kind = "keyboard";
                viewport.setViewPosition(0, 0);
                rebuild();
            };
        }
        addAndMakeVisible(keyboard);
        addAndMakeVisible(midi);
        addAndMakeVisible(information);
        keyboard.onClick = [this] {
            kind = "keyboard";
            viewport.setViewPosition(0, 0);
            rebuild();
        };
        midi.onClick = [this] {
            kind = "midi";
            viewport.setViewPosition(0, 0);
            rebuild();
        };
        information.setFont(theme::font(11));
        for (auto *button : {&keyboard, &midi}) {
            button->getProperties().set("flat", true);
            button->getProperties().set("fontSize", 13.f);
            button->setColour(TextButton::buttonColourId, Colour(0xff333333));
            button->setColour(TextButton::buttonOnColourId, Colour(0xff64b64a));
            button->setColour(TextButton::textColourOnId, Colours::white);
        }
        rebuild();
    }
    ~ActionsPage() override {
        actions.removeChangeListener(this);
        actions.cancel();
    }
    bool keyPressed(const KeyPress &key) override { return actions.captureKey(key); }
    void paint(Graphics &g) override {
        if (!onlyMappings) {
            g.setFont(theme::font(13));
            g.setColour(Colours::white);
            g.drawText(localization::translate("Input"), 0, 44, 52, 24, Justification::centredLeft);
        }
    }
    void resized() override {
        const int column = (getWidth() - 30) / 6;
        for (int i = 0; i < tabs.size(); ++i) {
            tabs[i]->setBounds(i * (column + 6), 0, column, 30);
            tabs[i]->setVisible(!onlyMappings);
        }
        keyboard.setBounds(56, 44, 72, 24);
        midi.setBounds(128, 44, 72, 24);
        keyboard.setVisible(!onlyMappings);
        midi.setVisible(!onlyMappings);
        information.setBounds(0, onlyMappings ? 0 : 78, getWidth(), 22);
        const int top = onlyMappings ? 40 : 110;
        viewport.setBounds(0, top, getWidth(), std::max(1, getHeight() - top));
        rows.setSize(std::max(200, viewport.getWidth() - 10), contentHeight);
        int y = 0;
        for (auto *card : cards) {
            const int height = card->height();
            card->setBounds(0, y, rows.getWidth(), height);
            y += height + 14;
        }
    }

  private:
    class Card final : public Component {
      public:
        Card(ActionsPage &owner, const ActionDefinition &definition, String inputKind)
            : page(owner), action(definition), kind(std::move(inputKind)) {
            for (auto *component : std::initializer_list<Component *>{&name, &reset, &input,
                                                                      &remove, &track, &target})
                addAndMakeVisible(component);
            name.setText(action.title, dontSendNotification);
            name.setFont(theme::semiboldFont(13));
            reset.getProperties().set("flat", true);
            reset.getProperties().set("fontSize", 12);
            reset.setColour(TextButton::buttonColourId, Colour(0xff505050));
            const auto current = page.actions.binding(action);
            auto label = page.actions.inputLabel(action, kind);
            const bool listening =
                page.actions.learning == action.id && page.actions.learningKind == kind;
            input.setName(listening         ? String::fromUTF8("Aguardando controle…")
                          : label.isEmpty() ? "Mapear controle"
                                            : label);
            input.kind = kind;
            input.listening = listening;
            input.locked = kind == "keyboard" && action.fixedKeyboard();
            input.setTooltip(String(action.title) + " " + kind);
            input.onClick = [this] {
                page.actions.begin(action.id, kind);
                page.grabKeyboardFocus();
            };
            remove.setVisible(label.isNotEmpty() && !input.locked);
            remove.getProperties().set("plain", true);
            remove.getProperties().set("icon", "close");
            remove.onClick = [this] { page.actions.assign(action.id, kind, {}); };
            reset.onClick = [this] {
                page.actions.assign(action.id, kind,
                                    kind == "keyboard" ? var(String(action.defaultKey).isEmpty()
                                                                 ? String()
                                                                 : KeyPress::createFromDescription(
                                                                       action.defaultKey)
                                                                       .getTextDescription())
                                                       : var());
            };
            track.setVisible(action.track);
            target.setVisible(action.track);
            target.setFont(theme::font(11));
            const int number = (int)num(current, "track");
            auto updateTarget = [this](int number) {
                target.setText(page.describeTrack ? page.describeTrack(number)
                               : number > 0       ? "Pista " + String(number)
                                                  : "Pista selecionada",
                               dontSendNotification);
            };
            updateTarget(number);
            track.setInputRestrictions(4, "0123456789");
            track.setText(number > 0 ? String(number) : String());
            track.setTextToShowWhenEmpty("Selecionada", theme::secondary);
            track.onTextChange = [this, updateTarget] {
                updateTarget(track.getText().getIntValue());
            };
            track.onFocusLost = [this] {
                page.actions.setTrack(action.id, track.getText().getIntValue());
            };
            input.setEnabled(!input.locked && !(kind == "keyboard" && action.continuous));
            reset.setEnabled(!input.locked);
        }
        int height() const { return action.track ? 126 : 96; }
        void paint(Graphics &g) override {
            g.setColour(theme::panel);
            g.fillRoundedRectangle(getLocalBounds().toFloat(), 6);
            if (action.track) {
                g.setColour(Colours::white);
                g.setFont(theme::font(13));
                g.drawText("Track", 12, 36, 36, 24, Justification::centredLeft);
            }
        }
        void resized() override {
            name.setBounds(12, 8, getWidth() - 120, 24);
            reset.setBounds(getWidth() - 94, 12, 82, 24);
            track.setBounds(48, 36, 92, 24);
            target.setBounds(146, 36, getWidth() - 162, 24);
            input.setBounds(12, action.track ? 74 : 44, input.locked ? 140 : getWidth() - 42, 40);
            remove.setBounds(getWidth() - 30, input.getY() + 8, 24, 24);
        }

      private:
        ActionsPage &page;
        ActionDefinition action;
        String kind;
        Label name, target;
        class InputButton final : public Button {
          public:
            InputButton() : Button("Mapear controle") {}
            String kind;
            bool listening = false, locked = false;
            void paintButton(Graphics &g, bool over, bool) override {
                g.setColour(over ? theme::display.brighter(.05f) : theme::display);
                if (!locked)
                    g.fillRoundedRectangle(getLocalBounds().toFloat(), 4);
                g.setColour(theme::secondary);
                g.setFont(theme::font(10));
                g.drawText(kind == "midi" ? "MIDI" : "Teclado", 6, 4, getWidth() - 12, 14,
                           Justification::centredLeft);
                g.setColour(listening ? theme::green : Colours::white);
                g.setFont(theme::font(11));
                g.drawText(getName(), 6, 20, getWidth() - 12, 14, Justification::centredLeft);
            }
        } input;
        TextButton reset{String::fromUTF8("Restaurar")}, remove{String::fromUTF8("×")};
        TextEditor track;
    };
    ActionBindings &actions;
    std::function<String(int)> describeTrack;
    bool onlyMappings = false;
    int category = 0, contentHeight = 0;
    String kind = "keyboard";
    OwnedArray<TextButton> tabs;
    TextButton keyboard{"Teclado"}, midi{"MIDI"};
    Label information;
    Viewport viewport;
    Component rows;
    OwnedArray<Card> cards;
    void changeListenerCallback(ChangeBroadcaster *) override { rebuild(); }
    void rebuild() {
        cards.clear();
        for (int i = 0; i < tabs.size(); ++i)
            tabs[i]->setToggleState(i == category, dontSendNotification);
        keyboard.setToggleState(kind == "keyboard", dontSendNotification);
        midi.setToggleState(kind == "midi", dontSendNotification);
        contentHeight = 0;
        auto add = [&](const ActionDefinition &definition, const String &inputKind) {
            auto *card = cards.add(new Card(*this, definition, inputKind));
            rows.addAndMakeVisible(card);
            contentHeight += card->height() + 14;
        };
        for (const auto &definition : actionDefinitions()) {
            if (onlyMappings) {
                for (auto inputKind : {String("keyboard"), String("midi")})
                    if (actions.hasCustomInput(definition, inputKind))
                        add(definition, inputKind);
                continue;
            }
            if (!onlyMappings && definition.category != category)
                continue;
            if (kind == "keyboard" && definition.continuous)
                continue;
            if (kind == "midi" && !definition.supportsMIDI())
                continue;
            add(definition, kind);
        }
        information.setText(actions.error.isNotEmpty() ? actions.error
                            : onlyMappings && cards.isEmpty()
                                ? "Nenhum mapeamento ainda."
                                : String::fromUTF8("As ações são salvas para todos os projetos."),
                            dontSendNotification);
        information.setColour(Label::textColourId,
                              actions.error.isNotEmpty() ? Colour(0xffff6565) : theme::secondary);
        localization::panel(*this);
        resized();
        repaint();
    }
};
} // namespace catlive
