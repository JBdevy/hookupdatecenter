#pragma once
#include "Automation.h"
#include "Session.h"
#include "Localization.h"
namespace catlive {
class AutomationPanel final : public Component {
  public:
    AutomationPanel(Session &s, ID target, std::function<void(String)> report)
        : session(s), id(std::move(target)), error(std::move(report)) {
        for (auto *c : std::initializer_list<Component *>{&enabled, &mode, &search, &active,
                                                          &visible, &armed})
            addAndMakeVisible(c);
        mode.addItemList({"Trim / Read", "Read", "Touch", "Latch", "Write"}, 1);
        search.setTextToShowWhenEmpty(localization::translate("Search parameters"),
                                      theme::secondary);
        enabled.onClick = [this] {
            edit([&](var &s) {
                put(s, "enabled", enabled.getToggleState());
                put(s, "lanesVisible", enabled.getToggleState());
            });
        };
        mode.onChange = [this] {
            static const char *modes[]{"trimRead", "read", "touch", "latch", "write"};
            edit([&](var &s) { put(s, "mode", modes[mode.getSelectedId() - 1]); });
        };
        active.onClick = [this] { change("enabled", active.getToggleState()); };
        visible.onClick = [this] { change("visible", visible.getToggleState()); };
        armed.onClick = [this] { change("armed", armed.getToggleState()); };
        for (int i = 0; i < 3; ++i) {
            auto *toggle = choices.add(new ToggleButton(i == 0   ? "Volume"
                                                        : i == 1 ? "Pan"
                                                                 : "Mute"));
            addAndMakeVisible(toggle);
            toggle->onClick = [this, i] {
                selected = i;
                edit([&](var &s) {
                    auto list = catlive::list(get(s, "envelopes"));
                    const String kind = i == 0 ? "volume" : i == 1 ? "pan" : "mute";
                    bool found = false;
                    for (auto &e : list)
                        if (str(get(e, "target"), "kind") == kind) {
                            put(e, "enabled", choices[i]->getToggleState());
                            put(e, "visible", true);
                            found = true;
                        }
                    if (!found) {
                        const auto *t = track();
                        list.add(automation::envelope(
                            kind, i == 0   ? AutomationCurve::normalized(t ? t->volume : session.project().masterVolume)
                                  : i == 1 ? (t ? t->pan : session.project().masterPan) * .5 + .5
                                           : 0));
                    }
                    put(s, "envelopes", list);
                    put(s, "enabled", true);
                    put(s, "lanesVisible", true);
                });
            };
        }
        search.onTextChange = [this] {
            for (auto *choice : choices)
                choice->setVisible(choice->getButtonText().containsIgnoreCase(search.getText()));
        };
        refresh();
        localization::panel(*this);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::background);
        g.setColour(theme::line);
        g.drawVerticalLine(266, 54.f, (float)getHeight() - 16);
        g.setColour(Colours::white);
        g.setFont(theme::font(13));
        g.drawText(selected == 0   ? "Volume"
                   : selected == 1 ? "Pan"
                                   : "Mute",
                   294, 68, 200, 28, Justification::centredLeft);
        g.setColour(theme::secondary);
        g.setFont(theme::font(12));
        g.drawFittedText(String::fromUTF8("Edite os pontos do envelope no grid, abaixo da pista."),
                         280, getHeight() - 70, getWidth() - 300, 24, Justification::centred, 1);
        g.setFont(theme::font(10));
        g.drawFittedText(
            String::fromUTF8(
                "Duplo clique adiciona um ponto. Arraste para mover. Shift libera da "
                "grade.\nDelete apaga o ponto selecionado. Clique direito altera a curva."),
            280, getHeight() - 46, getWidth() - 300, 36, Justification::centred, 2);
    }
    void resized() override {
        enabled.setBounds(16, 12, 240, 30);
        mode.setBounds(getWidth() - 160, 12, 142, 26);
        search.setBounds(16, 54, 236, 26);
        for (int i = 0; i < choices.size(); ++i)
            choices[i]->setBounds(18, 88 + i * 32, 234, 28);
        active.setBounds(getWidth() - 210, 64, 72, 28);
        visible.setBounds(getWidth() - 138, 64, 66, 28);
        armed.setBounds(getWidth() - 72, 64, 66, 28);
    }

  private:
    Session &session;
    ID id;
    std::function<void(String)> error;
    ToggleButton enabled{String::fromUTF8("Automação ativada")}, active{"Ativado"},
        visible{String::fromUTF8("Visível")}, armed{"Armar"};
    ComboBox mode;
    TextEditor search;
    OwnedArray<ToggleButton> choices;
    int selected = 0;
    const jaras::Track *track() const {
        if (auto *s = session.song())
            for (const auto &t : s->tracks)
                if (t.id == id)
                    return &t;
        return nullptr;
    }
    var settings() const {
        if(id.empty())return session.project().masterAutomationJSON ? JSON::parse(text(*session.project().masterAutomationJSON)) : object();
        if (auto *t = track())
            return automation::settings(*t);
        return {};
    }
    String kind() const { return selected == 0 ? "volume" : selected == 1 ? "pan" : "mute"; }
    void edit(std::function<void(var &)> action) {
        try {
            session.edit([&](jaras::Project &p) {
                if(id.empty()){auto value=settings();action(value);p.masterAutomationJSON=utf8(JSON::toString(value,true));return;}
                for (auto &s : p.songs)
                    for (auto &t : s.tracks)
                        if (t.id == id) {
                            auto value = automation::settings(t);
                            action(value);
                            t.automationJSON = utf8(JSON::toString(value, true));
                        }
            });
        } catch (const std::exception &e) {
            if (error)
                error(String::fromUTF8(e.what()));
        }
        refresh();
    }
    void change(String key, var value) {
        edit([&](var &s) {
            auto entries = list(get(s, "envelopes"));
            for (auto &entry : entries)
                if (str(get(entry, "target"), "kind") == kind())
                    put(entry, Identifier(key), value);
            put(s, "envelopes", entries);
        });
    }
    void refresh() {
        const auto value = settings();
        enabled.setToggleState(flag(value, "enabled", true), dontSendNotification);
        const StringArray modes{"trimRead", "read", "touch", "latch", "write"};
        mode.setSelectedId(std::max(1, modes.indexOf(str(value, "mode", "trimRead")) + 1),
                           dontSendNotification);
        for (int i = 0; i < choices.size(); ++i)
            choices[i]->setToggleState(false, dontSendNotification);
        var current;
        for (const auto &entry : list(get(value, "envelopes"))) {
            const auto target = str(get(entry, "target"), "kind");
            for (int i = 0; i < choices.size(); ++i)
                if (target == (i == 0 ? "volume" : i == 1 ? "pan" : "mute"))
                    choices[i]->setToggleState(flag(entry, "enabled", true), dontSendNotification);
            if (target == kind())
                current = entry;
        }
        for (auto *toggle : {&active, &visible, &armed})
            toggle->setEnabled(current.isObject());
        active.setToggleState(flag(current, "enabled", true), dontSendNotification);
        visible.setToggleState(flag(current, "visible", true), dontSendNotification);
        armed.setToggleState(flag(current, "armed"), dontSendNotification);
        repaint();
    }
};
} // namespace catlive
