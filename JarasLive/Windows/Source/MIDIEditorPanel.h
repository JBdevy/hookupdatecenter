#pragma once
#include "Localization.h"
#include "Session.h"
#include "MIDIEditing.h"
#include "EditorShortcuts.h"
#include "ClickProgram.h"
#include "LibraryMIDIChords.h"
namespace catlive {
inline void drawPianoNoteLabel(Graphics& g, juce::Rectangle<float> bounds, int pitch, int velocity) {
    if (bounds.getWidth() <= 14 || bounds.getHeight() < 11) return;
    static constexpr const char* names[]{"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"};
    static std::map<int,std::pair<String,float>> labels;
    const int key = pitch * 128 + velocity;
    auto at = labels.find(key);
    const auto font = theme::font(10);
    if (at == labels.end()) {
        const String text = String(names[jlimit(0,127,pitch) % 12]) + String(pitch / 12 - 1) + " - " + String(velocity);
        at = labels.emplace(key,std::make_pair(text,std::ceil(GlyphArrangement::getStringWidth(font,text)))).first;
    }
    if (bounds.getWidth() < at->second.second + 6) return;
    Graphics::ScopedSaveState save(g);
    g.setColour(Colours::black);
    g.setFont(font);
    g.drawText(at->second.first,bounds.reduced(3,0),Justification::centredLeft,false);
}
class MIDIEditorPanel final : public Component, public DragAndDropTarget, private Timer {
  public:
    MIDIEditorPanel(Session &value, ID item,
                    std::function<void(String)> failure, bool followGrid = false)
        : followGrid(followGrid), session(value), itemID(std::move(item)), projectID(session.project().id),
          error(std::move(failure)), canvas(*this) {
        for (Component *control : std::initializer_list<Component*>{&editToolsViewport, &heightMemoryButton,
                 &zoomMemoryButton, &noteHeight, &zoom, &channel, &velocity, &canvas})
            addAndMakeVisible(control);
        editToolsViewport.setViewedComponent(&editTools, false);
        editToolsViewport.setScrollBarsShown(false, true);
        editToolsViewport.setScrollBarThickness(5);
        for (Component *control : std::initializer_list<Component*>{&gridLabel, &division, &mode, &swing,
                 &swingPercent, &quantize, &creationLabel, &creationVelocity})
            editTools.addAndMakeVisible(control);
        gridLabel.setText("Grade", dontSendNotification);
        creationLabel.setText("Create Velocity", dontSendNotification);
        for (auto *label : {&gridLabel, &creationLabel, &swingPercent}) {
            label->setFont(theme::font(13));
            label->setColour(Label::textColourId, theme::secondary);
            label->setInterceptsMouseClicks(false, false);
        }
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
        configureZoomSlider(zoom, "timelineZoomAxis", "piano-time-zoom-slider", "Piano Roll zoom", 24, 360, 100);
        configureZoomSlider(noteHeight, "trackHeightAxis", "piano-note-height-slider", "Note height", 10, 42, 18);
        zoom.setSkewFactorFromMidPoint(std::sqrt(zoom.getMinimum() * zoom.getMaximum()));
        configureZoomMemory(zoomMemoryButton, zoom, zoomMemory, "fitTime", "piano-time-zoom-memory", "Toggle Piano Roll zoom");
        configureZoomMemory(heightMemoryButton, noteHeight, heightMemory, "fitTracks", "piano-note-height-memory", "Toggle note height");
        zoom.onValueChange = [this] {
            if (zoom.getValue() > zoom.getMinimum()) {
                zoomMemory.reset();
                zoomMemoryButton.setToggleState(false, dontSendNotification);
            }
            canvas.scale = zoom.getValue();
            canvas.updateRanges();
        };
        noteHeight.onValueChange = [this] {
            if (noteHeight.getValue() > noteHeight.getMinimum()) {
                heightMemory.reset();
                heightMemoryButton.setToggleState(false, dontSendNotification);
            }
            canvas.setKeyHeight(noteHeight.getValue());
        };
        swing.setRange(0, .95, .01);
        swing.setSliderStyle(Slider::LinearHorizontal);
        swing.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
        for (auto *selector : {&velocity, &creationVelocity}) {
            selector->setRange(1, 127, 1);
            selector->setValue(100, dontSendNotification);
            selector->setSliderStyle(Slider::IncDecButtons);
            selector->setTextBoxStyle(Slider::TextBoxLeft, false, 34, 22);
        }
        creationVelocity.setTitle("Create Velocity");
        creationVelocity.setTooltip(creationVelocity.getTitle());
        creationVelocity.setComponentID("piano-new-note-velocity");
        velocity.setComponentID("piano-selected-note-velocity");
        division.onChange = [this] { changeGrid(); };
        mode.onChange = [this] { changeGrid(); };
        swing.onDragEnd = [this] { changeGrid(); };
        swing.onValueChange = [this] { updateSwingLabel(); };
        velocity.textFromValueFunction = [this](double value) {
            return mixedVelocity && int(value) == velocityReference ? String("-") : String(int(value));
        };
        velocity.valueFromTextFunction = [this](const String& input) -> double {
            const auto digits = input.trim();
            const int value = digits.getIntValue();
            if (!digits.containsOnly("0123456789") || value < 1 || value > 127) return velocity.getValue();
            if (mixedVelocity && value == int(velocity.getValue())) setSelectedVelocity(value);
            return value;
        };
        velocity.onValueChange = [this] { setSelectedVelocity(int(velocity.getValue())); };
        quantize.onClick = [this] { openQuantize(); };
        refresh();
        startTimerHz(20);
    }
    bool isInterestedInDragSource(const SourceDetails& source) override {
        return editable() && str(source.description,"type") == "catlive-midi-chord";
    }
    void itemDropped(const SourceDetails& source) override {
        if (!isInterestedInDragSource(source) || !pianoBounds().contains(source.localPosition)) return;
        const auto* chord = libraryChords::find(str(source.description,"name"));
        if (!chord || !timing || !session.song()) return;
        const auto cursor = session.transport().editPosition;
        if (cursor < clip->startTime || cursor >= clip->startTime + clip->duration) return;
        const auto meter = ClickProgram::meterAt(*session.song(),cursor);
        const auto barSeconds = 60. / meter.bpm * meter.beats * 4. / meter.unit;
        auto next = *clip->midi;
        const auto start = timing->sourceAt(cursor) * next.sourceBPM / 60.;
        const auto length = timing->sourceAt(cursor + barSeconds) * next.sourceBPM / 60. - start;
        std::set<ID> added;
        for (const auto& interval : list(get(*chord,"intervals"))) {
            jaras::MIDINote note{uuid(),start,length,48 + int(interval),int(creationVelocity.getValue()),std::max(1,canvas.filter)};
            added.insert(note.id);
            next.notes.push_back(note);
        }
        if (!added.empty() && commit(next)) {
            canvas.selected = std::move(added);
            canvas.repaint();
        }
    }
    struct PreviewGeometry { double left=0, pixelsPerSecond=1, topPitch=0, height=18; int keys=42, ruler=16; };
    PreviewGeometry previewGeometry;
    bool editsPreview() const { return followGrid && editable(); }
    void drawPreviewNotes(Graphics& g) { canvas.drawNotes(g, canvas.area()); }
    Component& previewInput() { return canvas; }
    MouseCursor previewCursor(juce::Point<float> point) const { return canvas.cursorAt(point); }
    bool hasPreviewNote(juce::Point<float> point) const { return canvas.noteAt(point) != nullptr; }
    juce::Rectangle<int> pianoBounds() const { return canvas.getBounds(); }
    void setPreviewZoom(double value) { zoom.setValue(value,sendNotificationSync); }
    void setPreviewHeight(double value) { noteHeight.setValue(value,sendNotificationSync); }
    double previewZoom() const { return zoom.getValue(); }
    double previewKeyHeight() const { return noteHeight.getValue(); }
    void setPreviewItem(const ID &id) {
        if (id == itemID && projectID == session.project().id) return;
        projectID = session.project().id;
        itemID = id;
        canvas.selected.clear();
        refresh();
    }
    const String& trackTitle() const { return trackName; }
    void resized() override {
        const bool compact = followGrid && getHeight() < 170;
        const int top = compact ? 0 : 5;
        const int rightTools = std::max(0, getWidth() - 10 - 189);
        heightMemoryButton.setBounds(rightTools, top, 24, 24);
        zoomMemoryButton.setBounds(rightTools + 24, top, 24, 24);
        noteHeight.setBounds(rightTools + 53, top, 68, 24);
        zoom.setBounds(noteHeight.getRight(), top, 68, 24);
        int x = 0;
        const auto place = [&](Component& control, int width) {
            control.setBounds(x, 0, width, 24);
            x += width + 6;
        };
        place(gridLabel, 40);
        place(division, 78);
        place(mode, 104);
        if (mode.getSelectedId() == 4) {
            place(swing, 82);
            place(swingPercent, 38);
        }
        place(quantize, 104);
        place(creationLabel, 100);
        place(creationVelocity, 78);
        editTools.setSize(x - 6, 24);
        editToolsViewport.setBounds(10, top, std::max(0, rightTools - 18), 30);
        const int gridTop = top + editToolsViewport.getHeight() + 3;
        const int footer = compact ? 25 : 63;
        canvas.setBounds(0, gridTop, getWidth(), std::max(0, getHeight() - gridTop - footer));
        const int y = std::max(0, getHeight() - (compact ? 24 : 53));
        channel.setBounds(getWidth() - 226, y, 132, 24);
        velocity.setBounds(channel.getX() - 88, y, 78, 24);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::background);
        g.setColour(theme::secondary);
        g.drawHorizontalLine(canvas.getY() - 1, 0, (float)getWidth());
        const auto memoryBounds = heightMemoryButton.getBounds().getUnion(zoomMemoryButton.getBounds());
        const auto sliderBounds = noteHeight.getBounds().getUnion(zoom.getBounds());
        g.setColour(Colour(0xff4c4c4c)); g.fillRoundedRectangle(memoryBounds.toFloat(), 4.f);
        g.setColour(Colour(0xff343434)); g.fillRoundedRectangle(sliderBounds.toFloat(), 4.f);
        g.setColour(Colour(0xff393939)); g.drawVerticalLine(zoomMemoryButton.getX(), float(memoryBounds.getY()+1), float(memoryBounds.getBottom()-1));
        g.setColour(Colour(0xff242424)); g.drawVerticalLine(zoom.getX(), float(sliderBounds.getY()+1), float(sliderBounds.getBottom()-1));
        g.setColour(theme::secondary);
        g.setFont(theme::font(11));
        g.drawText("Shift: mover e redimensionar sem encaixe", 10, velocity.getY(),
                   std::max(0, velocity.getX() - 70), 24, Justification::centredLeft);
        g.drawText("Velocity", velocity.getX() - 56, velocity.getY(), 52, 24,
                   Justification::centredLeft);
        g.drawText(String(clip ? (int)clip->midi->notes.size() : 0) + " notas", getWidth() - 90,
                   velocity.getY(), 80, 24, Justification::centredRight);
        if (clip && clip->frozenMIDI.value_or(false))
            g.drawText("Item congelado: descongele antes de editar as notas.", 10, getHeight() - 25, getWidth() - 20, 20, Justification::centred);
    }
    bool keyPressed(const KeyPress &key) override {
        // Text fields own their editing history, even when it is empty.
        // Never let a declined text shortcut undo the project behind the field.
        if (dynamic_cast<TextEditor *>(Component::getCurrentlyFocusedComponent()))
            return retryEditorShortcut(key);
        return canvas.keyPressed(key);
    }

