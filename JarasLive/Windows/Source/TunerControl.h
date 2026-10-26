#pragma once
#include "Localization.h"
#include "Session.h"
namespace catlive {
class TunerControl final : public Component, private Timer {
  public:
    TunerControl(Session &owner, std::function<void(int)> step, std::function<void()> targets)
        : session(owner), configure(std::move(targets)) {
        for (auto *button : {&down, &up}) {
            addAndMakeVisible(button);
            button->setWantsKeyboardFocus(false);
            button->getProperties().set("plain", true);
            button->setColour(TextButton::textColourOffId, theme::green);
        }
        down.onClick = [step] { step(-1); };
        up.onClick = [step] { step(1); };
        down.setTooltip(String::fromUTF8("Abaixar tom da música"));
        up.setTooltip(String::fromUTF8("Subir tom da música"));
        startTimerHz(8);
    }
    void resized() override {
        down.setBounds(48, 0, 20, getHeight());
        up.setBounds(getWidth() - 24, 0, 20, getHeight());
    }
    const jaras::Part *region() const {
        const auto *song = session.song();
        if (!song)
            return nullptr;
        const auto &transport = session.transport();
        if (transport.playing) {
            for (const auto &part : song->parts) if (transport.ignoreNextRegionId == part.id) return &part;
            if (const auto *part = regionPitch::at(*song, transport.position)) return part;
        }
        for (const auto &part : song->parts)
            if (transport.regionId == part.id) {
                if (transport.playing) return &part;
                const jaras::Part *first = nullptr;
                for (const auto &child : song->parts)
                    if (child.parentRegionID == part.id && (!first || child.startTime < first->startTime)) first = &child;
                return first ? first : &part;
            }
        return nullptr;
    }
    void paint(Graphics &g) override {
        auto bounds = getLocalBounds().toFloat().reduced(.5f);
        g.setColour(theme::display);
        g.fillRoundedRectangle(bounds, 4);
        g.setColour(theme::line);
        g.drawRoundedRectangle(bounds, 4, 1);
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(9));
        g.drawText("Tuner", 5, 0, 42, getHeight(), Justification::centredLeft);
        g.setColour(theme::green);
        g.setFont(theme::semiboldFont(11));
        auto *part = region();
        g.drawText(String(part ? part->pitchSemitones.value_or(0) : 0) + "st", 68, 0,
                   getWidth() - 92, getHeight(), Justification::centred);
    }
    void mouseDown(const MouseEvent &e) override {
        if (e.mods.isPopupMenu() && e.x >= 68 && e.x < getWidth() - 24 && region())
            configure();
    }

  private:
    Session &session;
    std::function<void()> configure;
    QuietButton down{String::fromUTF8("−")}, up{"+"};
    void timerCallback() override {
        if (!isShowing())
            return;
        auto *part = region();
        const bool allowed =
            part && !session.busy;
        down.setEnabled(allowed && part->pitchSemitones.value_or(0) > -12);
        up.setEnabled(allowed && part->pitchSemitones.value_or(0) < 12);
        repaint();
    }
};
class PitchTargetsPanel final : public Component {
  public:
    PitchTargetsPanel(Session &owner, ID target, std::function<void()> finish,
                      std::function<void(String)> failure)
        : session(owner), region(std::move(target)), close(std::move(finish)),
          error(std::move(failure)) {
        if (auto *song = session.song()) {
            tracks = asSet(regionPitch::defaults(*song, false));
            groups = asSet(regionPitch::defaults(*song, true));
            for (const auto &part : song->parts)
                if (part.id == region) {
                    if (part.pitchTrackIDs)
                        tracks = asSet(*part.pitchTrackIDs);
                    if (part.pitchGroupIDs)
                        groups = asSet(*part.pitchGroupIDs);
                }
        }
        for (auto *button : {&tracksTab, &groupsTab, &all, &cancel, &apply}) {
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
        cancel.onClick = close;
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
        cancel.setBounds(getWidth() - 184, getHeight() - 43, 78, 28);
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
    std::set<ID> tracks, groups;
    std::vector<ID> visible;
    Viewport view;
    Component content;
    OwnedArray<ToggleButton> checks;
    TextButton tracksTab{localization::translate("Pistas")}, groupsTab{localization::translate("Grupos")}, all{"Selecionar todas"},
        cancel{"Cancelar"}, apply{"Aplicar"};
    static std::set<ID> asSet(const std::vector<ID> &values) {
        return {values.begin(), values.end()};
    }
    bool selected(const jaras::Track &track) const {
        if (!tab) {
            if (tracks.count(track.id))
                return true;
            auto parent = track.parentTrackID;
            const auto *song = session.song();
            for (size_t depth = 0; parent && song && depth < song->tracks.size(); ++depth) {
                if (groups.count(*parent))
                    return true;
                auto found = std::find_if(song->tracks.begin(), song->tracks.end(),
                                          [&](const auto &t) { return t.id == *parent; });
                if (found == song->tracks.end())
                    break;
                parent = found->parentTrackID;
            }
            return false;
        }
        if (groups.count(track.id))
            return true;
        bool any = false;
        for (const auto &child : session.song()->tracks)
            if (child.parentTrackID == track.id) {
                any = true;
                if (!tracks.count(child.id))
                    return false;
            }
        return any;
    }
    void select(const ID &id, bool value) {
        const auto *song = session.song();
        if (!song)
            return;
        if (tab) {
            for (const auto &track : song->tracks)
                if (track.id == id || track.parentTrackID == id)
                    tracks.erase(track.id);
            if (value)
                groups.insert(id);
            else
                groups.erase(id);
        } else {
            if (!value) { // Expand selected ancestor groups into explicit leaf targets before
                          // clearing one leaf.
                std::set<ID> explicitTracks = tracks;
                for (const auto &track : song->tracks)
                    if (!regionPitch::folder(*song, track.id) && selected(track))
                        explicitTracks.insert(track.id);
                tracks = std::move(explicitTracks);
                groups.clear();
                tracks.erase(id);
            } else
                tracks.insert(id);
        }
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
                    check->setToggleState(selected(track), dontSendNotification);
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
    void commit() {
        try {
            if (const auto *song = session.song()) for (const auto &part : song->parts)
                if (part.id == region) {
                    session.setRegionPitch(region, part.pitchSemitones.value_or(0),
                        std::vector<ID>(tracks.begin(), tracks.end()), std::vector<ID>(groups.begin(), groups.end()));
                    break;
                }
            close();
        } catch (const std::exception &e) {
            error(String::fromUTF8(e.what()));
        }
    }
};
} // namespace catlive
