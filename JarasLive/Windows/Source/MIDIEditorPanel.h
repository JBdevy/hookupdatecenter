#pragma once
#include "Session.h"
#include "MIDIEditing.h"
#include "EditorShortcuts.h"
namespace catlive {
class MIDIEditorPanel final : public Component, private Timer {
  public:
    MIDIEditorPanel(Session &value, ID item, std::function<void(ID)> effects,
                    std::function<void(String)> failure)
        : session(value), itemID(std::move(item)), projectID(session.project().id),
          openEffects(std::move(effects)), error(std::move(failure)), canvas(*this) {
        for (auto *button : {&fx, &undo, &redo, &play, &quantize, &applyVelocity})
            addAndMakeVisible(button);
        for (auto *box : {&division, &mode, &channel})
            addAndMakeVisible(box);
        for (auto *slider : {&zoom, &swing, &velocity})
            addAndMakeVisible(slider);
        addAndMakeVisible(canvas);
        undo.setButtonText({});
        redo.setButtonText({});
        undo.setTooltip("Desfazer (Ctrl+Z)");
        redo.setTooltip("Refazer (Ctrl+Shift+Z)");
        undo.getProperties().set("icon", "undo");
        redo.getProperties().set("icon", "redo");
        for (int d : {1, 2, 4, 8, 16, 32, 64, 128})
            division.addItem(d == 1 ? "1" : "1/" + String(d), d);
        mode.addItemList({"Straight", "Triplet", "Dotted", "Swing"}, 1);
        channel.addItem("Todos os canais", 1);
        for (int i = 1; i <= 16; ++i)
            channel.addItem("Canal " + String(i), i + 1);
        channel.setSelectedId(1, dontSendNotification);
        channel.onChange = [this] {
            canvas.filter = channel.getSelectedId() - 1;
            canvas.pruneSelection();
            canvas.repaint();
            repaint();
        };
        zoom.setRange(24, 360, 1);
        zoom.setValue(100, dontSendNotification);
        zoom.setSliderStyle(Slider::LinearHorizontal);
        zoom.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
        zoom.onValueChange = [this] {
            canvas.scale = zoom.getValue();
            canvas.updateRanges();
        };
        swing.setRange(0, .95, .01);
        swing.setSliderStyle(Slider::LinearHorizontal);
        swing.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
        velocity.setRange(1, 127, 1);
        velocity.setValue(100, dontSendNotification);
        velocity.setSliderStyle(Slider::IncDecButtons);
        velocity.setTextBoxStyle(Slider::TextBoxLeft, false, 34, 22);
        division.onChange = [this] { changeGrid(); };
        mode.onChange = [this] { changeGrid(); };
        swing.onDragEnd = [this] { changeGrid(); };
        fx.onClick = [this] {
            if (!trackID.empty())
                openEffects(trackID);
        };
        undo.onClick = [this] {
            guarded([&] { session.undo(); });
            refresh();
        };
        redo.onClick = [this] {
            guarded([&] { session.redo(); });
            refresh();
        };
        play.onClick = [this] {
            guarded([&] {
                session.command(session.transport().playing ? jaras::CommandKind::pause
                                                            : jaras::CommandKind::play);
            });
        };
        applyVelocity.onClick = [this] {
            if (!clip)
                return;
            auto next = *clip->midi;
            for (auto &note : next.notes)
                if (canvas.selected.count(note.id) && canvas.visible(note))
                    note.velocity = (int)velocity.getValue();
            commit(next);
        };
        quantize.onClick = [this] { openQuantize(); };
        refresh();
        startTimerHz(20);
    }
    void resized() override {
        auto top = getLocalBounds().removeFromTop(42).reduced(10, 8);
        play.setBounds(top.removeFromRight(64));
        top.removeFromRight(8);
        redo.setBounds(top.removeFromRight(28));
        top.removeFromRight(6);
        undo.setBounds(top.removeFromRight(28));
        top.removeFromRight(8);
        fx.setBounds(top.removeFromRight(92));
        division.setBounds(54, 51, 78, 24);
        mode.setBounds(138, 51, 104, 24);
        swing.setBounds(252, 51, 82, 24);
        quantize.setBounds(mode.getSelectedId() == 4 ? 372 : 254, 51, 104, 24);
        zoom.setBounds(getWidth() - 124, 51, 110, 24);
        canvas.setBounds(0, 84, getWidth(), std::max(40, getHeight() - 147));
        const int y = getHeight() - 53;
        channel.setBounds(getWidth() - 226, y, 132, 24);
        applyVelocity.setBounds(getWidth() - 300, y, 64, 24);
        velocity.setBounds(getWidth() - 388, y, 78, 24);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::background);
        g.setFont(theme::font(13));
        g.setColour(Colours::white);
        g.drawText(trackName + "   " + (clip ? text(clip->name) : "Item MIDI removido"), 12, 8,
                   getWidth() - 280, 26, Justification::centredLeft);
        g.setColour(theme::secondary);
        g.drawHorizontalLine(42, 0, (float)getWidth());
        g.drawText("Grade", 10, 51, 44, 24, Justification::centredLeft);
        g.drawText("Zoom", getWidth() - 168, 51, 40, 24, Justification::centredLeft);
        if (mode.getSelectedId() == 4)
            g.drawText(String((int)(swing.getValue() * 100)) + "%", 334, 51, 34, 24,
                       Justification::centred);
        g.setFont(theme::font(11));
        g.drawText("Shift: mover e redimensionar sem encaixe", 10, getHeight() - 53,
                   std::max(0, getWidth() - 462), 24, Justification::centredLeft);
        g.drawText("Velocity", getWidth() - 443, getHeight() - 53, 52, 24,
                   Justification::centredLeft);
        g.drawText(String(clip ? (int)clip->midi->notes.size() : 0) + " notas", getWidth() - 90,
                   getHeight() - 53, 80, 24, Justification::centredRight);
        g.drawText(clip && clip->frozenMIDI.value_or(false)
                       ? "Item congelado: descongele antes de editar as notas."
                       : "Escolha um instrumento no FX da pista para ouvir as notas.",
                   10, getHeight() - 25, getWidth() - 20, 20, Justification::centred);
    }
    bool keyPressed(const KeyPress &key) override {
        if (retryEditorShortcut(key))
            return true;
        return canvas.keyPressed(key);
    }

