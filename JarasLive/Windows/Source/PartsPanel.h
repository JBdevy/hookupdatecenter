#pragma once
#include "Session.h"
namespace catlive {
namespace partsPresentation {
inline const jaras::Part *region(const jaras::Song &song, const jaras::TransportState &state) {
    if (state.ignoreNextEnd && state.ignoreNextRegionId)
        for (const auto &part : song.parts)
            if (part.id == *state.ignoreNextRegionId && state.position >= part.startTime &&
                state.position < *state.ignoreNextEnd) return &part;
    const jaras::Part *result = nullptr;
    for (const auto &part : song.parts)
        if (state.position >= part.startTime && state.position < part.endTime &&
            (!result || (part.parentRegionID && !result->parentRegionID) ||
             (part.parentRegionID.has_value() == result->parentRegionID.has_value() &&
              part.endTime - part.startTime < result->endTime - result->startTime))) result = &part;
    return result;
}
inline double end(const jaras::Part &part, const jaras::TransportState &state) {
    return state.ignoreNextRegionId == part.id && state.ignoreNextEnd
        ? *state.ignoreNextEnd : part.endTime;
}
inline std::optional<double> trigger(const jaras::Song &song, const jaras::Part &part,
                                    const jaras::TransportState &state) {
    if (!state.playing) return {};
    // A boundary already rendered when the user armed the jump cannot become
    // its countdown target merely because the audible cursor trails the core.
    const double position = state.queuedSectionMarkerId
        ? std::max(state.position, state.sectionQueueStartedAt) : state.position;
    double next = end(part, state);
    if (next <= position + 1e-9) return {};
    if (song.markers) for (const auto &marker : *song.markers) {
        if (!marker.section.value_or(false) || marker.tempoBPM) continue;
        if (state.ignoreNextAfter && marker.position >= *state.ignoreNextAfter && marker.regionOwnerID != part.id) continue;
        if (marker.position > position + 1e-9 && marker.position <= part.endTime && marker.position < next)
            next = marker.position;
    }
    return next;
}
} // namespace partsPresentation
class PartsPanel final : public Component, private Timer {
  public:
    PartsPanel(Session &owner, std::function<void(String)> failure, bool verticalList = false)
        : session(owner), error(std::move(failure)), vertical(verticalList), current(*this, false),
          queued(*this, true) {
        addAndMakeVisible(current);
        addAndMakeVisible(queued);
        for (auto *button : std::initializer_list<Button *>{&cancel, &currentTab, &queuedTab}) {
            addChildComponent(button);
            button->setWantsKeyboardFocus(false);
        }
        cancel.onClick = [this] {
            try {
                session.command(jaras::CommandKind::cancelSection);
            } catch (const std::exception &e) {
                error(String::fromUTF8(e.what()));
            }
        };
        currentTab.onClick = [this] {
            secondaryTab = false;
            resized();
        };
        queuedTab.onClick = [this] {
            secondaryTab = true;
            resized();
        };
        startTimerHz(60);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(theme::secondary.withAlpha(.35f));
        if (!vertical)
            g.drawVerticalLine(getWidth() / 2, 5.f, (float)getHeight() - 5);
        else {
            g.drawVerticalLine(0, 0.f, (float)getHeight());
            for (int i = 0; i < 2; ++i) {
                auto r = (i ? queuedTab : currentTab).getBounds();
                const bool selected = secondaryTab == (i != 0);
                g.setColour(selected ? (i ? Colours::orange : theme::green).withAlpha(.55f)
                                     : theme::display);
                g.fillRoundedRectangle(r.toFloat(), 5);
                g.setColour(selected ? Colours::white : theme::secondary);
                g.setFont(theme::font(9));
                g.drawText(i ? (session.presentationTransport().subPlay.playing ? "Sub Play" : "Fila de espera")
                             : "Tocando / Selecionada",
                           r.removeFromTop(15), Justification::centred);
                g.setFont(theme::semiboldFont(12));
                g.drawFittedText(i ? queued.title() : current.title(), r.reduced(3, 1),
                                 Justification::centred, 2, .45f);
            }
        }
    }
    void resized() override {
        const int half = getWidth() / 2;
        for (auto *button : std::initializer_list<Button *>{&cancel, &currentTab, &queuedTab})
            button->setVisible(vertical);
        if (vertical) {
            cancel.setBounds(4, 4, getWidth() - 8, 26);
            currentTab.setBounds(4, 38, half - 6, 42);
            queuedTab.setBounds(half + 2, 38, getWidth() - half - 6, 42);
            current.setBounds(5, 85, getWidth() - 10, std::max(1, getHeight() - 90));
            queued.setBounds(current.getBounds());
            current.setVisible(!secondaryTab);
            queued.setVisible(secondaryTab);
        } else {
            current.setBounds(5, 5, half - 10, getHeight() - 10);
            queued.setBounds(half + 5, 5, getWidth() - half - 10, getHeight() - 10);
        }
        refresh();
    }
    void refresh() {
        current.refresh();
        queued.refresh();
        cancel.setEnabled(session.transport().queuedSectionMarkerId.has_value());
        if (vertical)
            repaint();
    }
    var diagnostics() const {
        auto result = object();
        put(result, "current", current.diagnostics());
        put(result, "queued", queued.diagnostics());
        put(result, "vertical", vertical);
        put(result, "secondaryTab", secondaryTab);
        return result;
    }

