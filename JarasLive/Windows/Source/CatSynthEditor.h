#pragma once
#include "ADSREnvelopeGraph.h"
#include "AudioEngine.h"
#include "CatSynthState.h"
#include "Appearance.h"

namespace catlive {
class CatSynthEditor final : public Component, public DragAndDropContainer, public DragAndDropTarget,
                             private MidiKeyboardState::Listener, private Timer {
  public:
    CatSynthEditor(AudioEngine &engine, ID target, String key, var saved, bool isEnabled,
                   std::function<void(var)> apply, std::function<void(bool)> applyEnabled)
        : audio(engine), track(std::move(target)), effect(std::move(key)), bank(synthState::bank(saved.clone())),
          store(std::move(apply)), keyboard(keys) {
        for (unsigned index = 0; index < presets.size(); ++index) {
            auto &button = presets[index];
            button.setButtonText(String(index + 1).paddedLeft('0', 2));
            button.addMouseListener(this, false);
            button.isDragTarget = [this, index] { return dragTarget == int(index); };
            button.onClick = [this, index] {
                put(bank, "selected", int(index)); updateControls(); publish(true);
            };
            addAndMakeVisible(button);
        }
        presetName.setEditable(false, true, false);
        presetName.setJustificationType(Justification::centredLeft);
        presetName.setFont(theme::semiboldFont(17));
        presetName.setColour(Label::textColourId, Colour(0xfff2eaff));
        presetName.onEditorShow = [this] {
            editingPreset = synthState::selected(bank);
            Desktop::getInstance().addGlobalMouseListener(&presetOutsideClick);
        };
        presetName.onEditorHide = [this] { Desktop::getInstance().removeGlobalMouseListener(&presetOutsideClick); };
        presetName.onTextChange = [this] {
            if (editingPreset < 0) return;
            synthState::rename(bank, editingPreset, presetName.getText());
            editingPreset = -1;
            updateControls();
            publish(true);
        };
        addAndMakeVisible(presetName);
        enableSwitch.setTitle("Enabled");
        enableSwitch.setTooltip("Enabled");
        enableSwitch.setClickingTogglesState(true);
        enableSwitch.setToggleState(isEnabled, dontSendNotification);
        enableSwitch.onClick = [this, applyEnabled=std::move(applyEnabled)] {
            const bool on = enableSwitch.getToggleState();
            if (!on) keys.allNotesOff(0);
            applyEnabled(on);
        };
        addAndMakeVisible(enableSwitch);
        addAndMakeVisible(octaveDown);
        addAndMakeVisible(octaveUp);
        addAndMakeVisible(octaveLabel);
        octaveLabel.setJustificationType(Justification::centred);
        octaveLabel.setColour(Label::textColourId, accent);
        octaveDown.onClick = [this] { shiftOctave(-1); };
        octaveUp.onClick = [this] { shiftOctave(1); };
        for (unsigned osc = 0; osc < 3; ++osc) {
            const auto first = osc * 4;
            chooser(osc, first, "Waveform", {"Sine","Triangle","Saw","Square","Pulse"});
            knob(osc, first+1, "Level", 0, 1);
            knob(osc, first+2, "Tune", -24, 24, " st", 1);
            knob(osc, first+3, "Fine", -100, 100, " ct", 1);
        }
        chooser(3, Synth::filterMode, "Filter mode", {"Low Pass","Band Pass","High Pass"});
        knob(3, Synth::cutoff, "Cutoff", 20, 18000, " Hz", 1, 1200);
        knob(3, Synth::resonance, "Res", 0, .98);
        knob(3, Synth::drive, "Drive", 0, 1);
        knob(3, Synth::envelopeAmount, "Env", -1, 1);
        envelope(4, Synth::attack);
        envelope(5, Synth::filterAttack);
        chooser(6, Synth::lfoWave, "LFO waveform", {"Sine", "Triangle", "Square"});
        knob(6, Synth::lfoRate, "Rate", .05, 16, " Hz", .01, 1.8);
        knob(6, Synth::lfoPitch, "Pitch", 0, 2, " st");
        knob(6, Synth::lfoFilter, "Filter", 0, 1);
        chooser(7, Synth::mono, "Voice mode", {"Poly", "Mono"});
        knob(7, Synth::volume, "Volume", 0, 1);
        knob(7, Synth::spread, "Spread", 0, 1);
        knob(7, Synth::glide, "Glide", 0, .8, " s");
        knob(7, Synth::noise, "Noise", 0, 1);
        addAndMakeVisible(keyboard);
        keyboard.setScrollButtonsVisible(false);
        keyboard.setKeyPressBaseOctave(4);
        keyboard.setBlackNoteLengthProportion(.62f);
        keyboard.setBlackNoteWidthProportion(.58f);
        keyboard.setColour(MidiKeyboardComponent::whiteNoteColourId, Colour(0xff100917));
        shiftOctave(0);
        keys.addListener(this);
        updateControls();
        startTimerHz(24);
    }
    ~CatSynthEditor() override {
        for (auto &mode : modes) if (mode) mode->setLookAndFeel(nullptr);
        for (auto &group : groups) for (auto &dial : group) dial->slider.setLookAndFeel(nullptr);
        presetName.onEditorHide = {};
        Desktop::getInstance().removeGlobalMouseListener(&presetOutsideClick);
        keys.removeListener(this);
        if (auto voice = audio.synthVoice(track, effect))
            for (unsigned key = 0; key < pressed.size(); ++key) if (pressed[key]) voice->screenKey(key, 0);
    }
    void paint(Graphics &g) override {
        const auto shape = getLocalBounds().toFloat().reduced(1);
        g.setGradientFill(ColourGradient(Colour(0xff25143c), shape.getX(), shape.getY(),
                                         Colour(0xff100a21), shape.getRight(), shape.getBottom(), false));
        g.fillRoundedRectangle(shape, 12);
        g.setColour(accent.withAlpha(.4f)); g.drawRoundedRectangle(shape, 12, 1.f);
        g.setColour(Colour(0xff120a20));
        g.fillRoundedRectangle(juce::Rectangle<float>(10.f, 10.f, float(getWidth()-20), 70.f), 8.f);
        for (size_t index=0; index<areas.size(); ++index) {
            auto area = areas[index];
            g.setColour(Colour(0xff161020)); g.fillRoundedRectangle(area.toFloat(), 7);
            g.setColour(accent.withAlpha(.23f)); g.drawRoundedRectangle(area.toFloat(), 7, 1);
            g.setColour(accent); g.setFont(theme::semiboldFont(10));
            g.drawText(titles[index], area.removeFromTop(20).reduced(8, 0), Justification::centredLeft);
            if (index == 4 || index == 5)
                drawEnvelope(g, area.removeFromTop(24).reduced(8, 1),
                    index == 4 ? Synth::attack : Synth::filterAttack);
        }
    }
    void resized() override {
        auto frame = getLocalBounds().reduced(12);
        auto presetHeader = frame.removeFromTop(32).reduced(6, 2);
        enableSwitch.setBounds(presetHeader.removeFromRight(37).withSizeKeepingCentre(34, 18));
        presetName.setBounds(presetHeader);
        auto slots = frame.removeFromTop(31).reduced(6, 0);
        for (size_t i = 0; i < presets.size(); ++i) {
            const auto left = slots.getX() + int(i) * slots.getWidth() / int(presets.size());
            const auto right = slots.getX() + (int(i) + 1) * slots.getWidth() / int(presets.size());
            presets[i].setBounds(left+2, slots.getY(), right-left-4, slots.getHeight());
        }
        frame.removeFromTop(8);
        auto keysArea = frame.removeFromBottom(std::min(86, frame.getHeight()/3));
        keyboard.setBounds(keysArea);
        keyboard.setKeyWidth(float(keysArea.getWidth())/22.f);
        frame.removeFromBottom(8);
        auto octaveControls = frame.removeFromBottom(26).withWidth(146);
        octaveDown.setBounds(octaveControls.removeFromLeft(28));
        octaveUp.setBounds(octaveControls.removeFromRight(28));
        octaveLabel.setBounds(octaveControls);
        frame.removeFromBottom(8);
        auto upper = frame.removeFromTop(frame.getHeight()/2);
        frame.removeFromTop(6);
        for (unsigned i=0;i<areas.size();++i) {
            auto row = i < 4 ? upper : frame;
            const auto col = int(i % 4);
            const auto x = row.getX() + row.getWidth() * col / 4;
            const auto next = row.getX() + row.getWidth() * (col+1) / 4;
            areas[i] = {x+2, row.getY(), std::max(1, next-x-4), row.getHeight()};
            auto body = areas[i].reduced(8, 4);
            body.removeFromTop(18);
            if (auto *mode = modes[i].get()) mode->setBounds(body.removeFromTop(24));
            if (i == 4 || i == 5) body.removeFromTop(24);
            body.removeFromTop(6);
            auto &dials = groups[i];
            for (size_t d=0; d<dials.size(); ++d) {
                auto &dial = *dials[d];
                auto bounds = juce::Rectangle<int>(body.getX()+int(d)*body.getWidth()/int(dials.size()), body.getY(),
                                             body.getWidth()/int(dials.size()), body.getHeight());
                dial.label.setBounds(bounds.removeFromTop(16));
                dial.slider.setBounds(bounds.removeFromTop(std::min(59, bounds.getHeight())).reduced(0, 1));
            }
        }
    }

    void mouseDrag(const MouseEvent &event) override {
        if (!event.mods.isLeftButtonDown() || !event.mouseWasDraggedSinceMouseDown() || isDragAndDropActive()) return;
        for (size_t i = 0; i < presets.size(); ++i) {
            if (event.eventComponent != &presets[i]) continue;
            startDragging(int(i) + 1, &presets[i]);
            return;
        }
    }
    bool isInterestedInDragSource(const SourceDetails &details) override {
        const int source = int(details.description) - 1;
        return isPositiveAndBelow(source, int(presets.size())) && details.sourceComponent.get() == &presets[size_t(source)];
    }
    void itemDragMove(const SourceDetails &details) override {
        const int next = presetAt(details.localPosition);
        if (next != dragTarget) {
            dragTarget = next;
            for (auto &button : presets) button.repaint();
        }
    }
    void itemDragExit(const SourceDetails &) override {
        dragTarget = -1;
        for (auto &button : presets) button.repaint();
    }
    void itemDropped(const SourceDetails &details) override {
        itemDragExit(details);
        const int source = int(details.description) - 1, target = presetAt(details.localPosition);
        if (target < 0 || target == source) return;
        synthState::save(bank, synthState::patch(bank, source), target);
        synthState::rename(bank, target, synthState::name(bank, source));
        updateControls();
        publish(true);
    }

  private:
    using Synth = synthState::Synth;
    class SynthKeyboard final : public MidiKeyboardComponent {
      public:
        explicit SynthKeyboard(MidiKeyboardState &state) : MidiKeyboardComponent(state, horizontalKeyboard) {}
      private:
        void drawWhiteNote(int key, Graphics &g, juce::Rectangle<float> area, bool down, bool, Colour, Colour) override {
            g.setColour(down ? Colour(0xffb58aff) : Colour(0xffece4fa));
            g.fillRoundedRectangle(area.reduced(.5f, 0.f), 3.f);
            if (key % 12 == 0) {
                g.setColour(Colours::black);
                g.setFont(theme::mediumFont(8));
                g.drawText("C" + String(key / 12 - 1), area.withY(area.getBottom()-18).withHeight(12), Justification::centred);
            }
        }
        void drawBlackNote(int, Graphics &g, juce::Rectangle<float> area, bool down, bool, Colour) override {
            g.setColour(down ? Colour(0xffb58aff) : Colour(0xff251731));
            g.fillRoundedRectangle(area.reduced(.5f, 0.f), 3.f);
        }
    };
    class EnableSwitch final : public TextButton {
        void paintButton(Graphics &g, bool, bool) override {
            const auto shape = getLocalBounds().toFloat().reduced(.5f);
            g.setColour(getToggleState() ? Colour(0xffb58aff) : Colour(0xff4c4357));
            g.fillRoundedRectangle(shape, shape.getHeight() / 2);
            const float thumb = shape.getHeight() - 4;
            g.setColour(Colours::white);
            g.fillEllipse(getToggleState() ? shape.getRight()-thumb-2 : shape.getX()+2, shape.getY()+2, thumb, thumb);
        }
    };
    class PresetNameLabel final : public Label {
        TextEditor *createEditorComponent() override {
            auto *editor = Label::createEditorComponent();
            editor->setInputRestrictions(20);
            editor->setColour(TextEditor::backgroundColourId, Colour(0xff2a1a3c));
            editor->setColour(TextEditor::textColourId, Colour(0xfff2eaff));
            return editor;
        }
    };

    class SelectorStyle final : public LookAndFeel_V4 {
      public:
        SelectorStyle() {
            setColour(PopupMenu::backgroundColourId, Colour(0xff211335));
            setColour(PopupMenu::textColourId, Colour(0xfff2eaff));
            setColour(ComboBox::textColourId, Colour(0xfff2eaff));
        }
        Font getComboBoxFont(ComboBox &) override { return theme::font(11); }
        void drawComboBox(Graphics &g, int width, int height, bool, int, int, int, int, ComboBox &) override {
            const auto box = juce::Rectangle<float>(0,0,float(width),float(height)).reduced(.5f);
            g.setColour(Colour(0xff2a1a3c)); g.fillRoundedRectangle(box,4);
            g.setColour(Colour(0x42b58aff)); g.drawRoundedRectangle(box,4,1);
            Path arrow;
            const float x = float(width)-13.f, y = float(height)*.5f;
            arrow.startNewSubPath(x-3,y-1); arrow.lineTo(x,y+2); arrow.lineTo(x+3,y-1);
            g.setColour(Colour(0xfff2eaff)); g.strokePath(arrow,PathStrokeType(1.2f));
        }
        void drawRotarySlider(Graphics &g, int x, int y, int width, int height, float value,
                              float start, float end, Slider &) override {
            const auto bounds = juce::Rectangle<float>((float)x, (float)y, (float)width, (float)height);
            const auto centre = bounds.getCentre();
            const float radius = std::min(15.5f, std::min(bounds.getWidth(), bounds.getHeight()) * .5f);
            if (radius < 5) return;
            const auto point = [&](float angle, float distance) {
                return centre + Point<float>(std::sin(angle), -std::cos(angle)) * distance;
            };
            const auto active = Colour(0xffb58aff);
            g.setColour(Colours::white.withAlpha(.5f));
            for (int i = 0; i <= 10; ++i) {
                const float angle = start + (end-start) * i / 10;
                g.drawLine(Line<float>(point(angle,radius-(i%5==0?4.f:2.5f)),point(angle,radius-1)),1);
            }
            auto arc = [&](float finish, Colour colour) {
                if (finish <= start) return;
                Path path;
                path.addCentredArc(centre.x,centre.y,radius-3.5f,radius-3.5f,0,start,finish,true);
                g.setColour(colour);
                g.strokePath(path,PathStrokeType(2.4f,PathStrokeType::curved,PathStrokeType::rounded));
            };
            arc(end, Colours::white.withAlpha(.12f));
            const float angle = start + (end-start)*value;
            arc(angle, active);
            const auto knob = bounds.withSizeKeepingCentre(radius*1.32f,radius*1.32f);
            g.setGradientFill(ColourGradient(Colour(0xff525252),knob.getTopLeft(),Colour(0xff262626),knob.getBottomLeft(),false));
            g.fillEllipse(knob);
            g.setColour(Colours::white.withAlpha(.17f)); g.drawEllipse(knob,1);
            g.setColour(active);
            g.drawLine(Line<float>(point(angle,radius*.29f),point(angle,radius*.56f)),2);
        }
        void getIdealPopupMenuItemSize(const String &text, bool divider, int, int &width, int &height) override {
            width = std::max(134, int(std::ceil(GlyphArrangement::getStringWidth(theme::font(11), text))) + 32);
            height = divider ? 4 : 24;
        }
        void drawPopupMenuItem(Graphics &g, const juce::Rectangle<int> &area, bool divider, bool enabled,
                               bool highlighted, bool checked, bool, const String &text, const String &,
                               const Drawable *, const Colour *) override {
            if (divider) return;
            if (highlighted || checked) {
                g.setColour(Colour(0xff392650)); g.fillRect(area);
            }
            g.setColour(Colour(0xfff2eaff).withMultipliedAlpha(enabled ? 1.f : .45f));
            if (checked) {
                Path check;
                const float x = float(area.getX()+9), y = float(area.getCentreY());
                check.startNewSubPath(x,y); check.lineTo(x+2,y+2); check.lineTo(x+7,y-3);
                g.strokePath(check, PathStrokeType(1.25f));
            }
            g.setFont(theme::font(11));
            g.drawText(text,area.withTrimmedLeft(23).withTrimmedRight(8),Justification::centredLeft,true);
        }
    };

    struct PresetOutsideClick final : MouseListener {
        explicit PresetOutsideClick(Label &field) : field(field) {}
        void mouseDown(const MouseEvent &event) override {
            const auto *editor = field.getCurrentTextEditor();
            if (editor && event.eventComponent != editor && !editor->isParentOf(event.eventComponent))
                field.hideEditor(false);
        }
        Label &field;
    };

    class PresetButton final : public TextButton {
      public:
        std::function<bool()> isDragTarget;
        void paintButton(Graphics &g, bool hover, bool down) override {
            const auto area = getLocalBounds().toFloat().reduced(.5f);
            const bool selected = getToggleState(), drop = isDragTarget && isDragTarget();
            g.setColour(selected ? Colour(0xffb58aff) : Colour(hover || down ? 0xff392650 : 0xff211335));
            g.fillRoundedRectangle(area,5);
            g.setColour(Colour(0xffb58aff).withAlpha(drop ? 1.f : .35f));
            g.drawRoundedRectangle(area,5,drop ? 2.f : 1.f);
            g.setColour(selected ? Colour(0xff140522) : Colour(0xffb58aff));
            g.setFont(theme::semiboldFont(12));
            g.drawText(getButtonText(),getLocalBounds(),Justification::centred);
        }
    };
    struct Dial { Label label; Slider slider; unsigned index = 0; };
    AudioEngine &audio;
    const ID track;
    const String effect;
    var bank;
    std::function<void(var)> store;
    std::array<PresetButton, Synth::presetCount> presets;
    PresetNameLabel presetName;
    EnableSwitch enableSwitch;
    PresetOutsideClick presetOutsideClick{presetName};
    int editingPreset = -1, dragTarget = -1, octave = 0;
    TextButton octaveDown{String::fromUTF8("−")}, octaveUp{"+"};
    Label octaveLabel;
    MidiKeyboardState keys;
    SynthKeyboard keyboard;
    std::array<bool,128> pressed{};
    std::array<bool,128> reflected{};
    bool updatingKeyboard = false;
    const Colour accent{0xffb58aff};
    std::array<std::vector<std::unique_ptr<Dial>>,8> groups;
    std::array<std::unique_ptr<ComboBox>,8> modes;
    std::array<unsigned,8> modeIndex{};
    std::array<juce::Rectangle<int>,8> areas;
    const std::array<const char*,8> titles{"OSC 1","OSC 2","OSC 3","FILTER","AMPLIFIER ENV","FILTER ENV","MODULATION","OUTPUT"};

    static SelectorStyle &controlStyle() {
        static SelectorStyle style;
        return style;
    }
    void drawEnvelope(Graphics &g, juce::Rectangle<int> area, unsigned first) const {
        const auto values = synthState::patch(bank);
        const float attack = values[first], decay = values[first+1], sustain = values[first+2], release = values[first+3];
        drawADSREnvelope(g, area, attack, decay, sustain, release, accent);
    }
    int presetAt(Point<int> point) const {
        for (size_t i = 0; i < presets.size(); ++i) if (presets[i].getBounds().contains(point)) return int(i);
        return -1;
    }
    void shiftOctave(int delta) {
        keys.allNotesOff(0);
        pressed.fill(false); reflected.fill(false);
        octave = jlimit(-2, 2, octave+delta);
        keyboard.setAvailableRange(48 + 12*octave, 84 + 12*octave);
        keyboard.setLowestVisibleKey(48 + 12*octave);
        keyboard.setKeyPressBaseOctave(4+octave);
        octaveLabel.setText("Octave  " + String(octave > 0 ? "+" : "") + String(octave), dontSendNotification);
        octaveDown.setEnabled(octave > -2); octaveUp.setEnabled(octave < 2);
    }
    void chooser(unsigned group, unsigned index, const String &title, StringArray choices) {
        auto choice = std::make_unique<ComboBox>();
        choice->addItemList(choices, 1);
        choice->setLookAndFeel(&controlStyle());
        choice->setTooltip(title);
        choice->setTitle(title);
        choice->onChange = [this, group, index] { edit(index, float(modes[group]->getSelectedId()-1)); publish(true); };
        modeIndex[group] = index;
        addAndMakeVisible(*choice);
        modes[group] = std::move(choice);
    }
    void knob(unsigned group, unsigned index, const String &title, double min, double max,
              const String &unit = {}, double step = .001, double centre = 0.) {
        auto control = std::make_unique<Dial>(); control->index = index;
        control->label.setText(title, dontSendNotification);
        control->label.setFont(theme::font(10));
        control->label.setJustificationType(Justification::centred);
        auto &slider = control->slider;
        slider.setSliderStyle(Slider::RotaryVerticalDrag);
        slider.setLookAndFeel(&controlStyle());
        slider.setTextBoxStyle(Slider::TextBoxBelow, true, 56, 16);
        slider.setColour(Slider::textBoxTextColourId, accent);
        slider.setColour(Slider::textBoxBackgroundColourId, Colour(0xff130a20));
        slider.setColour(Slider::textBoxOutlineColourId, Colours::transparentBlack);
        slider.setRange(min, max, step);
        slider.setTextValueSuffix(unit);
        slider.setNumDecimalPlacesToDisplay(step >= 1 ? 0 : 2);
        if (centre > min && centre < max) slider.setSkewFactorFromMidPoint(centre);
        slider.setColour(Slider::rotarySliderFillColourId, accent);
        slider.setColour(Slider::thumbColourId, accent);
        slider.onValueChange = [this, index, control=control.get()] {
            edit(index, float(control->slider.getValue()));
            publish(!control->slider.isMouseButtonDown());
        };
        slider.onDragEnd = [this] { publish(true); };
        addAndMakeVisible(slider); addAndMakeVisible(control->label);
        groups[group].push_back(std::move(control));
    }
    void envelope(unsigned group, unsigned first) {
        knob(group, first, "Atk", .001, 4, " s", .001, .2);
        knob(group, first+1, "Dec", .005, 4, " s", .001, .2);
        knob(group, first+2, "Sus", 0, 1);
        knob(group, first+3, "Rel", .006, 8, " s", .001, .4);
    }
    void edit(unsigned index, float value) {
        auto patch = synthState::patch(bank);
        patch[index] = value;
        synthState::save(bank, patch, synthState::selected(bank));
    }
    void publish(bool commit) {
        if (auto voice = audio.synthVoice(track, effect)) voice->configure(synthState::patch(bank));
        if (auto voice = audio.synthVoice(track, effect, 1)) voice->configure(synthState::patch(bank));
        if (commit) store(bank.clone());
        repaint();
    }
    void updateControls() {
        auto patch = synthState::patch(bank);
        const auto selected = synthState::selected(bank);
        presetName.setText(synthState::name(bank, selected), dontSendNotification);
        for (size_t i=0; i<presets.size(); ++i) {
            presets[i].setTooltip(synthState::name(bank, int(i)));
            presets[i].setToggleState(int(i)==selected, dontSendNotification);
        }
        for (size_t i=0; i<groups.size(); ++i) {
            if (modes[i]) modes[i]->setSelectedId(int(patch[modeIndex[i]])+1, dontSendNotification);
            for (auto &dial : groups[i]) {
                dial->slider.setValue(patch[dial->index], dontSendNotification);
                dial->slider.setDoubleClickReturnValue(true, Synth::factory(unsigned(selected))[dial->index]);
            }
        }
        repaint();
    }
    void handleNoteOn(MidiKeyboardState *, int, int key, float) override {
        if (updatingKeyboard || !enableSwitch.getToggleState()) return;
        pressed[size_t(key)] = true;
        if (auto voice = audio.synthVoice(track, effect)) voice->screenKey(unsigned(key), 100);
    }
    void handleNoteOff(MidiKeyboardState *, int, int key, float) override {
        if (updatingKeyboard) return;
        pressed[size_t(key)] = false;
        if (auto voice = audio.synthVoice(track, effect)) voice->screenKey(unsigned(key), 0);
    }
    void timerCallback() override {
        const auto voice = audio.synthVoice(track, effect);
        const ScopedValueSetter<bool> visualOnly(updatingKeyboard, true);
        for (int key=48 + octave*12; key<=84 + octave*12; ++key) {
            const bool on = voice && voice->keyIsActive(key) && !pressed[key];
            if (on == reflected[key]) continue;
            reflected[key] = on;
            if (on) keys.noteOn(16, int(key), 1);
            else keys.noteOff(16, int(key), 0);
        }
    }
};
}
