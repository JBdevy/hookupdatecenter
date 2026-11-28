#pragma once
#include "Localization.h"
#include "Session.h"
#include "RegionPitch.h"
namespace catlive {
class TunerControl final : public Component, private Timer {
  public:
    TunerControl(Session &owner, std::function<void(int)> step, std::function<void()> targets)
        : session(owner), configure(std::move(targets)) {
        for (auto *button : {&down, &up}) {
            addAndMakeVisible(button);
            button->setWantsKeyboardFocus(false);
            button->getProperties().set("plain", true);
            button->getProperties().set("fontSize", 15);
            button->setColour(TextButton::textColourOffId, theme::green);
        }
        down.onClick = [step] { step(-1); };
        up.onClick = [step] { step(1); };
        down.setTooltip(String::fromUTF8("Abaixar tom da música"));
        up.setTooltip(String::fromUTF8("Subir tom da música"));
        startTimerHz(8);
    }
    void resized() override {
        constexpr int stepWidth = 28, stepHeight = 28;
        const int y = (getHeight() - stepHeight) / 2;
        down.setBounds(38, y, stepWidth, stepHeight);
        up.setBounds(getWidth() - stepWidth - 3, y, stepWidth, stepHeight);
    }
    const jaras::Part *region() const {
        const auto *song = session.song();
        return song ? regionPitch::target(*song, session.transport()) : nullptr;
    }
    void paint(Graphics &g) override {
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(9));
        g.drawText("Tuner", 5, 0, down.getX() - 5, getHeight(), Justification::centredLeft);
        g.setColour(theme::green);
        g.setFont(theme::semiboldFont(11));
        auto *part = region();
        g.drawText(String(part ? part->pitchSemitones.value_or(0) : 0) + "st", down.getRight(), 0,
                   up.getX() - down.getRight(), getHeight(), Justification::centred);
    }
    void mouseDown(const MouseEvent &e) override {
        if (session.tunerInputAllowed() && e.mods.isPopupMenu() && e.x >= down.getRight() && e.x < up.getX() && region())
            configure();
    }