  private:
    class Bank final : public Component {
      public:
        Bank(PartsPanel &owner, bool second) : panel(owner), secondary(second) {
            addAndMakeVisible(view);
            view.setViewedComponent(&content, false);
            view.setScrollBarsShown(true, false);
            view.setScrollBarThickness(8);
        }
        ~Bank() override { view.setViewedComponent(nullptr, false); }
        String title() const { return name; }
        void paint(Graphics &g) override {
            if (panel.vertical)
                return;
            g.setFont(theme::semiboldFont(11));
            g.setColour(theme::secondary);
            auto title = secondary ? (panel.session.presentationTransport().subPlay.playing
                                          ? String("Sub Play")
                                          : String::fromUTF8("Fila de espera"))
                                   : String::fromUTF8("Tocando / Selecionada");
            const int width = secondary ? 95 : 122;
            g.drawText(title, 0, 0, width, 17, Justification::centredLeft);
            g.setColour(Colours::white);
            g.drawText(name, width + 4, 0, getWidth() - width - 4, 17, Justification::centredLeft);
        }
        void resized() override {
            const int header = panel.vertical ? 0 : 20;
            view.setBounds(0, header, getWidth(), std::max(1, getHeight() - header));
            layout();
        }
        var diagnostics() const {
            auto result = object();
            put(result, "region", text(region));
            put(result, "count", buttons.size());
            Array<var> ids;
            for (const auto &marker : markers)
                ids.add(text(marker.id));
            put(result, "markers", ids);
            Array<var> pads;
            for (const auto *button : buttons) {
                auto pad = object();
                put(pad, "progress", button->progress);
                put(pad, "queued", button->queued);
                put(pad, "active", button->active);
                pads.add(pad);
            }
            put(result, "pads", pads);
            return result;
        }
        void refresh() {
            const auto *song = panel.session.song();
            const auto state = panel.session.presentationTransport();
            const bool compensated = panel.session.audio.presentationLatencyFrames() != 0;
            const auto at = [&](double position) -> const jaras::Part * {
                const jaras::Part *best = nullptr;
                if (song)
                    for (const auto &p : song->parts)
                        if (position >= p.startTime && position < p.endTime) {
                            if (!best || (p.parentRegionID && !best->parentRegionID) ||
                                (p.parentRegionID.has_value() == best->parentRegionID.has_value() &&
                                 (p.startTime > best->startTime ||
                                  (p.startTime == best->startTime && p.endTime < best->endTime))))
                                best = &p;
                        }
                return best;
            };
            const auto byID = [&](const std::optional<ID> &id) -> const jaras::Part * {
                if (id && song)
                    for (const auto &p : song->parts)
                        if (p.id == *id)
                            return &p;
                return nullptr;
            };
            const auto *part = secondary
                                   ? (state.subPlay.playing ? at(state.subPlay.position)
                                                            : byID(state.queuedRegionId))
                                   : (state.playing ? (compensated && song ? partsPresentation::region(*song, state)
                                                                                       : panel.session.core.sectionPlaybackRegion())
                                                    : byID(panel.session.focusedRegion ? panel.session.focusedRegion : state.regionId));
            if (!secondary && !part)
                part = at(state.editPosition);
            std::vector<jaras::TimelineMarker> next;
            if (part) {
                jaras::TimelineMarker start;
                start.id = part->id;
                start.name = "INÍCIO";
                start.position = part->startTime;
                next.push_back(start);
                if (song->markers)
                    for (const auto &marker : *song->markers)
                        if (marker.section.value_or(false) && !marker.tempoBPM &&
                            marker.position >= part->startTime && marker.position <= part->endTime)
                            next.push_back(marker);
                std::sort(next.begin() + 1, next.end(), [](const auto &a, const auto &b) {
                    return a.position == b.position ? a.id < b.id : a.position < b.position;
                });
            }
            bool changed = next.size() != markers.size();
            if (!changed)
                for (size_t i = 0; i < next.size(); ++i)
                    if (next[i].id != markers[i].id || next[i].name != markers[i].name ||
                        next[i].position != markers[i].position) {
                        changed = true;
                        break;
                    }
            region = part ? part->id : ID{};
            name = part ? text(part->name) : String::fromUTF8("—");
            markers = std::move(next);
            if (changed) {
                buttons.clear();
                for (const auto &marker : markers) {
                    auto *button = buttons.add(new Pad(panel, marker.id));
                    content.addAndMakeVisible(button);
                }
                layout();
            }
            const double position = secondary       ? state.subPlay.position
                                    : state.playing ? state.position
                                                    : state.editPosition;
            const bool running = secondary ? state.subPlay.playing : state.playing;
            int active = -1;
            const double regionEnd = part ? (!secondary && state.playing
                ? (compensated ? partsPresentation::end(*part, state) : state.ignoreNextEnd.value_or(part->endTime))
                : part->endTime) : 0;
            std::optional<double> trigger;
            if (state.queuedSectionMarkerId) {
                if (!compensated) trigger = panel.session.core.nextSectionTrigger();
                else if (song)
                    if (const auto *audiblePart = partsPresentation::region(*song, state))
                        trigger = partsPresentation::trigger(*song, *audiblePart, state);
            }
            if (part && position < regionEnd && (!secondary || state.subPlay.playing))
                for (size_t i = 0; i < markers.size(); ++i)
                    if (markers[i].position <= position)
                        active = (int)i;
            for (int i = 0; i < buttons.size(); ++i) {
                auto &button = *buttons[i];
                button.label = unicodeCase(text(markers[(size_t)i].name));
                button.start = i == 0;
                button.active = active == i;
                button.queued = state.queuedSectionMarkerId == markers[(size_t)i].id;
                button.selected = button.queued || (!state.queuedSectionMarkerId && button.active);
                double end = regionEnd;
                for (const auto &marker : markers)
                    if (marker.position > markers[(size_t)i].position) {
                        end = std::min(end, marker.position);
                        break;
                    }
                if (button.queued && trigger && state.playing)
                    button.progress = jlimit(0., 1., (*trigger - state.position) /
                        std::max(.001, *trigger - state.sectionQueueStartedAt));
                else
                    button.progress = running && button.active && !button.queued
                        ? jlimit(0., 1., (position - markers[(size_t)i].position) /
                            std::max(.001, end - markers[(size_t)i].position)) : 0;
                button.repaint();
            }
            repaint();
        }

