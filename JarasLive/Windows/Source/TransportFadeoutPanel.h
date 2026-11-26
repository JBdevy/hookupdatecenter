#pragma once
#include "Localization.h"
#include "Session.h"
#include "Appearance.h"
#include "ActionBindings.h"
#include "ModalSheet.h"

namespace catlive {
class TransportFadeoutPanel final : public Component, private Timer, private ChangeListener {
  public:
    struct Configuration { bool enabled = false; double duration = 3; std::set<ID> tracks; };
    static bool eligibleTrack(const jaras::Track &track) {
        return !jaras::isTeleprompterRole(track.role) && track.role.id != "video" &&
               track.role.id != "timecode" && track.role.id != "chords";
    }
    static Configuration read(const Appearance &preferences, const jaras::Project &project) {
        Configuration value;
        value.enabled = (bool)preferences.value("jaras.transportFadeout.enabled", false);
        const double seconds = (double)preferences.value("jaras.transportFadeout.duration", 3.0);
        value.duration = std::isfinite(seconds) ? std::round(jlimit(1., 5., seconds)) : 3;
        const auto saved = get(preferences.value("jaras.transportFadeout.projects", object()), Identifier(text(project.id)));
        std::set<ID> requested;
        if (const auto *ids = saved.getArray())
            for (const auto &id : *ids) if (id.isString()) requested.insert(utf8(id.toString()));
        for (const auto &song : project.songs) for (const auto &track : song.tracks)
            if (eligibleTrack(track) && (!saved.isArray() || requested.count(track.id))) value.tracks.insert(track.id);
        return value;
    }
    TransportFadeoutPanel(Session &value, Appearance &appearance, ActionBindings &bindings)
        : session(value), preferences(appearance), actions(bindings) {
        setComponentID("transportFadeoutPanel");
        setWantsKeyboardFocus(true);
        for (auto *component : std::initializer_list<Component *>{&enabled, &duration, &viewport,
                 &shortcut, &removeShortcut, &keyboardTab, &midiTab, &feedback}) addAndMakeVisible(component);
        enabled.setButtonText(localization::translate("Ativar Fadeout")); enabled.setComponentID("transportFadeoutEnabled");
        enabled.onClick = [this] { if (!locked()) save("jaras.transportFadeout.enabled", enabled.getToggleState()); };
        duration.setComponentID("transportFadeoutDuration");
        for (int seconds = 1; seconds <= 5; ++seconds) duration.addItem(String(seconds) + " s", seconds);
        duration.onChange = [this] { if (!locked()) save("jaras.transportFadeout.duration", (double)duration.getSelectedId()); };
        viewport.setViewedComponent(&trackRows, false);
        viewport.setScrollBarsShown(true, false); viewport.setScrollBarThickness(10);
        viewport.setComponentID("transportFadeoutTracks");
        shortcut.setComponentID("transportFadeoutShortcut");
        removeShortcut.setComponentID("transportFadeoutRemoveShortcut");
        keyboardTab.setComponentID("transportFadeoutKeyboard");
        midiTab.setComponentID("transportFadeoutMIDI");
        for (auto *button : {&shortcut, &removeShortcut, &keyboardTab, &midiTab}) {
            button->getProperties().set("flat", true);
            button->getProperties().set("fontSize", 12.f);
        }
        shortcut.onClick = [this] {
            if (locked()) return;
            localError.clear();
            if (listening()) actions.cancel();
            else { actions.begin("transportFadeout", inputKind); grabKeyboardFocus(); }
            refresh();
        };
        removeShortcut.onClick = [this] {
            if (locked()) return;
            if (listening()) actions.cancel();
            localError = actions.assign("transportFadeout", inputKind, {}) ? String() : actions.error;
            refresh();
        };
        keyboardTab.onClick = [this] { selectInput("keyboard"); };
        midiTab.onClick = [this] { selectInput("midi"); };
        for(auto *tab : {&keyboardTab,&midiTab}) {
            tab->setColour(TextButton::buttonOnColourId,theme::green.withAlpha(.18f));
            tab->setColour(TextButton::textColourOnId,theme::green);
        }
        feedback.setFont(theme::font(11)); feedback.setJustificationType(Justification::centredLeft);
        actions.addChangeListener(this);
        rebuildTracks(); refresh(); startTimerHz(8);
    }
    ~TransportFadeoutPanel() override {
        stopTimer(); actions.removeChangeListener(this);
        if (listening()) actions.cancel();
        viewport.setViewedComponent(nullptr, false);
    }
    bool keyPressed(const KeyPress &key) override {
        if (!listening()) return false;
        if (locked()) { actions.cancel(); refresh(); return true; }
        if(key == KeyPress::escapeKey) { actions.cancel();localError.clear();refresh();return true; }
        if(inputKind == "midi") return true;
        const bool handled = actions.captureKey(key);
        localError = actions.error; refresh(); return handled;
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::background);
        g.setFont(theme::font(12)); g.setColour(Colours::white);
        g.drawText(localization::translate(String::fromUTF8("Duração")), 18, 55, 100, 26, Justification::centredLeft);
        g.drawText(localization::translate(String::fromUTF8("Pistas incluídas")), 18, 94, getWidth() - 36, 24, Justification::centredLeft);
        g.setColour(theme::display); g.fillRoundedRectangle(viewport.getBounds().toFloat(), 6);
        g.setColour(theme::line); g.drawRoundedRectangle(viewport.getBounds().toFloat().reduced(.5f), 6, 1);
        g.setColour(Colours::white);
        g.drawText(inputKind == "midi" ? "MIDI" : localization::translate("Tecla"), 18, shortcut.getY(), 68, shortcut.getHeight(), Justification::centredLeft);
        if (trackButtons.isEmpty()) {
            g.setColour(theme::secondary); g.setFont(theme::font(12));
            g.drawText(localization::translate(String::fromUTF8("Nenhuma pista de áudio neste projeto.")), viewport.getBounds().reduced(10), Justification::centred);
        }
    }
    void resized() override {
        enabled.setBounds(18, 14, getWidth() - 36, 28);
        duration.setBounds(getWidth() - 112, 55, 94, 26);
        viewport.setBounds(18, 120, getWidth() - 36, std::max(50, getHeight() - 260));
        const int y = viewport.getBottom() + 14;
        keyboardTab.setBounds(18,y,(getWidth()-36)/2,28);
        midiTab.setBounds(keyboardTab.getRight(),y,getWidth()-18-keyboardTab.getRight(),28);
        removeShortcut.setBounds(getWidth() - 94, y + 40, 76, 28);
        shortcut.setBounds(86, y + 40, std::max(50, removeShortcut.getX() - 94), 28);
        feedback.setBounds(18, y + 74, getWidth() - 36, std::max(28, getHeight() - y - 80));
        trackRows.setSize(std::max(1, viewport.getWidth() - 12), std::max(1, trackButtons.size() * 30 + 8));
        for (int i = 0; i < trackButtons.size(); ++i) trackButtons[i]->setBounds(8, 4 + i * 30, trackRows.getWidth() - 16, 28);
    }
  private:
    Session &session; Appearance &preferences; ActionBindings &actions;
    ToggleButton enabled;
    ComboBox duration;
    Viewport viewport; Component trackRows;
    OwnedArray<ToggleButton> trackButtons;
    std::vector<ID> trackIDs;
    TextButton shortcut, removeShortcut{localization::translate("Remover")}, keyboardTab{localization::translate("Tecla")}, midiTab{"MIDI"};
    Label feedback;
    String localError, inputKind = "keyboard";
    ID builtProject, builtSong;
    uint64 builtRevision = ~uint64(0);
    bool listening() const { return actions.learning == "transportFadeout" && actions.learningKind == inputKind; }
    bool locked() const { return session.transportFadeoutActive(); }
    void save(const String &key, var value) {
        const auto result = preferences.set(key, std::move(value));
        localError = result.getErrorMessage(); refresh();
    }
    void setTrack(const ID &id, bool included, const ID &projectID) {
        if (locked() || session.project().id != projectID) { refresh(); return; }
        auto value = read(preferences, session.project());
        if (included) value.tracks.insert(id); else value.tracks.erase(id);
        auto projects = preferences.value("jaras.transportFadeout.projects", object()).clone();
        if (!projects.isObject()) projects = object();
        Array<var> ids; for (const auto &track : value.tracks) ids.add(text(track));
        put(projects, Identifier(text(projectID)), ids);
        save("jaras.transportFadeout.projects", projects);
    }
    void rebuildTracks() {
        const bool changedProject = builtProject != session.project().id;
        builtProject = session.project().id; builtSong = session.song() ? session.song()->id : ID{};
        builtRevision = session.revision;
        std::vector<const jaras::Track *> current;
        if (const auto *song = session.song()) for (const auto &track : song->tracks)
            if (eligibleTrack(track)) current.push_back(&track);
        bool same = !changedProject && current.size() == trackIDs.size();
        if (same) for (size_t i = 0; i < current.size(); ++i)
            same = same && current[i]->id == trackIDs[i] && trackButtons[(int)i]->getButtonText() == text(current[i]->name);
        if (same) return;
        trackButtons.clear(); trackIDs.clear();
        for (const auto *track : current) {
            const auto id = track->id, projectID = session.project().id;
            auto *button = trackButtons.add(new ToggleButton(text(track->name)));
            trackIDs.push_back(id); trackRows.addAndMakeVisible(button);
            button->setComponentID("transportFadeoutTrack-" + text(id));
            button->onClick = [this, button, id, projectID] { setTrack(id, button->getToggleState(), projectID); };
        }
        resized(); repaint();
    }
    void refresh() {
        if (builtProject != session.project().id || builtSong != (session.song() ? session.song()->id : ID{}) || builtRevision != session.revision)
            rebuildTracks();
        const auto value = read(preferences, session.project());
        const bool active = locked();
        if (active && actions.learning == "transportFadeout") actions.cancel();
        enabled.setToggleState(value.enabled, dontSendNotification); enabled.setEnabled(!active);
        duration.setSelectedId((int)value.duration, dontSendNotification); duration.setEnabled(!active);
        for (int i = 0; i < trackButtons.size(); ++i) {
            trackButtons[i]->setToggleState(value.tracks.count(trackIDs[(size_t)i]) != 0, dontSendNotification);
            trackButtons[i]->setEnabled(!active);
        }
        const auto label = actions.inputLabel("transportFadeout", inputKind);
        shortcut.setButtonText(listening() ? String::fromUTF8(inputKind == "midi" ? "Acione o controle MIDI…" : "Pressione uma tecla…") : label.isEmpty() ? (inputKind == "midi" ? localization::translate("Mapear MIDI") : "Definir atalho") : label);
        shortcut.setEnabled(!active); removeShortcut.setEnabled(!active && (listening() || label.isNotEmpty())); keyboardTab.setEnabled(!active);midiTab.setEnabled(!active);
        keyboardTab.setToggleState(inputKind == "keyboard",dontSendNotification);midiTab.setToggleState(inputKind == "midi",dontSendNotification);
        feedback.setText(active ? localization::translate(String::fromUTF8("Aguarde o Fadeout terminar para alterar estas opções."))
                         : localError.isNotEmpty() ? localError
                         : listening() ? String::fromUTF8("Esc cancela. Atalhos existentes são preservados.")
                         : inputKind == "midi" ? String::fromUTF8("Clique em Mapear MIDI e acione uma nota ou botão CC. A entrada MIDI deve estar ativa em Configurações.")
                         : String::fromUTF8("Use uma tecla livre. Espaço e atalhos padrão não podem ser usados."), dontSendNotification);
        feedback.setColour(Label::textColourId, localError.isNotEmpty() && !active ? Colour(0xffff9b96) : theme::secondary);
    }
    void selectInput(const String &kind) {
        if(locked())return;
        if(actions.learning == "transportFadeout")actions.cancel();
        inputKind=kind;localError.clear();refresh();repaint();
    }
    void timerCallback() override { refresh(); }
    void changeListenerCallback(ChangeBroadcaster *) override { localError=actions.error;refresh(); }
};
} // namespace catlive
