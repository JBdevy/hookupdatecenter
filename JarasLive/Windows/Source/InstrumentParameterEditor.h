#pragma once
#include "NativeFXControls.h"
#include "InstrumentAssets.h"
#include "Localization.h"

namespace catlive {
// Uses the same nested parameter document as the Mac editor and the SF2 renderer.
class InstrumentParameterEditor final : public Component {
    class Segment final : public TextButton {
    public:
        void paintButton(Graphics &g, bool over, bool down) override {
            g.setColour(getToggleState() ? Colour(0xff63bb40) : Colour(over || down ? 0xff383838 : 0xff2c2c2c));
            g.fillRoundedRectangle(getLocalBounds().toFloat(), 6);
            g.setColour(getToggleState() ? Colours::black : Colour(0xffdddddd));
            g.setFont(theme::font(14));
            g.drawText(getButtonText(), getLocalBounds().reduced(3, 0), Justification::centred);
        }
    };
    class Check final : public ToggleButton {
        void paintButton(Graphics &g, bool, bool) override {
            const float y = (getHeight() - 16) * .5f;
            g.setColour(getToggleState() ? Colour(0xff63bb40) : Colour(0xff383838));
            g.fillRoundedRectangle(0, y, 16, 16, 4);
            if (getToggleState()) {
                Path mark; mark.startNewSubPath(4, y + 8); mark.lineTo(7, y + 11); mark.lineTo(12, y + 5);
                g.setColour(Colours::black); g.strokePath(mark, PathStrokeType(1.6f));
            }
            g.setColour(Colours::white); g.setFont(theme::font(14));
            g.drawText(getButtonText(), 22, 0, getWidth() - 22, getHeight(), Justification::centredLeft);
        }
    };
    struct Body final : Component {
        InstrumentParameterEditor &owner;
        explicit Body(InstrumentParameterEditor &o) : owner(o) {}
        void paint(Graphics &g) override { owner.paintPage(g); }
    } body{*this};
public:
    InstrumentParameterEditor(String id, std::function<var()> readSettings,
                              std::function<void()> preview, std::function<void()> save)
        : instrumentID(std::move(id)), read(std::move(readSettings)), changed(std::move(preview)), commit(std::move(save)) {
        setComponentID("instrumentParameterEditor");
        for (auto entry : instrumentAssets::catalog())
            if (str(entry, "id") == instrumentID) category = str(entry, "category");
        artwork = ImageCache::getFromFile(File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("InstrumentInterfaces").getChildFile((category.isEmpty() ? "keyboard" : category) + ".png"));
        const std::array<String, 4> names{"Envelope", "Velocity", "Cutoff", "Controller"};
        for (int i = 0; i < 4; ++i) {
            tabs[i].setButtonText(names[i]); tabs[i].setComponentID("instrumentTab" + names[i]);
            tabs[i].onClick = [this, i] { selectPage(i); }; addAndMakeVisible(tabs[i]);
        }
        const std::array<String, 3> curves{"Soft", localization::translate("Medium"), "Hard"};
        for (int i = 0; i < 3; ++i) {
            curveButtons[i].setButtonText(curves[i]); curveButtons[i].setComponentID("instrumentCurve" + String(i));
            curveButtons[i].onClick = [this, i] {
                edit("velocity", "curve", i == 0 ? "soft" : i == 2 ? "hard" : "medium"); refreshSegments();
            }; body.addChildComponent(curveButtons[i]);
        }
        for (int i = 0; i < 2; ++i) {
            voices[i].setButtonText(localization::translate(i == 0 ? "Monophonic" : "Polyphonic"));
            voices[i].setComponentID(i == 0 ? "instrumentMonophonic" : "instrumentPolyphonic");
            voices[i].onClick = [this, i] { edit("controllers", "monophonic", i == 0); refreshSegments(); };
            body.addChildComponent(voices[i]);
        }
        modulation.setButtonText("Modulation"); pitchBend.setButtonText("Pitch Bend");
        modulation.setComponentID("instrumentModulation"); pitchBend.setComponentID("instrumentPitchBend");
        modulation.onClick = [this] { edit("controllers", "modulation", modulation.getToggleState()); };
        pitchBend.onClick = [this] { edit("controllers", "pitchBend", pitchBend.getToggleState()); };
        body.addChildComponent(modulation); body.addChildComponent(pitchBend);
        viewport.setComponentID("instrumentParametersViewport");
        viewport.setViewedComponent(&body, false); viewport.setScrollBarsShown(true, false);
        viewport.setScrollBarThickness(8); addAndMakeVisible(viewport);
        selectPage(0);
    }
    ~InstrumentParameterEditor() override { viewport.setViewedComponent(nullptr, false); }
    void selectPage(int index) {
        page = jlimit(0, 3, index); knobs.clear();
        for (int i = 0; i < 4; ++i) tabs[i].setToggleState(page == i, dontSendNotification);
        for (auto &button : curveButtons) button.setVisible(page == 1);
        for (auto &button : voices) button.setVisible(page == 3);
        modulation.setVisible(page == 3); pitchBend.setVisible(page == 3);
        if (page == 0) {
            knob("Attack", "", "attack", 0, 10, 0, " ms", 1000, true);
            knob("Hold", "", "hold", 0, 10, 10, " ms", 1000, true);
            knob("Decay", "", "decay", .001, 10, 10, " ms", 1000, true);
            knob("Sustain", "", "sustain", 0, 1, 1, " %", 100);
            knob("Release", "", "release", .001, 20, category == "drum" ? 20 : .3, " ms", 1000, true);
            knob("Gain", "", "gain", -24, 12, 0, " dB");
        } else if (page == 1) {
            knob("Cutoff", "velocity", "cutoffMinimum", 20, 20000, 20000, " Hz", 1, true);
        } else if (page == 2) {
            knob("Cutoff", "cutoff", "frequency", 20, 20000, 20000, " Hz", 1, true);
            knob("Depth", "cutoff", "depth", 0, 10, 0, " oct");
            knob("Attack", "cutoff", "attack", 0, 10, 0, " ms", 1000, true);
            knob("Hold", "cutoff", "hold", 0, 10, 0, " ms", 1000, true);
            knob("Decay", "cutoff", "decay", .001, 10, .3, " ms", 1000, true);
            knob("Sustain", "cutoff", "sustain", 0, 1, 1, " %", 100);
            knob("Release", "cutoff", "release", .001, 20, .3, " ms", 1000, true);
        } else knob("Volume", "controllers", "volume", -96, 0, 0, " dB");
        refreshSegments(); viewport.setViewPosition(0, 0); resized(); repaint();
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        if (artwork.isValid()) {
            g.setImageResamplingQuality(Graphics::highResamplingQuality);
            g.drawImage(artwork, getLocalBounds().toFloat(), RectanglePlacement::fillDestination);
            g.setColour(Colours::black.withAlpha(.12f)); g.fillAll();
        }
        const auto title = juce::Rectangle<float>(float(getWidth() / 2 - std::min(220, getWidth()/2 - 16)), 16,
                                                 float(std::min(440, getWidth() - 32)), 48);
        g.setColour(Colours::black.withAlpha(.78f)); g.fillRoundedRectangle(title, 12);
        g.setColour(Colours::white.withAlpha(.18f)); g.drawRoundedRectangle(title, 12, 1);
        g.setColour(Colours::white); g.setFont(theme::semiboldFont(20));
        g.drawFittedText(instrumentAssets::name(instrumentID), title.reduced(16, 4).toNearestInt(), Justification::centred, 1);
    }
    void resized() override {
        const int tabWidth = std::min(440, getWidth() - 32);
        for (int i = 0; i < 4; ++i) tabs[i].setBounds((getWidth() - tabWidth) / 2 + i * tabWidth / 4, 80, tabWidth / 4, 28);
        viewport.setBounds(16, 124, std::max(1, getWidth()-32), std::max(1, getHeight()-140));
        // Shrink the artwork's empty space before hiding any controls. The standard
        // 920 x 560 FX manager leaves 416 px here, not the 540 px preview canvas.
        const int minimum = page == 2 ? 264 : page == 1 ? 262 : page == 3 ? 232 : 236;
        const int h = std::max(minimum, viewport.getHeight());
        const int w = std::max(1, viewport.getWidth() - (h > viewport.getHeight() ? 10 : 0));
        body.setSize(w, h); graphArea = {}; topRack = {}; bottomRack = {};
        if (page == 0) {
            bottomRack = {0, h-124, w, 124}; graphArea = {0, h-224, w, 84};
            layoutKnobs(bottomRack, 0, 6);
        } else if (page == 1) {
            const int y = h-250;
            for (int i = 0; i < 3; ++i) curveButtons[i].setBounds(w / 2 - 72 + i * 68, y, 68, 26);
            graphArea = {0, y+38, w, 88}; bottomRack = {0, h-112, w, 112};
            knobs[0]->setBounds(18, bottomRack.getY()+8, 110, 96);
        } else if (page == 2) {
            topRack = {0, h-252, w, 112}; bottomRack = {0, h-124, w, 124};
            const int cell = std::min(110, w / 4);
            knobs[0]->setBounds(12, topRack.getY()+8, cell, 96);
            knobs[1]->setBounds(24+cell, topRack.getY()+8, cell, 96);
            layoutKnobs(bottomRack, 2, 5);
        } else {
            topRack = {0, h-220, w, 220}; const int y = topRack.getY();
            knobs[0]->setBounds(12, y+60, 96, 96);
            for (int i = 0; i < 2; ++i) voices[i].setBounds(226 + i * 104, y+16, 104, 26);
            modulation.setBounds(132, y+62, w-150, 26);
            pitchBend.setBounds(132, y+140, w-150, 26);
        }
        body.repaint();
    }
private:
    Image artwork;
    String instrumentID, category;
    std::function<var()> read;
    std::function<void()> changed, commit;
    Viewport viewport;
    std::array<Segment, 4> tabs;
    std::array<Segment, 3> curveButtons;
    std::array<Segment, 2> voices;
    Check modulation, pitchBend;
    OwnedArray<fxui::Knob> knobs;
    int page = 0;
    juce::Rectangle<int> graphArea, topRack, bottomRack;
    var parameters() const { return get(read(), "instrumentParameters"); }
    var group(const String &name) const { return name.isEmpty() ? parameters() : get(parameters(), Identifier(name)); }
    bool controller(const char *key, bool fallback) const { return flag(group("controllers"), key, fallback); }
    void edit(const String &name, const String &key, var value, bool finish = true) {
        auto settings = read(), p = get(settings, "instrumentParameters");
        if (!p.isObject()) { p = object(); put(settings, "instrumentParameters", p); }
        auto target = name.isEmpty() ? p : get(p, Identifier(name));
        if (!target.isObject()) {
            target = object(); put(p, Identifier(name), target);
            if (name == "controllers") {
                put(target, "modulation", category == "synthPad" || category == "strings");
                put(target, "pitchBend", category == "bass" || category == "lead");
                put(target, "monophonic", category == "lead");
            }
        }
        put(target, Identifier(key), value);
        if (changed) changed();
        if (finish && commit) commit();
        body.repaint();
    }
    void knob(const char *title, String name, String key, double low, double high, double reset,
              String suffix, double multiplier = 1, bool logarithmic = false) {
        auto *control = knobs.add(new fxui::Knob(localization::translate(title), low * multiplier, high * multiplier,
            .1, num(group(name), Identifier(key), reset) * multiplier, suffix,
            [this, name, key, multiplier](double value) { edit(name, key, value / multiplier, false); },
            [this] { if (commit) commit(); }));
        control->setDiameter(52);
        control->setComponentID("instrumentKnob_" + name + "_" + key);
        control->slider.setComponentID("instrumentValue_" + name + "_" + key);
        control->slider.setDoubleClickReturnValue(true, reset * multiplier);
        if (logarithmic) {
            const double offset = low == 0 ? .001 * multiplier : 0;
            NormalisableRange<double> range(low * multiplier, high * multiplier,
                [offset](double lo, double hi, double fraction) { return (lo + offset) * std::pow((hi + offset) / (lo + offset), fraction) - offset; },
                [offset](double lo, double hi, double value) { return std::log((value + offset) / (lo + offset)) / std::log((hi + offset) / (lo + offset)); });
            range.interval = .1;
            control->slider.setNormalisableRange(range);
        }
        body.addAndMakeVisible(control);
    }
    void refreshSegments() {
        const auto curve = str(group("velocity"), "curve", "medium");
        const int selectedCurve = curve == "soft" ? 0 : curve == "hard" ? 2 : 1;
        for (int i = 0; i < 3; ++i) curveButtons[i].setToggleState(i == selectedCurve, dontSendNotification);
        const bool mono = controller("monophonic", category == "lead");
        voices[0].setToggleState(mono, dontSendNotification); voices[1].setToggleState(!mono, dontSendNotification);
        modulation.setToggleState(controller("modulation", category == "synthPad" || category == "strings"), dontSendNotification);
        pitchBend.setToggleState(controller("pitchBend", category == "bass" || category == "lead"), dontSendNotification);
    }
    void layoutKnobs(juce::Rectangle<int> area, int first, int count) {
        area = area.reduced(12); const int cell = area.getWidth() / count;
        for (int i = 0; i < count; ++i) knobs[first + i]->setBounds(area.getX() + i * cell, area.getY(), cell, 96);
    }
    void paintPage(Graphics &g) {
        g.setColour(Colours::black.withAlpha(.76f));
        for (auto area : {graphArea, topRack, bottomRack}) if (!area.isEmpty()) g.fillRoundedRectangle(area.toFloat(), 10);
        if (page == 0) {
            const auto r = graphArea.toFloat().reduced(16); const auto p = parameters();
            const double a = num(p, "attack"), hold = num(p, "hold", 10), d = num(p, "decay", 10),
                         release = num(p, "release", category == "drum" ? 20 : .3), total = a + hold + d + release + 1;
            const auto x = [&](double t) { return r.getX() + float(t / total) * r.getWidth(); };
            const float sustainY = r.getBottom() - float(num(p, "sustain", 1)) * r.getHeight();
            Path curve; curve.startNewSubPath(r.getX(), r.getBottom()); curve.lineTo(x(a), r.getY());
            curve.lineTo(x(a + hold), r.getY()); curve.lineTo(x(a + hold + d), sustainY);
            curve.lineTo(x(a + hold + d + 1), sustainY); curve.lineTo(r.getRight(), r.getBottom());
            Path fill = curve; fill.closeSubPath();
            g.setGradientFill(ColourGradient(theme::green.withAlpha(.35f), 0, r.getY(), theme::green.withAlpha(.02f), 0, r.getBottom(), false));
            g.fillPath(fill); g.setColour(theme::green); g.strokePath(curve, PathStrokeType(2));
        } else if (page == 1) {
            label(g, "Curve", {body.getWidth() / 2 - 126, curveButtons[0].getY(), 48, 26}, 14);
            auto r = graphArea.toFloat().reduced(18); g.setColour(Colour(0xff454545));
            for (int i = 0; i <= 4; ++i) {
                const float f = i / 4.f;
                g.drawVerticalLine(roundToInt(r.getX() + f * r.getWidth()), r.getY(), r.getBottom());
                g.drawHorizontalLine(roundToInt(r.getY() + f * r.getHeight()), r.getX(), r.getRight());
            }
            const auto value = str(group("velocity"), "curve", "medium");
            const double exponent = value == "soft" ? .65 : value == "hard" ? 1.6 : 1;
            Path curve;
            for (int i = 0; i <= 100; ++i) {
                const float x = r.getX() + i / 100.f * r.getWidth(), y = r.getBottom() - float(std::pow(i / 100., exponent)) * r.getHeight();
                if (i) curve.lineTo(x, y); else curve.startNewSubPath(x, y);
            }
            g.setColour(theme::green); g.strokePath(curve, PathStrokeType(2));
            label(g, "Minimum cutoff for soft notes. Stronger notes open their own filter.",
                  bottomRack.withTrimmedLeft(146).reduced(10, 20), 12, true);
        } else if (page == 2) {
            label(g, "Cutoff envelope", topRack.withTrimmedLeft(std::min(110, body.getWidth() / 4) * 2 + 48).reduced(0, 20), 16);
        } else {
            const int y = topRack.getY();
            label(g, "Voice mode", {132, y+16, 90, 26}, 12);
            label(g, "Modulation wheel controls the cutoff.", {132, y+92, body.getWidth()-150, 36}, 12, true);
            label(g, "Pitch Bend controls vibrato depth at 6.85 Hz.", {132, y+170, body.getWidth()-150, 36}, 12, true);
        }
    }
    static void label(Graphics &g, const char *text, juce::Rectangle<int> area, float size, bool secondary = false) {
        g.setColour(secondary ? theme::secondary : Colours::white); g.setFont(theme::font(size));
        g.drawFittedText(localization::translate(text), area, Justification::centredLeft, 3, 1.f);
    }
};
} // namespace catlive