      private:
        class Pad final : public Button {
          public:
            Pad(PartsPanel &owner, ID target)
                : Button("part"), panel(owner), id(std::move(target)) {
                setWantsKeyboardFocus(false);
                onClick = [this] {
                    try {
                        panel.session.command(jaras::CommandKind::queueSection, id);
                    } catch (const std::exception &e) {
                        panel.error(String::fromUTF8(e.what()));
                    }
                };
            }
            String label;
            bool start = false, active = false, queued = false, selected = false;
            double progress = 0;
            void paintButton(Graphics &g, bool over, bool down) override {
                auto bounds = getLocalBounds().toFloat().reduced(.8f);
                g.setColour(selected ? theme::green.withAlpha(.35f)
                            : start  ? Colour(0xff007aff).withAlpha(.4f)
                                     : theme::display);
                g.fillRoundedRectangle(bounds, 5);
                if (over || down) {
                    g.setColour(Colours::white.withAlpha(down ? .12f : .06f));
                    g.fillRoundedRectangle(bounds, 5);
                }
                if (progress > 0) {
                    Graphics::ScopedSaveState saved(g);
                    Path clip; clip.addRoundedRectangle(bounds, 5);
                    g.reduceClipRegion(clip);
                    g.setColour(queued ? theme::yellow : theme::green);
                    g.fillRect(0.f, (float)getHeight() - 5, (float)(getWidth() * progress), 5.f);
                }
                g.setColour(selected ? theme::green : start ? Colour(0xff007aff) : theme::line);
                g.drawRoundedRectangle(bounds, 5, selected || start ? 1.5f : .5f);
                g.setColour(Colours::white);
                g.setFont(start ? theme::semiboldFont(16) : theme::semiboldFont(12));
                g.drawFittedText((queued ? String::fromUTF8("↰ ") : String()) + label,
                                 getLocalBounds().reduced(3, 0), Justification::centred, 2, .35f);
            }
            void mouseDown(const MouseEvent &event) override {
                if (event.mods.isPopupMenu()) {
                    try {
                        panel.session.command(jaras::CommandKind::cancelSection);
                    } catch (const std::exception &e) {
                        panel.error(String::fromUTF8(e.what()));
                    }
                } else
                    Button::mouseDown(event);
            }