  private:
    Session &session;
    ID itemID, projectID, trackID;
    String trackName;
    std::optional<jaras::AudioClip> clip;
    uint64 revision = ~uint64(0);
    std::function<void(ID)> openEffects;
    std::function<void(String)> error;
    TextButton fx{"FX da pista"}, undo{String::fromUTF8("↶")}, redo{String::fromUTF8("↷")},
        play{"Play"}, quantize{String::fromUTF8("Quantizar…")}, applyVelocity{"Aplicar"};
    ComboBox division, mode, channel;
    Slider zoom, swing, velocity;
    bool editable() const {
        return clip && !clip->frozenMIDI.value_or(false) && !session.busy &&
               !session.transport().playing && !session.transport().subPlay.playing &&
               !session.audio.isRecording() && session.project().id == projectID;
    }
    void guarded(const std::function<void()> &work) {
        try {
            work();
        } catch (const std::exception &e) {
            error(String::fromUTF8(e.what()));
        }
    }
    bool commit(const jaras::MIDIItem &next) {
        if (!editable()) {
            refresh();
            return false;
        }
        bool applied = false;
        guarded([&] {
            if (session.revision != revision)
                throw std::runtime_error("O projeto mudou durante a edição. Tente novamente.");
            session.edit([&](jaras::Project &p) { midiEditing::replace(p, itemID, next); });
            applied = true;
        });
        refresh();
        return applied;
    }
    void changeGrid() {
        if (!clip)
            return;
        auto next = *clip->midi;
        next.division = division.getSelectedId();
        next.mode =
            std::array<std::string, 4>{"straight", "triplet", "dotted",
                                       "swing"}[(size_t)jlimit(0, 3, mode.getSelectedId() - 1)];
        next.swing = swing.getValue();
        commit(next);
    }
    void refresh() {
        revision = session.revision;
        clip.reset();
        if (session.project().id == projectID)
            for (const auto &song : session.project().songs)
                for (const auto &track : song.tracks)
                    for (const auto &item : track.clips)
                        if (item.id == itemID && item.midi) {
                            clip = item;
                            trackID = track.id;
                            trackName = text(track.name);
                        }
        if (clip) {
            division.setSelectedId(clip->midi->division, dontSendNotification);
            mode.setSelectedId(clip->midi->mode == "triplet"  ? 2
                               : clip->midi->mode == "dotted" ? 3
                               : clip->midi->mode == "swing"  ? 4
                                                              : 1,
                               dontSendNotification);
            swing.setValue(clip->midi->swing, dontSendNotification);
        }
        swing.setVisible(mode.getSelectedId() == 4);
        canvas.sync();
        resized();
        repaint();
    }
    void timerCallback() override {
        if (revision != session.revision && !canvas.dragging())
            refresh();
        const bool enabled = editable();
        for (auto *component : std::initializer_list<Component *>{&division, &mode, &swing,
                                                                  &quantize, &applyVelocity})
            component->setEnabled(enabled);
        applyVelocity.setEnabled(enabled && !canvas.selected.empty());
        undo.setEnabled(session.canUndo() && enabled);
        redo.setEnabled(session.canRedo() && enabled);
        play.setButtonText(session.transport().playing ? "Pausar" : "Play");
        canvas.repaint();
    }
    void openQuantize() {
        if (!editable())
            return;
        class Options final : public Component {
          public:
            Options(std::function<void(double, bool)> apply) {
                addAndMakeVisible(strength);
                addAndMakeVisible(ends);
                addAndMakeVisible(ok);
                addAndMakeVisible(cancel);
                strength.setRange(0, 100, 1);
                strength.setValue(100, dontSendNotification);
                strength.setTextValueSuffix("%");
                strength.setSliderStyle(Slider::LinearHorizontal);
                strength.setTextBoxStyle(Slider::TextBoxRight, false, 50, 24);
                auto close = [this] {
                    if (auto *box = findParentComponentOfClass<CallOutBox>())
                        box->dismiss();
                };
                ok.onClick = [this, apply, close] {
                    apply(strength.getValue() / 100., ends.getToggleState());
                    close();
                };
                cancel.onClick = close;
                setSize(340, 160);
            }
            void paint(Graphics &g) override {
                g.setColour(Colours::white);
                g.setFont(theme::font(13, true));
                g.drawText("Quantizar notas selecionadas", 16, 8, 310, 28,
                           Justification::centredLeft);
            }
            void resized() override {
                strength.setBounds(16, 42, 308, 26);
                ends.setBounds(16, 78, 310, 26);
                cancel.setBounds(16, 120, 85, 26);
                ok.setBounds(239, 120, 85, 26);
            }

          private:
            Slider strength;
            ToggleButton ends{String::fromUTF8("Quantizar também o final das notas")};
            TextButton ok{"Aplicar"}, cancel{"Cancelar"};
        };
        const auto safe = SafePointer<MIDIEditorPanel>(this);
        CallOutBox::launchAsynchronously(
            std::make_unique<Options>([safe](double amount, bool ends) {
                if (!safe || !safe->clip)
                    return;
                auto next = *safe->clip->midi;
                auto chosen = safe->canvas.selected;
                if (chosen.empty())
                    for (const auto &note : next.notes)
                        if (safe->canvas.visible(note))
                            chosen.insert(note.id);
                midiEditing::quantize(next, chosen, amount, ends);
                safe->commit(next);
            }),
            quantize.getScreenBounds(), nullptr);
    }
    class Canvas final : public Component, private ScrollBar::Listener {
      public:
        explicit Canvas(MIDIEditorPanel &owner) : p(owner), horizontal(false), vertical(true) {
            setWantsKeyboardFocus(true);
            addAndMakeVisible(horizontal);
            addAndMakeVisible(vertical);
            horizontal.addListener(this);
            vertical.addListener(this);
        }
        double scale = 100;
        int filter = 0;
        std::set<ID> selected;
        bool dragging() const { return gesture != 0; }
        bool visible(const jaras::MIDINote &note) const {
            return filter == 0 || note.channel == filter;
        }
        void pruneSelection() {
            std::set<ID> keep;
            for (const auto &note : draft.notes)
                if (visible(note) && selected.count(note.id))
                    keep.insert(note.id);
            selected = std::move(keep);
        }
        void sync() {
            gesture = 0;
            draft = p.clip ? *p.clip->midi : jaras::MIDIItem{};
            pruneSelection();
            if (!centred && getHeight() > 100) {
                int low = 127, high = 0;
                for (const auto &note : draft.notes) {
                    low = std::min(low, note.pitch);
                    high = std::max(high, note.pitch);
                }
                const double pitch = draft.notes.empty() ? 60. : (low + high) * .5;
                yOffset = std::max(0., (127 - pitch) * 18 + 9 - (getHeight() - 36) * .5);
                centred = true;
            }
            updateRanges();
        }
        void resized() override {
            horizontal.setBounds(64, getHeight() - 12, std::max(0, getWidth() - 76), 12);
            vertical.setBounds(getWidth() - 12, 24, 12, std::max(0, getHeight() - 36));
            if (!centred)
                sync();
            else
                updateRanges();
        }
        void updateRanges() {
            double end = 16;
            if (p.clip)
                end = (p.clip->sourceOffset + p.clip->duration * p.clip->playbackRate) *
                      draft.sourceBPM / 60.;
            for (const auto &note : draft.notes)
                end = std::max(end, note.start + note.length);
            const double view = std::max(1, getWidth() - 76) / scale;
            horizontal.setRangeLimits(0, std::max(view, end + 4));
            horizontal.setCurrentRange(xOffset, view);
            xOffset = horizontal.getCurrentRangeStart();
            vertical.setRangeLimits(0, 128 * 18);
            vertical.setCurrentRange(yOffset, std::max(1, getHeight() - 36));
            yOffset = vertical.getCurrentRangeStart();
            repaint();
        }
        void paint(Graphics &g) override {
            g.fillAll(Colour(0xff242424));
            const auto content = area();
            {
                Graphics::ScopedSaveState save(g);
                g.reduceClipRegion(content);
                for (int pitch = 0; pitch < 128; ++pitch) {
                    const auto y = rowY(pitch);
                    if (y > content.getBottom() || y + 18 < 24)
                        continue;
                    g.setColour(Colour(black(pitch) ? 0xff1b1b1b : 0xff252525));
                    g.fillRect(64.f, y, (float)content.getWidth(), 18.f);
                    g.setColour(Colour(pitch % 12 == 0 ? 0xff525252 : 0xff333333));
                    g.drawHorizontalLine((int)y + 17, 64, (float)content.getRight());
                }
                const double gridStep = midiEditing::step(draft);
                const int first = std::max(0, (int)(xOffset / gridStep) - 2);
                const int last = first + (int)(content.getWidth() / scale / gridStep) + 5;
                const int stride = std::max(1, (int)std::ceil(4. / (gridStep * scale)));
                for (int i = first; i <= last; i += stride) {
                    const double beat = midiEditing::line(draft, i);
                    const bool bar = std::abs(beat / 4 - std::round(beat / 4)) < 1e-6;
                    g.setColour(theme::green.withAlpha(bar ? .48f : .18f));
                    g.drawVerticalLine((int)x(beat), 24, (float)content.getBottom());
                }
                for (const auto &note : draft.notes)
                    if (visible(note)) {
                        auto r = noteRect(note);
                        if (!r.intersects(content.toFloat()))
                            continue;
                        g.setColour(theme::green.withAlpha(
                            selected.count(note.id) ? 1.f : .55f + note.velocity / 127.f * .25f));
                        g.fillRoundedRectangle(r, 2);
                        if (selected.count(note.id)) {
                            g.setColour(Colours::white);
                            g.drawRect(r.reduced(.5f), 1);
                        }
                        if (r.getWidth() > 30) {
                            g.setColour(Colours::black);
                            g.setFont(theme::font(10));
                            g.drawText(String(note.pitch), r.reduced(4, 0),
                                       Justification::centredLeft);
                        }
                    }
                if (p.clip) {
                    const double begin = p.clip->sourceOffset * draft.sourceBPM / 60.;
                    const double end =
                        begin + p.clip->duration * p.clip->playbackRate * draft.sourceBPM / 60.;
                    g.setColour(Colours::yellow);
                    for (double beat : {begin, end})
                        g.drawVerticalLine((int)x(beat), 24, (float)content.getBottom());
                    const double cursor = begin + ((p.session.transport().playing
                                                        ? p.session.transport().position
                                                        : p.session.transport().editPosition) -
                                                   p.clip->startTime) *
                                                      p.clip->playbackRate * draft.sourceBPM / 60.;
                    g.setColour(theme::green);
                    g.drawVerticalLine((int)x(cursor), 24, (float)content.getBottom());
                }
                if (gesture == 5) {
                    g.setColour(theme::green.withAlpha(.15f));
                    g.fillRect(box);
                    g.setColour(theme::green);
                    g.drawRect(box);
                }
            }
            g.setFont(theme::font(10));
            for (int pitch = 0; pitch < 128; ++pitch) {
                const float y = rowY(pitch);
                if (y < 6 || y >= content.getBottom())
                    continue;
                g.setColour(Colour(black(pitch) ? 0xff191919 : 0xffc7c7c7));
                g.fillRect(0.f, std::max(24.f, y), 63.f, std::min(17.f, y + 17 - 24));
                if (pitch % 12 == 0 && y >= 24) {
                    g.setColour(Colours::black);
                    g.drawText("C" + String(pitch / 12 - 1), 30, (int)y + 1, 30, 16,
                               Justification::centredLeft);
                }
            }
            g.setColour(Colour(0xff171717));
            g.fillRect(0, 0, getWidth(), 24);
            g.setColour(theme::green);
            for (double beat = std::floor(xOffset / 4) * 4; x(beat) < content.getRight(); beat += 4)
                if (x(beat) >= 64)
                    g.drawText(String((int)(beat / 4) + 1), (int)x(beat) + 3, 2, 48, 20,
                               Justification::centredLeft);
        }
        void mouseDown(const MouseEvent &e) override {
            grabKeyboardFocus();
            if (!p.editable())
                return;
            origin = e.position;
            original = draft;
            anchor.clear();
            moved = false;
            if (e.y < 24 && e.x >= 64) {
                gesture = 6;
                return;
            }
            if (!area().contains(e.getPosition()))
                return;
            if (e.mods.isPopupMenu()) {
                gesture = 5;
                selected.clear();
                box = {};
                repaint();
                return;
            }
            for (auto it = draft.notes.rbegin(); it != draft.notes.rend(); ++it)
                if (visible(*it) && noteRect(*it).contains(e.position)) {
                    if (e.mods.isCtrlDown()) {
                        if (selected.count(it->id)) {
                            selected.erase(it->id);
                            gesture = 0;
                            repaint();
                            return;
                        }
                        selected.insert(it->id);
                    } else if (!selected.count(it->id))
                        selected = {it->id};
                    anchor = it->id;
                    const auto r = noteRect(*it);
                    const float edge = std::min(6.f, r.getWidth() / 3);
                    gesture = e.x <= r.getX() + edge ? 2 : e.x >= r.getRight() - edge ? 3 : 1;
                    repaint();
                    return;
                }
            jaras::MIDINote note{uuid(),
                                 midiEditing::snap(draft, beatAt(e.x), e.mods.isShiftDown()),
                                 midiEditing::step(draft),
                                 pitchAt(e.y),
                                 (int)p.velocity.getValue(),
                                 std::max(1, filter)};
            draft.notes.push_back(note);
            selected = {note.id};
            anchor = note.id;
            gesture = 4;
            repaint();
        }
        void mouseDrag(const MouseEvent &e) override {
            if (!gesture)
                return;
            moved = moved || e.getDistanceFromDragStart() > 3;
            if (gesture == 6)
                return;
            if (!p.editable()) {
                cancel();
                return;
            }
            if (gesture == 5) {
                box = juce::Rectangle<float>::leftTopRightBottom(
                    std::min(origin.x, e.position.x), std::min(origin.y, e.position.y),
                    std::max(origin.x, e.position.x), std::max(origin.y, e.position.y));
                selected.clear();
                for (const auto &note : draft.notes)
                    if (visible(note) && box.intersects(noteRect(note)))
                        selected.insert(note.id);
            } else if (gesture == 4) {
                auto &note = draft.notes.back();
                note.length = std::max(midiEditing::minimum,
                                       midiEditing::snap(draft, beatAt(e.x), e.mods.isShiftDown()) -
                                           note.start);
                note.pitch = pitchAt(e.y);
            } else {
                draft = original;
                auto found = std::find_if(original.notes.begin(), original.notes.end(),
                                          [&](const auto &n) { return n.id == anchor; });
                if (found == original.notes.end())
                    return;
                const double base = found->start + (gesture == 3 ? found->length : 0);
                const double delta = midiEditing::snap(draft, base + (e.x - origin.x) / scale,
                                                       e.mods.isShiftDown()) -
                                     base;
                midiEditing::transform(draft, selected, delta, pitchAt(e.y) - pitchAt(origin.y),
                                       gesture == 2   ? -1
                                       : gesture == 3 ? 1
                                                      : 0);
            }
            repaint();
            p.repaint();
        }
        void mouseUp(const MouseEvent &e) override {
            const int kind = gesture;
            gesture = 0;
            if (kind == 6 && !moved && p.clip) {
                const double source = midiEditing::snap(draft, beatAt(e.x), e.mods.isShiftDown()) *
                                      60. / draft.sourceBPM;
                const double time = jlimit(p.clip->startTime, p.clip->startTime + p.clip->duration,
                                           p.clip->startTime + (source - p.clip->sourceOffset) /
                                                                   p.clip->playbackRate);
                p.guarded([&] { p.session.command(jaras::CommandKind::editSeek, {}, time); });
            } else if (kind >= 1 && kind <= 4) {
                bool changed = draft.notes.size() != original.notes.size();
                if (!changed)
                    for (size_t i = 0; i < draft.notes.size(); ++i)
                        if (!midiEditing::equal(draft.notes[i], original.notes[i])) {
                            changed = true;
                            break;
                        }
                if (changed)
                    p.commit(draft);
            }
            repaint();
            p.repaint();
        }
        void mouseMove(const MouseEvent &e) override {
            MouseCursor cursor(MouseCursor::CrosshairCursor);
            for (const auto &note : draft.notes)
                if (visible(note) && noteRect(note).contains(e.position)) {
                    const auto r = noteRect(note);
                    const float edge = std::min(6.f, r.getWidth() / 3);
                    cursor = MouseCursor(e.x <= r.getX() + edge || e.x >= r.getRight() - edge
                                             ? MouseCursor::LeftRightResizeCursor
                                             : MouseCursor::DraggingHandCursor);
                    break;
                }
            setMouseCursor(cursor);
        }
        void mouseWheelMove(const MouseEvent &e, const MouseWheelDetails &d) override {
            if (e.mods.isCtrlDown())
                p.zoom.setValue(jlimit(24., 360., scale * std::pow(1.3, d.deltaY)));
            else if (e.mods.isShiftDown() || std::abs(d.deltaX) > std::abs(d.deltaY))
                horizontal.setCurrentRangeStart(
                    xOffset - (e.mods.isShiftDown() ? d.deltaY : d.deltaX) * 240 / scale);
            else
                vertical.setCurrentRangeStart(yOffset - d.deltaY * 240);
        }
        bool keyPressed(const KeyPress &key) override {
            if (!p.editable())
                return false;
            const int code = key.getKeyCode();
            if (code == KeyPress::escapeKey && gesture) {
                cancel();
                return true;
            }
            if (key.getModifiers().isCtrlDown() && (code == 'A' || code == 'a' || code == 1)) {
                selected.clear();
                for (const auto &note : draft.notes)
                    if (visible(note))
                        selected.insert(note.id);
                repaint();
                return true;
            }
            if (key.getModifiers().isCtrlDown() &&
                (code == 'Z' || code == 'z' || code == 26 || code == 'Y' || code == 25)) {
                cancel();
                p.guarded([&] {
                    if (code == 'Y' || code == 25 || key.getModifiers().isShiftDown())
                        p.session.redo();
                    else
                        p.session.undo();
                });
                p.refresh();
                return true;
            }
            if (code == KeyPress::deleteKey || code == KeyPress::backspaceKey) {
                if (selected.empty())
                    return true;
                auto next = draft;
                next.notes.erase(std::remove_if(next.notes.begin(), next.notes.end(),
                                                [&](const auto &n) {
                                                    return visible(n) && selected.count(n.id);
                                                }),
                                 next.notes.end());
                p.commit(next);
                return true;
            }
            return false;
        }