  private:
    Session &session;
    std::function<void()> configure;
    QuietButton down{String::fromUTF8("−")}, up{"+"};
    std::optional<int> shownPitch;
    void timerCallback() override {
        if (!isShowing())
            return;
        auto *part = region();
        const bool unlocked = session.tunerInputAllowed();
        setAlpha(unlocked ? 1.0f : 0.45f);
        const bool allowed = part && !session.busy && unlocked;
        down.setEnabled(allowed && part->pitchSemitones.value_or(0) > -12);
        up.setEnabled(allowed && part->pitchSemitones.value_or(0) < 12);
        const int pitch = part ? part->pitchSemitones.value_or(0) : 0;
        if (!shownPitch || *shownPitch != pitch) { shownPitch = pitch; repaint(); }
    }
};
class PitchTargetsPanel final : public Component, private Timer {
  public:
    PitchTargetsPanel(Session &owner, ID target, std::function<void()> finish,
                      std::function<void(String)> failure)
        : session(owner), region(std::move(target)), close(std::move(finish)),
          error(std::move(failure)) {
        if (const auto *song = session.song()) {
            const auto part = std::find_if(song->parts.begin(), song->parts.end(), [&](const auto &p) { return p.id == region; });
            for (const auto &track : song->tracks) {
                if (!jaras::fixedTrackName(track.role).empty() || regionPitch::folder(*song, track.id)) continue;
                if (part != song->parts.end() && regionPitch::selected(*song, track, *part)) tracks.insert(track.id);
                auto parent = track.parentTrackID;
                for (size_t depth = 0; parent && depth < song->tracks.size(); ++depth) {
                    groupTracks[*parent].insert(track.id);
                    const auto found = std::find_if(song->tracks.begin(), song->tracks.end(),
                        [&](const auto &candidate) { return candidate.id == *parent; });
                    if (found == song->tracks.end()) break;
                    parent = found->parentTrackID;
                }
            }
        }
        for (auto *button : {&tracksTab, &groupsTab, &all, &apply}) {
            addAndMakeVisible(button);
            button->setWantsKeyboardFocus(false);
        }
        tracksTab.onClick = [this] {
            tab = 0;
            refresh();
        };
        groupsTab.onClick = [this] {
            tab = 1;
            refresh();
        };
        apply.onClick = [this] { commit(); };
        all.onClick = [this] {
            bool selected = false;
            for (auto *b : checks)
                if (!b->getToggleState())
                    selected = true;
            auto ids = visible;
            for (const auto &id : ids)
                select(id, selected);
            refresh();
        };
        addAndMakeVisible(view);
        view.setViewedComponent(&content, false);
        view.setScrollBarsShown(true, false);
        view.setScrollBarThickness(8);
        apply.setColour(TextButton::buttonColourId, theme::green);
        apply.setColour(TextButton::textColourOffId, Colours::black);
        refresh();
        timerCallback();
        startTimerHz(8);
    }
    ~PitchTargetsPanel() override { view.setViewedComponent(nullptr, false); }
    void paint(Graphics &g) override { g.fillAll(theme::panel); }
    void resized() override {
        tracksTab.setBounds(20, 14, (getWidth() - 40) / 2, 28);
        groupsTab.setBounds(getWidth() / 2, 14, (getWidth() - 40) / 2, 28);
        all.setBounds(getWidth() - 160, 52, 140, 26);
        view.setBounds(20, 86, getWidth() - 40, getHeight() - 144);
        content.setSize(view.getWidth() - 8, std::max(view.getHeight(), checks.size() * 31));
        for (int i = 0; i < checks.size(); ++i)
            checks[i]->setBounds(4, i * 31, content.getWidth() - 8, 28);
        apply.setBounds(getWidth() - 98, getHeight() - 43, 78, 28);
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::returnKey) {
            commit();
            return true;
        }
        return false;
    }

  private:
    Session &session;
    ID region;
    std::function<void()> close;
    std::function<void(String)> error;
    int tab = 0;
    std::set<ID> tracks;
    std::map<ID, std::set<ID>> groupTracks;
    std::vector<ID> visible;
    Viewport view;
    Component content;
    OwnedArray<ToggleButton> checks;
    TextButton tracksTab{localization::translate("Pistas")}, groupsTab{localization::translate("Grupos")}, all{"Selecionar todas"},
        apply{"Aplicar"};
    static std::set<ID> asSet(const std::vector<ID> &values) {
        return {values.begin(), values.end()};
    }
    std::set<ID> targetIDs(const ID &id) const {
        if (tab == 0) return {id};
        const auto group = groupTracks.find(id);
        return group == groupTracks.end() ? std::set<ID>{} : group->second;
    }
    void select(const ID &id, bool value) {
        const auto targets = targetIDs(id);
        if (value) tracks.insert(targets.begin(), targets.end());
        else for (const auto &track : targets) tracks.erase(track);
    }
    void refresh() {
        checks.clear();
        visible.clear();
        tracksTab.setToggleState(tab == 0, dontSendNotification);
        groupsTab.setToggleState(tab == 1, dontSendNotification);
        if (const auto *song = session.song())
            for (const auto &track : song->tracks)
                if (jaras::fixedTrackName(track.role).empty() &&
                    regionPitch::folder(*song, track.id) == (tab == 1)) {
                    visible.push_back(track.id);
                    auto *check = checks.add(new ToggleButton(text(track.name)));
                    content.addAndMakeVisible(check);
                    const auto targets = targetIDs(track.id);
                    check->setEnabled(!targets.empty());
                    check->setToggleState(!targets.empty() && std::includes(tracks.begin(), tracks.end(), targets.begin(), targets.end()),
                        dontSendNotification);
                    check->onClick = [this, id = track.id, check] {
                        select(id, check->getToggleState());
                        refresh();
                    };
                }
        bool allSelected = !checks.isEmpty();
        for (auto *check : checks)
            allSelected = allSelected && check->getToggleState();
        all.setButtonText(allSelected ? "Desmarcar todas" : "Selecionar todas");
        resized();
    }
    void timerCallback() override {
        const bool editable = session.tunerInputAllowed();
        view.setEnabled(editable);
        all.setEnabled(editable);
        apply.setEnabled(editable);
    }
    void commit() {
        if (!session.tunerInputAllowed()) return;
        try {
            if (const auto *song = session.song()) for (const auto &part : song->parts)
                if (part.id == region) {
                    if (!part.pitchTrackIDs || tracks != asSet(*part.pitchTrackIDs) ||
                        !part.pitchGroupIDs || !part.pitchGroupIDs->empty())
                        session.setRegionPitch(region, part.pitchSemitones.value_or(0),
                            std::vector<ID>(tracks.begin(), tracks.end()), std::vector<ID>{});
                    break;
                }
            close();
        } catch (const std::exception &e) {
            error(String::fromUTF8(e.what()));
        }
    }
};
} // namespace catlive