          private:
            PartsPanel &panel;
            ID id;
        };
        PartsPanel &panel;
        bool secondary;
        Viewport view;
        Component content;
        OwnedArray<Pad> buttons;
        std::vector<jaras::TimelineMarker> markers;
        ID region;
        String name;
        void layout() {
            const int columns = panel.vertical ? 1 : 6;
            const int width = std::max(1, view.getWidth() - 8),
                      cell = std::max(1, (width - 4 * (columns - 1)) / columns);
            content.setSize(
                width, std::max(view.getHeight(), ((buttons.size() + columns - 1) / columns) * 38));
            for (int i = 0; i < buttons.size(); ++i)
                buttons[i]->setBounds((i % columns) * (cell + 4), (i / columns) * 38, cell, 34);
        }
    };
    Session &session;
    std::function<void(String)> error;
    bool vertical = false, secondaryTab = false;
    // Tab faces are painted by the panel so their two font sizes match the Mac.
    struct Tab final : public TextButton {
        void paintButton(Graphics &, bool, bool) override {}
    } currentTab, queuedTab;
    class CancelButton final : public TextButton {
      public:
        CancelButton() : TextButton("Cancel") {}
        void paintButton(Graphics &g, bool, bool down) override {
            // SmoothSeekPanel uses a plain button with an explicit yellow
            // background, including when no jump is queued. Do not apply the
            // generic disabled-button opacity, which turns it olive on Windows.
            g.setColour(Colour(0xffffd600));
            g.fillRoundedRectangle(getLocalBounds().toFloat(), 4);
            if (down && isEnabled()) {
                g.setColour(Colours::black.withAlpha(.1f));
                g.fillRoundedRectangle(getLocalBounds().toFloat(), 4);
            }
            g.setColour(Colours::black);
            g.setFont(theme::semiboldFont(12));
            g.drawText(getButtonText(), getLocalBounds(), Justification::centred);
        }
    } cancel;
    Bank current, queued;
    void timerCallback() override {
        if (isShowing())
            refresh();
    }
};
} // namespace catlive