      private:
        MIDIEditorPanel &p;
        ScrollBar horizontal, vertical;
        double xOffset = 0, yOffset = 0;
        bool centred = false, moved = false;
        int gesture = 0;
        ID anchor;
        jaras::MIDIItem draft, original;
        Point<float> origin;
        juce::Rectangle<float> box;
        juce::Rectangle<int> area() const {
            return {64, 24, std::max(0, getWidth() - 76), std::max(0, getHeight() - 36)};
        }
        float x(double beat) const { return (float)(64 + (beat - xOffset) * scale); }
        float rowY(int pitch) const { return (float)(24 + (127 - pitch) * 18 - yOffset); }
        double beatAt(double x) const { return std::max(0., xOffset + (x - 64) / scale); }
        int pitchAt(double y) const {
            return jlimit(0, 127, 127 - (int)std::floor((y - 24 + yOffset) / 18));
        }
        static bool black(int pitch) {
            const int key = pitch % 12;
            return key == 1 || key == 3 || key == 6 || key == 8 || key == 10;
        }
        juce::Rectangle<float> noteRect(const jaras::MIDINote &note) const {
            return {x(note.start), rowY(note.pitch) + 1, (float)std::max(2., note.length * scale),
                    16};
        }
        void scrollBarMoved(ScrollBar *bar, double value) override {
            if (bar == &horizontal)
                xOffset = value;
            else
                yOffset = value;
            repaint();
        }
        void cancel() {
            gesture = 0;
            p.refresh();
        }
    } canvas;
};
} // namespace catlive