  private:
    const bool followGrid;
    Session &session;
    ID itemID, projectID;
    String trackName;
    std::optional<jaras::AudioClip> clip;
    std::optional<ClipTempo> timing;
    uint64 revision = ~uint64(0), velocityRevision = 0;
    std::set<ID> lastVelocitySelection;
    bool mixedVelocity = false;
    int velocityReference = 100;
    void setSelectedVelocity(int value) {
        if (!editable() || canvas.selected.empty()) return;
        auto next = *clip->midi;
        bool changed = false;
        for (auto& note : next.notes) {
            if (canvas.selected.count(note.id) && canvas.visible(note) && note.velocity != value) {
                note.velocity = value;
                changed = true;
            }
        }
        if (changed) commit(next);
    }
    std::function<void(String)> error;
    Component editTools;
    Viewport editToolsViewport;
    Label gridLabel, creationLabel, swingPercent;
    TextButton quantize{String::fromUTF8("Quantizar…")};
    TextButton heightMemoryButton, zoomMemoryButton;
    ComboBox division, mode, channel;
    ParameterSlider zoom, noteHeight, swing, velocity, creationVelocity;
    std::optional<double> zoomMemory, heightMemory;
    static void configureZoomSlider(Slider &slider, const char *axis, const char *id, const char *title,
                                    double minimum, double maximum, double initial) {
        slider.setComponentID(id);
        slider.setTitle(localization::translate(title));
        slider.setTooltip(slider.getTitle());
        slider.getProperties().set("zoomAxis", axis);
        slider.setRange(minimum, maximum, 0);
        slider.setValue(initial, dontSendNotification);
        slider.setSliderStyle(Slider::LinearHorizontal);
        slider.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
    }
    static void configureZoomMemory(TextButton &button, Slider &slider, std::optional<double> &memory,
                                    const char *icon, const char *id, const char *title) {
        button.setComponentID(id);
        button.setTitle(localization::translate(title));
        button.setTooltip(button.getTitle());
        button.getProperties().set("icon", icon);
        button.getProperties().set("iconSize", 15.f);
        button.getProperties().set("zoomSegment", true);
        button.onClick = [&button, &slider, &memory] {
            if (memory) {
                const double target = *memory;
                memory.reset();
                button.setToggleState(false, dontSendNotification);
                slider.setValue(target, sendNotificationSync);
            } else if (slider.getValue() > slider.getMinimum()) {
                memory = slider.getValue();
                button.setToggleState(true, dontSendNotification);
                slider.setValue(slider.getMinimum(), sendNotificationSync);
            }
        };
    }
    bool editable() const {
        return clip && (!followGrid || (clip->startTime <= session.transport().editPosition &&
                                        session.transport().editPosition < clip->startTime + clip->duration)) &&
               !clip->frozenMIDI.value_or(false) && !session.busy &&
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
    void updateSwingLabel() {
        swingPercent.setText(String(roundToInt(swing.getValue() * 100)) + "%", dontSendNotification);
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
        trackName.clear();
        if (!itemID.empty() && session.project().id == projectID)
            for (const auto &song : session.project().songs)
                for (const auto &track : song.tracks)
                    for (const auto &item : track.clips)
                        if (item.id == itemID && item.midi) {
                            clip = item;
                            trackName = text(track.name);
                        }
        if (clip) {
            if (!followGrid)
                if (auto *window = findParentComponentOfClass<DocumentWindow>(); window && window->getName() != trackName)
                    window->setName(trackName);
            timing.emplace(*clip, session.song());
            division.setSelectedId(clip->midi->division, dontSendNotification);
            mode.setSelectedId(clip->midi->mode == "triplet"  ? 2
                               : clip->midi->mode == "dotted" ? 3
                               : clip->midi->mode == "swing"  ? 4
                                                              : 1,
                               dontSendNotification);
            swing.setValue(clip->midi->swing, dontSendNotification);
        } else timing.reset();
        swing.setVisible(mode.getSelectedId() == 4);
        swingPercent.setVisible(swing.isVisible());
        updateSwingLabel();
        canvas.sync();
        resized();
        repaint();
    }
    void timerCallback() override {
        if (revision != session.revision && !canvas.dragging())
            refresh();
        const bool enabled = editable();
        for (auto *component : std::initializer_list<Component *>{&division, &mode, &swing,
                                                                  &quantize})
            component->setEnabled(enabled);
        if (followGrid) {
            creationVelocity.setEnabled(enabled);
            channel.setEnabled(enabled);
            if (clip) canvas.followCursor();
        }
        velocity.setEnabled(enabled && !canvas.selected.empty());
        if (lastVelocitySelection != canvas.selected || velocityRevision != revision) {
            lastVelocitySelection = canvas.selected;
            velocityRevision = revision;
            std::optional<int> first;
            mixedVelocity = false;
            if (clip && !canvas.selected.empty()) {
                for (const auto& note : clip->midi->notes) if (canvas.selected.count(note.id)) {
                    if (!first) first = note.velocity;
                    else if (note.velocity != *first) { mixedVelocity = true; break; }
                }
            }
            velocityReference = first.value_or(100);
            velocity.setValue(velocityReference,dontSendNotification);
            velocity.updateText();
        }
        quantize.setEnabled(enabled && canvas.hasVisibleNotes());
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
            ParameterSlider strength;
            ToggleButton ends{String::fromUTF8("Quantizar também o final das notas")};
            TextButton ok{localization::translate("Quantizar")}, cancel{localization::translate("Cancelar")};
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
        bool hasVisibleNotes() const {
            return std::any_of(draft.notes.begin(), draft.notes.end(),
                               [this](const auto &note){ return visible(note); });
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
                yOffset = std::max(0., (127.5 - pitch) * keyHeight - (getHeight() - 36) * .5);
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
        void setKeyHeight(double value) {
            const double center = std::max(0, getHeight() - 36) * .5;
            yOffset = (yOffset + center) * value / keyHeight - center;
            keyHeight = value;
            updateRanges();
        }
        void followCursor() {
            const auto position = cursorBeat();
            if (!std::isfinite(previousCursor) || position != previousCursor) {
                previousCursor = position;
                xOffset = position - horizontal.getCurrentRangeSize() / 2;
                updateRanges();
            }
        }
        void updateRanges() {
            double end = 16;
            if (p.clip && p.timing)
                end = p.timing->sourceAt(p.clip->startTime + p.clip->duration) * draft.sourceBPM / 60.;
            for (const auto &note : draft.notes)
                end = std::max(end, note.start + note.length);
            const double view = std::max(1, getWidth() - 76) / scale;
            const double padding = p.followGrid ? view / 2 : 0;
            horizontal.setRangeLimits(-padding, std::max(view - padding, end + 4 + padding));
            horizontal.setCurrentRange(xOffset, view);
            xOffset = horizontal.getCurrentRangeStart();
            vertical.setRangeLimits(0, 128 * keyHeight);
            vertical.setCurrentRange(yOffset, std::max(1, getHeight() - 36));
            yOffset = vertical.getCurrentRangeStart();
            repaint();
        }
        void drawNotes(Graphics& g, juce::Rectangle<int> content) {
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
                        drawPianoNoteLabel(g,r,note.pitch,note.velocity);
                    }
            if (p.followGrid && gesture == 5) {
                g.setColour(theme::green.withAlpha(.18f)); g.fillRect(box);
            }
        }
        void paint(Graphics &g) override {
            g.fillAll(Colour(0xff242424));
            const auto content = area();
            {
                Graphics::ScopedSaveState save(g);
                g.reduceClipRegion(content);
                for (int pitch = 0; pitch < 128; ++pitch) {
                    const auto y = rowY(pitch);
                    if (y > content.getBottom() || y + keyHeight < 24)
                        continue;
                    g.setColour(Colour(black(pitch) ? 0xff1b1b1b : 0xff252525));
                    g.fillRect(64.f, y, (float)content.getWidth(), (float)keyHeight);
                    g.setColour(Colour(pitch % 12 == 0 ? 0xff525252 : 0xff333333));
                    g.drawHorizontalLine((int)(y + keyHeight - 1), 64, (float)content.getRight());
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
                drawNotes(g, content);
                if (p.clip && p.timing) {
                    const double begin = p.clip->sourceOffset * draft.sourceBPM / 60.;
                    const double end = p.timing->sourceAt(p.clip->startTime + p.clip->duration) * draft.sourceBPM / 60.;
                    g.setColour(Colours::yellow);
                    for (double beat : {begin, end})
                        g.drawVerticalLine((int)x(beat), 24, (float)content.getBottom());
                    const double cursor = cursorBeat();
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
                const float top = std::max(24.f, y);
                const float bottom = std::min((float)content.getBottom(), y + (float)keyHeight - 1);
                if (bottom <= top)
                    continue;
                g.setColour(Colour(black(pitch) ? 0xff191919 : 0xffc7c7c7));
                g.fillRect(0.f, top, 63.f, bottom - top);
                if (pitch % 12 == 0 && y >= 24 && keyHeight >= 13) {
                    g.setColour(Colours::black);
                    g.drawText("C" + String(pitch / 12 - 1), 30, (int)y, 30, (int)keyHeight,
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
            const float cursor = x(cursorBeat());
            if (p.timing && cursor >= 64 && cursor <= content.getRight()) {
                Path head;
                head.addTriangle(cursor-5, 0, cursor+5, 0, cursor, 7);
                g.fillPath(head);
            }
        }
        void mouseDown(const MouseEvent &e) override {
            if (!p.followGrid) grabKeyboardFocus();
            origin = e.position;
            original = draft;
            anchor.clear();
            moved = false;
            if (!p.followGrid && e.y < 24 && e.x >= 64 && e.mods.isLeftButtonDown() && p.clip && !p.session.busy) {
                gesture = 6;
                return;
            }
            if (!p.editable()) return;
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
            if (!e.mods.isLeftButtonDown() || e.getNumberOfClicks() != 2) {
                selected.clear();
                gesture = 5;
                box = {};
                repaint();
                return;
            }
            if (p.followGrid && p.clip) {
                const auto& v = p.previewGeometry;
                const double when = v.left+(e.x-v.keys)/v.pixelsPerSecond;
                if (when < p.clip->startTime || when >= p.clip->startTime+p.clip->duration) return;
            }
            jaras::MIDINote note{uuid(),
                                 midiEditing::snap(draft, beatAt(e.x), e.mods.isShiftDown()),
                                 midiEditing::step(draft),
                                 pitchAt(e.y),
                                 (int)p.creationVelocity.getValue(),
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
                const double delta = midiEditing::snap(draft, base + (p.followGrid ? beatAt(e.x)-beatAt(origin.x) : (e.x-origin.x)/scale),
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
            if (kind == 6 && !moved && p.clip && p.timing && !p.session.busy &&
                e.y >= 0 && e.y < 24 && e.x >= 64) {
                const double source = midiEditing::snap(draft, beatAt(e.x), e.mods.isShiftDown()) *
                                      60. / draft.sourceBPM;
                const double time = p.timing->timeAt(source);
                p.guarded([&] { p.session.command(p.session.transport().playing ? jaras::CommandKind::seek
                                                                              : jaras::CommandKind::editSeek, {}, time); });
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
        const jaras::MIDINote* noteAt(juce::Point<float> point) const {
            for (auto it = draft.notes.rbegin(); it != draft.notes.rend(); ++it)
                if (visible(*it) && noteRect(*it).contains(point)) return &*it;
            return nullptr;
        }
        MouseCursor cursorAt(juce::Point<float> point) const {
            const int keys = p.followGrid ? p.previewGeometry.keys : 64;
            const int ruler = p.followGrid ? p.previewGeometry.ruler : 24;
            if (point.x < keys) return MouseCursor::NormalCursor;
            if (point.y < ruler) return MouseCursor::PointingHandCursor;
            if (!p.editable()) return MouseCursor::NormalCursor;
            if (const auto* note = noteAt(point)) {
                const auto rect = noteRect(*note);
                const float edge = std::min(6.f, rect.getWidth() / 3);
                return point.x <= rect.getX() + edge || point.x >= rect.getRight() - edge
                    ? MouseCursor::LeftRightResizeCursor : MouseCursor::DraggingHandCursor;
            }
            return MouseCursor::CrosshairCursor;
        }
        void mouseMove(const MouseEvent &event) override { setMouseCursor(cursorAt(event.position)); }
        void mouseExit(const MouseEvent &) override { setMouseCursor(MouseCursor::NormalCursor); }
        void mouseWheelMove(const MouseEvent &e, const MouseWheelDetails &d) override {
            if (e.mods.isAltDown()) {
                vertical.setCurrentRangeStart(yOffset - d.deltaY * 300);
            } else if (e.mods.isCtrlDown()) {
                if (!d.isInertial) p.setPreviewHeight(keyHeight * std::pow(1.3,d.deltaY * 4));
            } else if (e.mods.isShiftDown() || e.mods.isLeftButtonDown() || std::abs(d.deltaX) > std::abs(d.deltaY)) {
                const auto delta = std::abs(d.deltaX) > std::abs(d.deltaY) ? d.deltaX : d.deltaY;
                horizontal.setCurrentRangeStart(xOffset - delta * 500 / scale);
            } else if (!d.isInertial && d.deltaY != 0) {
                const auto anchor = beatAt(std::max(64, e.x));
                p.zoom.setValue(scale * std::pow(1.3, d.deltaY * 4), sendNotificationSync);
                horizontal.setCurrentRangeStart(anchor - std::max(0, e.x - 64) / scale, sendNotificationSync);
            }
        }
        bool keyPressed(const KeyPress &key) override {
            if (!p.editable())
                return false;
            const int code = key.getKeyCode();
            if (code == KeyPress::escapeKey && gesture) {
                cancel();
                return true;
            }
            if (key.getModifiers().isCtrlDown() && !key.getModifiers().isAltDown() &&
                !key.getModifiers().isShiftDown() && (code == 'A' || code == 'a' || code == 1)) {
                selected.clear();
                for (const auto &note : draft.notes)
                    if (visible(note))
                        selected.insert(note.id);
                repaint();
                return true;
            }
            if (key.getModifiers().isCtrlDown() && !key.getModifiers().isAltDown() &&
                (code == 'Z' || code == 'z' || code == 26)) {
                cancel();
                p.guarded([&] {
                    if (key.getModifiers().isShiftDown())
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
        double xOffset = 0, yOffset = 0, keyHeight = 18;
        bool centred = false, moved = false;
        int gesture = 0;
        ID anchor;
        jaras::MIDIItem draft, original;
        Point<float> origin;
        juce::Rectangle<float> box;
        double previousCursor = std::numeric_limits<double>::quiet_NaN();
        double cursorBeat() const {
            return p.timing ? p.timing->sourceAt(p.session.transport().playing || p.session.transport().paused
                                                  ? p.session.transport().position
                                                  : p.session.transport().editPosition) * draft.sourceBPM / 60. : 0;
        }
      public:
        juce::Rectangle<int> area() const {
            if (p.followGrid) {
                const auto& v=p.previewGeometry;
                return {v.keys,v.ruler,std::max(0,getWidth()-v.keys-13),std::max(0,getHeight()-v.ruler-13)};
            }
            return {64,24,std::max(0,getWidth()-76),std::max(0,getHeight()-36)};
        }
      private:
        float x(double beat) const {
            if (p.followGrid && p.timing) {
                const auto& v=p.previewGeometry;
                return float(v.keys+(p.timing->timeAt(beat*60/draft.sourceBPM,false)-v.left)*v.pixelsPerSecond);
            }
            return float(64+(beat-xOffset)*scale);
        }
        float rowY(int pitch) const {
            const auto& v=p.previewGeometry;
            return p.followGrid ? float(v.ruler+(127-pitch-v.topPitch)*v.height) : float(24+(127-pitch)*keyHeight-yOffset);
        }
        double beatAt(double pos) const {
            if (p.followGrid && p.timing) {
                const auto& v=p.previewGeometry;
                return std::max(0.,p.timing->sourceAt(v.left+(pos-v.keys)/v.pixelsPerSecond)*draft.sourceBPM/60);
            }
            return std::max(0.,xOffset+(pos-64)/scale);
        }
        int pitchAt(double y) const {
            const auto& v=p.previewGeometry;
            const double row=p.followGrid ? (y-v.ruler)/v.height+v.topPitch : (y-24+yOffset)/keyHeight;
            return jlimit(0,127,127-int(std::floor(row)));
        }
        static bool black(int pitch) {
            const int key = pitch % 12;
            return key == 1 || key == 3 || key == 6 || key == 8 || key == 10;
        }
        juce::Rectangle<float> noteRect(const jaras::MIDINote &note) const {
            return {x(note.start), rowY(note.pitch) + 1, std::max(2.f,x(note.start+note.length)-x(note.start)),
                    (float)keyHeight - 2};
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
