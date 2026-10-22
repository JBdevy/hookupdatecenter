#include "NativePluginShortcuts.h"
#pragma once
#include "Session.h"
#include "ExternalEffectEditor.h"
#include "Localization.h"
#include "EffectInsertPanel.h"
#include "FXPresets.h"
#include "FXChain.h"
#include "FXSchema.h"
#include "CatStemEditor.h"
#include "CatDynamicsEditor.h"
namespace catlive {
namespace fxui {
class EnableButton final : public ToggleButton {
  public:
    bool checkbox = false;
    void paintButton(Graphics &g, bool over, bool down) override {
        if (checkbox) {
            ToggleButton::paintButton(g, over, down);
            return;
        }
        g.setColour(Colours::white);
        g.setFont(theme::font(13));
        g.drawText(getButtonText(), 0, 0, getWidth() - 58, getHeight(),
                   Justification::centredRight);
        const auto r =
            juce::Rectangle<float>((float)getWidth() - 52, (getHeight() - 22) * .5f, 50, 22);
        g.setColour(getToggleState() ? theme::green : Colour(0xff555555));
        g.fillRoundedRectangle(r, 11);
        g.setColour(Colours::white);
        g.fillEllipse(getToggleState() ? r.getRight() - 20 : r.getX() + 2, r.getY() + 2, 18, 18);
    }
};
inline String enabledKey(const String &kind) {
    return kind == "CatLive Trigger" ? "triggerEnabled"
           : kind == "Cat Gate" ? "gateEnabled"
           : kind == "CatStemSeparation 5" ? "stemSeparatorEnabled"
           : kind == "EQ"            ? "eqEnabled"
           : kind == "Compressor"  ? "compressorEnabled"
           : kind == "Delay"       ? "delayEnabled"
           : kind == "Reverb"      ? "reverbEnabled"
           : kind == "Limiter"     ? "limiterEnabled"
           : kind == "Pitch"       ? "pitchEnabled"
           : kind == "Instruments" ? "instrumentBypassed"
           : kind == "External"    ? "bypassed"
                                   : "";
}
inline bool isEnabled(const String &kind, const var &settings) {
    const auto key = enabledKey(kind);
    return key.isNotEmpty() && ((kind == "Instruments" || kind == "External") ? !flag(settings, Identifier(key))
                                                      : flag(settings, Identifier(key)));
}
inline void enable(const String &kind, var &settings, bool value) {
    const auto key = enabledKey(kind);
    if (key.isNotEmpty())
        put(settings, Identifier(key), (kind == "Instruments" || kind == "External") ? !value : value);
}
inline void defaults(var &s) {
    s = s.isObject() ? fxschema::complete(s, true) : fxschema::defaults(true);
    if (!get(s, "trigger").isObject()) {
        auto trigger = object();
        for (const auto &[key, value] : std::map<String, double>{{"threshold",-30},{"retrigger",.08},{"gain",0},{"mix",100},{"attack",0},{"decay",.1},{"sustain",1},{"release",.02}}) put(trigger, Identifier(key), value);
        put(s, "trigger", trigger);
    }
    if (!get(s, "gate").isObject()) {
        auto gate = object();
        for (const auto &[key, value] : std::map<String, double>{{"threshold",-40},{"attack",.001},{"decay",.02},{"hold",.05},{"release",.1},{"highPass",20},{"lowPass",20000}}) put(gate, Identifier(key), value);
        put(gate, "filterOutput", false); put(s, "gate", gate);
    }
    if (get(s, "pitchSemitones").isVoid()) put(s, "pitchSemitones", 0.);
    if (!get(s, "limiter").isObject()) {
        auto l = object();
        put(l, "ceiling", -.1);
        put(l, "release", .1);
        put(l, "inputGain", 0);
        put(s, "limiter", l);
    }
}
inline var instrumentParameters(const String &instrument) {
    auto parameters = object(), controllers = object();
    put(parameters, "gain", 0);
    put(parameters, "attack", 0);
    put(parameters, "hold", 10);
    put(parameters, "decay", 10);
    put(parameters, "sustain", 1);
    put(parameters, "release", instrument.startsWith("drum-") ? 20. : .3);
    String category;
    for (auto item : instrumentAssets::catalog())
        if (str(item, "id") == instrument)
            category = str(item, "category");
    put(controllers, "modulation", category == "synthPad" || category == "strings");
    put(controllers, "pitchBend", category == "bass" || category == "lead");
    put(controllers, "monophonic", category == "lead");
    put(parameters, "controllers", controllers);
    return parameters;
}
inline void reset(const String &kind, var &settings) {
    for (const auto &key : fxpresets::fields(kind)) fxpresets::erase(settings, Identifier(key));
    defaults(settings);
}
class KnobLook final : public LookAndFeel_V4 {
  public:
    Font getSliderPopupFont(Slider &) override { return theme::font(12); }
    Label *createSliderTextBox(Slider &s) override {
        auto *l = LookAndFeel_V4::createSliderTextBox(s);
        l->setFont(theme::semiboldFont(12));
        return l;
    }
    void drawRotarySlider(Graphics &g, int x, int y, int w, int h, float value, float start,
                          float end, Slider &) override {
        const auto r = juce::Rectangle<float>((float)x, (float)y, (float)w, (float)h)
                           .withSizeKeepingCentre(78, 78);
        const float cx = r.getCentreX(), cy = r.getCentreY(), radius = 36,
                    angle = start + value * (end - start);
        Path base;
        base.addCentredArc(cx, cy, radius, radius, 0, start, end, true);
        g.setColour(Colour(0xff303030));
        g.strokePath(base, PathStrokeType(4, PathStrokeType::curved, PathStrokeType::rounded));
        Path fill;
        fill.addCentredArc(cx, cy, radius, radius, 0, start, angle, true);
        g.setGradientFill(ColourGradient(theme::green, cx - 35, cy + 30, Colour(0xff2dc5ed),
                                         cx + 35, cy - 30, false));
        g.strokePath(fill, PathStrokeType(3.5f, PathStrokeType::curved, PathStrokeType::rounded));
        g.setColour(Colours::black.withAlpha(.4f));
        g.fillEllipse(cx - 31, cy - 29, 65, 65);
        g.setGradientFill(ColourGradient(Colour(0xff383838), cx, cy - 30, Colour(0xff202020), cx,
                                         cy + 30, false));
        g.fillEllipse(cx - 30, cy - 30, 60, 60);
        g.setColour(Colour(0xff424242));
        g.drawEllipse(cx - 30, cy - 30, 60, 60, 1);
        g.setColour(theme::green);
        g.drawLine(cx + std::sin(angle) * 16, cy - std::cos(angle) * 16, cx + std::sin(angle) * 27,
                   cy - std::cos(angle) * 27, 3);
    }
};
class Knob final : public Component {
  public:
    Knob(String title, double low, double high, double step, double value, String suffix,
         std::function<void(double)> change, std::function<void()> commit)
        : label(std::move(title)) {
        slider.setLookAndFeel(&look);
        addAndMakeVisible(slider);
        slider.setSliderStyle(Slider::RotaryHorizontalVerticalDrag);
        slider.setRotaryParameters(MathConstants<float>::pi * 1.25f,
                                   MathConstants<float>::pi * 2.75f, true);
        slider.setRange(low, high, step);
        slider.setTextBoxStyle(Slider::TextBoxBelow, false, 110, 22);
        slider.setColour(Slider::textBoxTextColourId, Colours::white);
        slider.setColour(Slider::textBoxOutlineColourId, Colours::transparentBlack);
        slider.setColour(Slider::textBoxBackgroundColourId, Colours::transparentBlack);
        slider.setTextValueSuffix(std::move(suffix));
        slider.setValue(value, dontSendNotification);
        slider.setDoubleClickReturnValue(true, value);
        slider.onValueChange = [this, change, commit] {
            change(slider.getValue());
            if (!slider.isMouseButtonDown())
                commit();
        };
        slider.onDragEnd = std::move(commit);
    }
    ~Knob() override { slider.setLookAndFeel(nullptr); }
    void paint(Graphics &g) override {
        g.setColour(theme::secondary);
        g.setFont(theme::semiboldFont(12));
        g.drawText(label, 0, 0, getWidth(), 20, Justification::centred);
    }
    void resized() override { slider.setBounds(0, 22, getWidth(), getHeight() - 22); }
    ParameterSlider slider;

  private:
    String label;
    KnobLook look;
};
class EQGraph final : public Component {
  public:
    var settings;
    std::function<void()> changed, commit;
    EQGraph() {
        setWantsKeyboardFocus(true);
        setComponentID("eqGraph");
    }
    void paint(Graphics &g) override {
        g.setColour(theme::display);
        g.fillRoundedRectangle(getLocalBounds().toFloat(), 5);
        auto area = plot();
        const auto bands = list(get(settings, "bands"));
        g.saveState();
        g.reduceClipRegion(area.toNearestInt());
        g.setColour(Colour(0xff303030));
        for (auto f : {20., 50., 100., 200., 500., 1000., 2000., 5000., 10000., 20000.})
            g.drawVerticalLine((int)xAt(f), area.getY(), area.getBottom());
        for (int db = -24; db <= 24; db += 6)
            g.drawHorizontalLine((int)yAt(db), area.getX(), area.getRight());
        g.setColour(theme::secondary.withAlpha(.7f));
        g.drawHorizontalLine((int)yAt(0), area.getX(), area.getRight());
        std::vector<dsp::IIR::Coefficients<float>::Ptr> filters;
        for (const auto &band : bands)
            if (flag(band, "enabled", true)) {
                const auto f = (float)jlimit(20., 20000., num(band, "frequency", 1000)),
                           q = (float)jlimit(.1, 18., num(band, "q", .707));
                const auto gain = Decibels::decibelsToGain((float)num(band, "gain"));
                const auto type = str(band, "type", "bell");
                using C = dsp::IIR::Coefficients<float>;
                if (type == "lowCut" || type == "highCut") {
                    const int order = jlimit(1, 32, (int)num(band, "slope", 12) / 6);
                    for (int stage = 0; stage < std::max(1, order / 2); ++stage) {
                        if (order == 1) {
                            double k = std::tan(MathConstants<double>::pi * f / 48000.),
                                   b0 = (type == "lowCut" ? 1 : k) / (1 + k);
                            filters.push_back(new C((float)b0, (float)(type == "lowCut" ? -b0 : b0),
                                                    0, 1, (float)((k - 1) / (k + 1)), 0));
                        } else {
                            const auto sq =
                                (float)(1 / (2 * std::sin(MathConstants<double>::pi *
                                                          (2 * stage + 1) / (2 * order))));
                            filters.push_back(type == "lowCut" ? C::makeHighPass(48000, f, sq)
                                                               : C::makeLowPass(48000, f, sq));
                        }
                    }
                } else
                    filters.push_back(type == "lowShelf"    ? C::makeLowShelf(48000, f, q, gain)
                                      : type == "highShelf" ? C::makeHighShelf(48000, f, q, gain)
                                                            : C::makePeakFilter(48000, f, q, gain));
            }
        Path response;
        for (int x = (int)area.getX(); x < area.getRight(); ++x) {
            double magnitude = 1;
            for (const auto &f : filters)
                magnitude *= f->getMagnitudeForFrequency(frequencyAt((float)x), 48000);
            const auto y = yAt(Decibels::gainToDecibels(magnitude, -120.));
            if (x == (int)area.getX())
                response.startNewSubPath((float)x, y);
            else
                response.lineTo((float)x, y);
        }
        g.setColour(flag(settings, "eqEnabled", true) ? theme::green : theme::secondary);
        g.strokePath(response, PathStrokeType(1.8f));
        for (int i = 0; i < bands.size(); ++i) {
            const auto band = bands[i];
            const auto p = point(band);
            g.setColour(flag(band, "enabled", true) ? theme::green : theme::secondary);
            g.fillEllipse(p.x - 5, p.y - 5, 10, 10);
            g.setColour(i == selected ? Colours::white : theme::display);
            g.drawEllipse(p.x - 5.5f, p.y - 5.5f, 11, 11, 1);
        }
        g.restoreState();
        g.setColour(theme::secondary);
        g.setFont(theme::font(9));
        for (auto f : {20., 50., 100., 200., 500., 1000., 2000., 5000., 10000., 20000.}) {
            String label = f >= 1000 ? String(f / 1000, 0) + "k" : String(f, 0);
            g.drawText(label, (int)xAt(f) - 18, getHeight() - 18, 36, 16, Justification::centred);
        }
        if (selected >= 0 && selected < bands.size()) {
            auto band = bands[selected];
            g.setFont(theme::font(11));
            g.drawText(String(num(band, "frequency"), 0) + " Hz    " +
                           String(num(band, "gain"), 1) + " dB    Q " + String(num(band, "q"), 2),
                       12, 6, getWidth() - 24, 20, Justification::centredLeft);
        }
    }
    void mouseDown(const MouseEvent &e) override {
        grabKeyboardFocus();
        selected = -1;
        auto bands = list(get(settings, "bands"));
        for (int i = 0; i < bands.size(); ++i)
            if (point(bands[i]).getDistanceFrom(e.position) < 12) {
                selected = i;
                break;
            }
        dragging = false;
        wheelBandHeld = selected >= 0 && e.mods.isLeftButtonDown();
        wheelRemainder = 0;
        if (e.mods.isPopupMenu() && std::abs(e.position.y-getHeight()*.5f)<18) add({e.position.x,getHeight()*.5f});
        repaint();
    }
    void mouseDoubleClick(const MouseEvent &e) override {
        if (e.mods.isPopupMenu()) return;
        auto bands = list(get(settings, "bands"));
        if (selected >= 0 && selected < bands.size()) {
            put(bands.getReference(selected), "gain", 0.);
            put(settings, "bands", bands);
            if (changed) changed();
            if (commit) commit();
            repaint();
        } else add(e.position);
    }
    void mouseDrag(const MouseEvent &e) override {
        if (selected < 0 || e.mods.isPopupMenu())
            return;
        auto bands = list(get(settings, "bands"));
        if (selected >= bands.size())
            return;
        auto &band = bands.getReference(selected);
        put(band, "frequency", std::round(frequencyAt(e.position.x)));
        const auto type = str(band, "type");
        if (type != "lowCut" && type != "highCut")
            put(band, "gain", std::round(gainAt(e.position.y) * 10) / 10);
        put(settings, "bands", bands);
        dragging = true;
        if (changed)
            changed();
        repaint();
    }
    void mouseUp(const MouseEvent &) override {
        wheelBandHeld = false;
        wheelRemainder = 0;
        if (dragging && commit)
            commit();
        dragging = false;
    }
    void mouseWheelMove(const MouseEvent &event, const MouseWheelDetails &wheel) override {
        if (!wheelBandHeld || !event.mods.isLeftButtonDown()) {
            Component::mouseWheelMove(event, wheel);
            return;
        }
        if (wheel.isInertial || !std::isfinite(wheel.deltaY)) return;
        wheelRemainder += wheel.isSmooth ? wheel.deltaY * 10. : (wheel.deltaY > 0 ? 1 : wheel.deltaY < 0 ? -1 : 0);
        const int steps = (int)wheelRemainder;
        if (!steps) return;
        wheelRemainder -= steps;
        auto bands = list(get(settings, "bands"));
        if (selected < 0 || selected >= bands.size()) return;
        auto &band = bands.getReference(selected);
        const auto type = str(band, "type");
        if (type == "lowCut" || type == "highCut") {
            const std::array<int, 8> slopes{6,12,24,36,48,72,96,192};
            const auto found = std::find(slopes.begin(), slopes.end(), (int)num(band, "slope", 12));
            const int current = found == slopes.end() ? 1 : (int)(found - slopes.begin());
            put(band, "slope", slopes[(size_t)jlimit(0, 7, current + steps)]);
        } else {
            put(band, "q", jlimit(.1, 18., num(band, "q", .707) * std::pow(1.12, steps)));
        }
        put(settings, "bands", bands);
        if (changed) changed();
        if (commit) commit();
        repaint();
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::deleteKey || key == KeyPress::backspaceKey) {
            remove();
            return true;
        }
        return false;
    }

  private:
    int selected = -1;
    bool dragging = false, wheelBandHeld = false;
    double wheelRemainder = 0;
    juce::Rectangle<float> plot() const {
        return getLocalBounds().toFloat().withTrimmedBottom(20).reduced(8, 0);
    }
    float xAt(double f) const {
        return plot().getX() +
               (float)(std::log(jlimit(20., 20000., f) / 20) / std::log(1000.)) * plot().getWidth();
    }
    float yAt(double gain) const {
        return plot().getCentreY() - (float)(gain / 48) * plot().getHeight();
    }
    double frequencyAt(float x) const {
        return 20 *
               std::pow(1000., jlimit(0., 1., (double)(x - plot().getX()) / plot().getWidth()));
    }
    double gainAt(float y) const {
        return jlimit(-24., 24., (double)(plot().getCentreY() - y) * 48 / plot().getHeight());
    }
    Point<float> point(const var &b) const {
        const auto type = str(b, "type");
        return {xAt(num(b, "frequency", 1000)),
                yAt(type == "lowCut" || type == "highCut" ? 0 : num(b, "gain"))};
    }
    void update() {
        if (changed)
            changed();
        if (commit)
            commit();
        repaint();
    }
    void add(Point<float> p) {
        auto bands = list(get(settings, "bands"));
        if (bands.size() >= 10)
            return;
        auto b = object();
        put(b, "id", text(uuid()));
        put(b, "frequency", frequencyAt(p.x));
        put(b, "gain", gainAt(p.y));
        put(b, "q", .707);
        put(b, "type", "bell");
        put(b, "slope", 12);
        put(b, "enabled", true);
        bands.add(b);
        put(settings, "bands", bands);
        selected = bands.size() - 1;
        update();
    }
    void remove() {
        auto bands = list(get(settings, "bands"));
        if (selected < 0 || selected >= bands.size())
            return;
        bands.remove(selected);
        put(settings, "bands", bands);
        selected = -1;
        update();
    }

};
} // namespace fxui
class EffectsPanel final : public Component, private ListBoxModel, private Timer {
  public:
    std::function<bool(const KeyPress &)> globalKey;
    std::function<void(bool)> globalKeyState;
    EffectsPanel(Session &s, ID target, std::function<void(String)> report, bool itemTarget = false, std::vector<ID> batchTargets = {})
        : session(s), track(std::move(target)), item(itemTarget), insertionTargets(std::move(batchTargets)), error(std::move(report)), chain("FX", this) {
        setComponentID("effectsPanel");
        load();
        fxui::defaults(settings);
        chain.setRowHeight(30);
        chain.setColour(ListBox::backgroundColourId, Colour(0xff181818));
        chain.setOutlineThickness(0);
        addAndMakeVisible(chain);
        for (auto *b : {&add, &remove, &removeEffect}) {
            addAndMakeVisible(b);
            b->getProperties().set("fontSize", 12);
            b->getProperties().set("flat", true);
            b->setColour(TextButton::buttonColourId, Colour(0xff4d4d4d));
        }
        add.setButtonText("Add");
        remove.setButtonText("Excluir");
        removeEffect.setButtonText("Remover efeito");
        add.setComponentID("addEffect");
        remove.setComponentID("removeEffect");
        add.onClick = [this] { addMenu(); };
        remove.onClick = [this] { erase(); };
        removeEffect.onClick = [this] { erase(); };
        enabled.setButtonText("Ativado");
        addAndMakeVisible(enabled);
        enabled.onClick = [this] {
            auto s = current();
            fxui::enable(kind(), s, enabled.getToggleState());
            commit();
            chain.repaint();
            graph.repaint();
        };
        for (int i = 0; i < 3; ++i) {
            auto *b = rooms.add(new TextButton(i == 0 ? "Room" : i == 1 ? "Hall" : "Plate"));
            addAndMakeVisible(b);
            b->getProperties().set("plain", true);
            b->onClick = [this, i] {
                auto s = current();
                put(s, "reverbRoom", i);
                commit();
                show();
            };
        }
        addAndMakeVisible(graph);
        graph.changed = [this] {
            auto s = current();
            put(s, "bands", get(graph.settings, "bands"));
            repaint();
        };
        graph.commit = [this] { commit(); };
        chain.updateContent();
        if (getNumRows())
            chain.selectRow(0);
        else
            show();
        addAndMakeVisible(presets); addAndMakeVisible(savePreset); addAndMakeVisible(defaultPreset);
        presets.setComponentID("fxPreset"); savePreset.setComponentID("saveFXPreset"); defaultPreset.setComponentID("defaultFXPreset");
        savePreset.setButtonText(String::fromUTF8("Salvar preset…"));
        defaultPreset.setButtonText(String::fromUTF8("Usar como padrão"));
        presets.onChange = [this] { loadPreset(); };
        savePreset.onClick = [this] { saveCurrentPreset(); };
        defaultPreset.onClick = [this] { makePresetDefault(); };
        refreshPresets(); resized();
        startTimerHz(20);
    }
    void selectEffect(const String &preferred) {
        const int index = list(get(settings, "inserted")).indexOf(var(preferred));
        if (index < 0) return;
        chain.selectRow(index);
        if (kind() == "External") openExternalEditor();
    }
    void paint(Graphics &g) override {
        g.fillAll(Colour(0xff242424));
        g.setColour(Colour(0xff181818));
        g.fillRect(0, 0, 190, getHeight());
        g.setColour(Colour(0xff202020));
        g.fillRect(0, getHeight() - 40, 190, 40);
        auto r = content();
        if(kind()=="CatStemSeparation 5"||kind()=="External"||dynamicsEditor)return;
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(14));
        if (kind().isEmpty()) {
            g.drawText("Adicionar efeito", r, Justification::centred);
            return;
        }
        g.drawText((kind()=="External"?str(current(),"name"):"CatLive " + kind()) + String::fromUTF8(" · ") + trackName, r.getX(), headerY, r.getWidth() - 36,
                   24, Justification::centredLeft);
        g.setFont(theme::semiboldFont(9));
        g.setColour(theme::secondary);
        g.drawText(unicodeCase(trackName), r.getX(), headerY + 43, r.getWidth() - 120, 20,
                   Justification::centredLeft);
        if (kind() == "EQ") {
            g.setFont(theme::font(10));
            g.drawText(String(list(get(current(), "bands")).size()) + "/10", r.getRight() - 46,
                       headerY + 78, 46, 20, Justification::centredRight);
            g.drawText(String::fromUTF8(
                           "Clique com o botão direito na linha central para adicionar uma banda."),
                       r.getX(), getHeight() - 31, r.getWidth(), 20, Justification::centred);
        } else {
            g.setColour(theme::display);
            g.fillRoundedRectangle(r.getX(), rackY, (float)r.getWidth(), (float)rackHeight, 10);
            paintMeters(g);
        }
    }
    void resized() override {
        chain.setBounds(0, 0, 190, std::max(1, getHeight() - 40));
        add.setBounds(6, getHeight() - 32, 84, 24);
        remove.setBounds(96, getHeight() - 32, 88, 24);
        auto r = content();
        const bool eq = kind() == "EQ",
                   compressor = kind() == "Compressor" || kind() == "Instruments";
        rackHeight = compressor ? 308 : 180;
        presets.setBounds(r.getX(), 8, std::max(100, r.getWidth() - 268), 24);
        savePreset.setBounds(r.getRight() - 258, 8, 114, 24);
        defaultPreset.setBounds(r.getRight() - 140, 8, 140, 24);
        headerY = eq ? 60 : std::max(60, (getHeight() - (rackHeight + 124)) / 2);
        rackY = headerY + 118;
        removeEffect.setBounds(r.getRight() - 100, headerY + 42, 100, 22);
        enabled.setBounds(eq ? r.getX() : r.getCentreX() - 55, headerY + 76, 110, 24);
        if(externalEditor)externalEditor->setBounds(190,40,std::max(1,getWidth()-190),std::max(1,getHeight()-40));
        if(stemEditor)stemEditor->setBounds(r.getX(),40,r.getWidth(),getHeight()-40);
        if(dynamicsEditor)dynamicsEditor->setBounds(r.getX(),40,r.getWidth(),getHeight()-40);
        graph.setBounds(r.getX(), headerY + 102, r.getWidth(),
                        std::max(40, getHeight() - headerY - 141));
        for (int i = 0; i < rooms.size(); ++i)
            rooms[i]->setBounds(r.getX() + r.getWidth() / 2 - 105 + i * 70, headerY + 43, 70, 24);
        const int count = knobs.size(), columns = compressor ? 3 : std::max(1, count),
                  left = r.getX() + 128, usable = r.getWidth() - 140;
        for (int i = 0; i < count; ++i) {
            int row = compressor ? i / 3 : 0, col = compressor ? i % 3 : i;
            knobs[i]->setBounds(left + col * usable / columns, rackY + 16 + row * 146,
                                usable / columns, 130);
        }
    }

  private:
    Session &session;
    std::vector<ID> insertionTargets;
    ID track;
    bool item = false;
    String trackName = "Master";
    std::function<void(String)> error;
    var settings;
    uint64 loadedRevision = ~uint64(0);
    ListBox chain;
    TextButton add, remove, removeEffect, savePreset, defaultPreset;
    std::unique_ptr<CatDynamicsEditor> dynamicsEditor;
    std::unique_ptr<ExternalEffectEditor> externalEditor;
    String externalEditorKey;
    void openExternalEditor() {
        if(kind()!="External")return;
        auto plugin=session.audio.externalEffect(track,key());
        if(!plugin)return;
        if(externalEditor && externalEditorKey==key() && externalEditor->uses(plugin))return;
        externalEditor.reset();externalEditorKey=key();
        externalEditor=std::make_unique<ExternalEffectEditor>(std::move(plugin),
            [this](const KeyPress &press){return globalKey && globalKey(press);},
            [this](bool down){if(globalKeyState)globalKeyState(down);});
        addAndMakeVisible(*externalEditor);resized();
    }
    ComboBox presets;
    Array<var> presetEntries;
    var presetLibrary;
    bool presetsLoaded = false;
    int64 presetRevision = -1;
    int presetPoll = 0;
    fxui::EnableButton enabled;
    OwnedArray<TextButton> rooms;
    OwnedArray<fxui::Knob> knobs;
    fxui::EQGraph graph;
    std::unique_ptr<CatStemEditor> stemEditor;
    int selected = -1, headerY = 24, rackY = 140, rackHeight = 180;
    juce::Rectangle<int> content() const {
        return {210, 0, std::max(200, getWidth() - 230), getHeight()};
    }
    void load() {
        loadedRevision = session.revision;
        settings = var();
        if (item) {
            for(const auto &song:session.project().songs) for(const auto &t:song.tracks) for(const auto &clip:t.clips)
                if(clip.id==track) { trackName=text(clip.name); if(clip.fxJSON) settings=JSON::parse(text(*clip.fxJSON)); }
        } else if (track.empty()) {
            if (session.project().masterFXJSON)
                settings = JSON::parse(text(*session.project().masterFXJSON));
        } else
            for (const auto &song : session.project().songs)
                for (const auto &t : song.tracks)
                    if (t.id == track) {
                        trackName = text(t.name);
                        if (t.fxJSON)
                            settings = JSON::parse(text(*t.fxJSON));
                    }
    }
    String key() const {
        auto values = list(get(settings, "inserted"));
        return selected >= 0 && selected < values.size() ? values[selected].toString() : String();
    }
    String kind() const {
        auto k = key();
        if(k.startsWith("External:"))return "External";
        for (auto instance : list(get(settings, "instances")))
            if ("Native:" + str(instance, "id") == k || "Instance:" + str(instance, "id") == k)
                return str(instance, "kind");
        return k;
    }
    var current() const {
        auto k = key();
        for(auto plugin:list(get(settings,"externalPlugins")))if(k=="External:"+str(plugin,"id"))return plugin;
        for (auto instance : list(get(settings, "instances")))
            if ("Native:" + str(instance, "id") == k || "Instance:" + str(instance, "id") == k)
                return get(instance, "settings");
        return settings;
    }
    int getNumRows() override { return list(get(settings, "inserted")).size(); }
    void paintListBoxItem(int row, Graphics &g, int width, int height, bool isSelected) override {
        auto keys = list(get(settings, "inserted"));
        if (row >= keys.size())
            return;
        auto k = keys[row].toString(), name = k;
        var s = settings;
        if(k.startsWith("External:"))for(auto plugin:list(get(settings,"externalPlugins")))if(k=="External:"+str(plugin,"id")){name=str(plugin,"name");s=plugin;break;}
        for (auto instance : list(get(settings, "instances")))
            if ("Native:" + str(instance, "id") == k || "Instance:" + str(instance, "id") == k) {
                name = str(instance, "kind");
                s = get(instance, "settings");
                break;
            }
        if (isSelected) {
            g.setColour(Colour(0xff458e22));
            g.fillAll();
        }
        const bool active=fxui::isEnabled(k.startsWith("External:")?"External":name,s);
        g.setColour(Colours::white.withAlpha(active ? .18f : .05f));
        g.fillRect(0, 0, 30, height);
        g.setColour(active ? Colours::white : theme::secondary);
        g.setFont(theme::semiboldFont(10));
        g.drawText("By", 0, 0, 30, height, Justification::centred);
        g.setFont(theme::semiboldFont(12));
        g.drawText(name, 35, 0, width - 40, height, Justification::centredLeft);
    }
    void selectedRowsChanged(int row) override {
        selected = row;
        show();
    }
    void listBoxItemDoubleClicked(int row,const MouseEvent &) override {chain.selectRow(row);if(kind()=="External")openExternalEditor();}
    void listBoxItemClicked(int row, const MouseEvent &e) override {
        chain.selectRow(row);
        if ((e.position.x < 30 || e.mods.isAltDown()) && !e.mods.isPopupMenu()) {
            auto s = current();
            auto k = fxui::enabledKey(kind());
            if (k.isNotEmpty()) {
                fxui::enable(kind(), s, !fxui::isEnabled(kind(), s));
                commit();
                show();
            }
        }
        if(e.mods.isPopupMenu()) {
            if(e.mods.isAltDown()){erase();return;}
            PopupMenu menu;menu.addItem(1,"Remover");
            menu.showMenuAsync(PopupMenu::Options().withTargetComponent(&chain),[safe=SafePointer<EffectsPanel>(this)](int choice){if(safe && choice==1)safe->erase();});
        }
    }

    void show() {
        stemEditor.reset();
        dynamicsEditor.reset();
        knobs.clear();
        refreshPresets();
        const auto k = kind();
        if(k=="External")openExternalEditor();else externalEditor.reset();
        const bool available = k.isNotEmpty() && fxui::enabledKey(k).isNotEmpty();
        enabled.setVisible(available&&k!="CatStemSeparation 5"&&k!="External"&&k!="CatLive Trigger"&&k!="Cat Gate");
        removeEffect.setVisible(k.isNotEmpty()&&k!="External"&&k!="CatLive Trigger"&&k!="Cat Gate");
        remove.setEnabled(k.isNotEmpty());
        for (int i = 0; i < rooms.size(); ++i) {
            rooms[i]->setVisible(k == "Reverb");
            rooms[i]->setToggleState((int)num(current(), "reverbRoom", 1) == i,
                                     dontSendNotification);
        }
        graph.setVisible(k == "EQ");
        enabled.checkbox = k == "EQ";
        if (!available) {
            resized();
            repaint();
            return;
        }
        auto s = current();
        if(k!="External")fxui::defaults(s);
        enabled.setToggleState(fxui::isEnabled(k, s), dontSendNotification);
        graph.settings = s;
        if (k == "CatLive Trigger" || k == "Cat Gate") {
            const auto dynamicsKey = key();
            dynamicsEditor = std::make_unique<CatDynamicsEditor>(k, session.mediaDirectory, [this] { return current(); }, [this] { commit(); chain.repaint(); }, error,
                [this, dynamicsKey] { session.audio.previewDynamics(track, dynamicsKey, current()); });
            addAndMakeVisible(*dynamicsEditor);
        }
        if(k=="CatStemSeparation 5") {
            auto stemKey=key();
            stemEditor=std::make_unique<CatStemEditor>(trackName,[this]{return current();},[this,stemKey](var value,bool save){
                session.audio.previewStemMix(track,stemKey,stemMix::decode(value));
                if(save){commit();chain.repaint();}
            },[this,stemKey]{return session.audio.stemStatus(track,stemKey);});
            addAndMakeVisible(*stemEditor);
        }
        if (k == "Compressor") {
            knob("Threshold", "threshold", -60, 0, .1, " dB");
            knob("Ratio", "ratio", 1, 20, .1, " :1");
            knob("Gain", "makeup", -12, 24, .1, " dB");
            knob("Attack", "attack", .1, 200, .1, " ms", 1000);
            knob("Release", "release", 10, 3000, 1, " ms", 1000);
        }
        if (k == "Delay") {
            knob("Time", "delayTime", 10, 2000, 1, " ms", 1000);
            knob("Feedback", "feedback", 0, 90, .1, " %");
            knob("Mix", "delayMix", 0, 100, .1, " %");
        }
        if (k == "Reverb") {
            knob("Mix", "reverbMix", 0, 100, .1, " %");
            knob("Decay", "reverbDecay", .1, 20, .1, " s");
            knob("Low Cut", "reverbLowCut", 20, 2000, 1, " Hz");
            knob("High Cut", "reverbHighCut", 2000, 20000, 1, " Hz");
        }
        if (k == "Limiter") {
            knob("Input Gain", "inputGain", -24, 24, .1, " dB", 1, "limiter");
            knob("Ceiling", "ceiling", -24, 0, .1, " dB", 1, "limiter");
            knob("Release", "release", 10, 3000, 1, " ms", 1000, "limiter");
        }
        if (k == "Pitch")
            knob("Semitons", "pitchSemitones", -12, 12, 1, " st");
        if (k == "Instruments") {
            auto parameters = get(s, "instrumentParameters");
            if (!parameters.isObject()) {
                parameters = object();
                put(s, "instrumentParameters", parameters);
            }
            for (const auto &item : std::map<String, double>{{"gain", 0},
                                                             {"attack", 0},
                                                             {"hold", 10},
                                                             {"decay", 10},
                                                             {"sustain", 1},
                                                             {"release", .3}})
                if (get(parameters, Identifier(item.first)).isVoid())
                    put(parameters, Identifier(item.first), item.second);
            knob("Gain", "gain", -24, 12, .1, " dB", 1, "instrumentParameters");
            knob("Attack", "attack", 0, 10000, 1, " ms", 1000, "instrumentParameters");
            knob("Hold", "hold", 0, 10000, 1, " ms", 1000, "instrumentParameters");
            knob("Decay", "decay", 1, 10000, 1, " ms", 1000, "instrumentParameters");
            knob("Sustain", "sustain", 0, 100, .1, " %", 100, "instrumentParameters");
            knob("Release", "release", 1, 20000, 1, " ms", 1000, "instrumentParameters");
        }
        resized();
        repaint();
        chain.repaint();
    }
    void knob(String title, String property, double low, double high, double step, String suffix,
              double multiplier = 1, String group = {}) {
        auto s = group.isNotEmpty() ? get(current(), Identifier(group)) : current();
        auto *k = knobs.add(new fxui::Knob(
            title, low, high, step, num(s, Identifier(property)) * multiplier, suffix,
            [this, property, multiplier, group](double value) {
                auto s = group.isNotEmpty() ? get(current(), Identifier(group)) : current();
                put(s, Identifier(property), value / multiplier);
            },
            [this] { commit(); }));
        addAndMakeVisible(k);
        if (property == "attack" || property == "release" || property == "delayTime")
            k->slider.setSkewFactor(.4);
    }
    class InsertWindow final : public DocumentWindow {
      public:
        InsertWindow()
            : DocumentWindow("Inserir efeito", theme::panel, DocumentWindow::closeButton, true) {
            setUsingNativeTitleBar(false);
            setTitleBarButtonsRequired(DocumentWindow::closeButton, false);
            setTitleBarHeight(32);
            setResizable(false, false);
        }
        void closeButtonPressed() override { setVisible(false); }
    };
    std::unique_ptr<InsertWindow> insertWindow;
    void addMenu() {
        if (insertWindow && insertWindow->isVisible()) {
            insertWindow->toFront(true);
            return;
        }
        insertWindow = std::make_unique<InsertWindow>();
        insertWindow->setLookAndFeel(&getLookAndFeel());
        const auto safe = SafePointer<EffectsPanel>(this);
        auto *panel = new EffectInsertPanel(
            session.mediaDirectory,
            [safe](String kind, String id) { return safe && safe->insert(kind, id); },
            [safe] {
                if (safe && safe->insertWindow)
                    safe->insertWindow->setVisible(false);
            }, !item && !track.empty() && insertionTargets.size() <= 1, item || !track.empty());
        panel->setSize(460, 214);
        insertWindow->setContentOwned(panel, true);
        panel->updateLayout();
        insertWindow->centreAroundComponent(this, 460, 246);
        insertWindow->setVisible(true);
        insertWindow->toFront(true);
    }
    bool insert(const String &kind, const String &instrument) {
        try {
            if (session.busy) return false;
            if (!item && track.empty() &&
                (kind == "Instruments" || kind == "CatStemSeparation 5" ||
                 (kind == "External" && str(JSON::parse(instrument), "category").containsIgnoreCase("Instrument"))))
                return false;
            if(kind=="CatStemSeparation 5") {
                if(insertionTargets.size()>1)throw std::runtime_error("Selecione uma pista para inserir CatStemSeparation 5.");
            }
            if (kind == "Instruments") {
                auto source = instrumentAssets::resolve(instrument, session.mediaDirectory);
                auto target = session.mediaDirectory.getChildFile("Instruments/" + instrument + ".sf2");
                if (!instrumentAssets::validBank(source)) throw std::runtime_error("Download the instrument before applying it.");
                target.getParentDirectory().createDirectory();
                if (source != target && !source.copyFileTo(target)) throw std::runtime_error("Could not copy the instrument to the project.");
            }
            auto targets = item || insertionTargets.empty() ? std::vector<ID>{track} : insertionTargets;
            if (kind == "Instruments" && targets.size() != 1) throw std::runtime_error("Escolha apenas uma pista para inserir um instrumento.");
            std::map<ID, var> changes;
            String ownKey;
            for (const auto &target : targets) {
                auto next = target == track ? settings.clone() : fxchain::settings(session, target).clone();
                fxui::defaults(next);
                auto inserted = list(get(next, "inserted"));
                String key = kind;
                if (kind == "External") {
                    auto plugin = JSON::parse(instrument);
                    if (!plugin.isObject() || str(plugin, "classID").isEmpty()) throw std::runtime_error("Selecione um plugin VST3.");
                    put(plugin, "id", text(uuid())); put(plugin, "bypassed", false);
                    auto plugins = list(get(next, "externalPlugins")); plugins.add(plugin); put(next, "externalPlugins", plugins);
                    key = "External:" + str(plugin, "id");
                } else {
                    if ((item||kind=="CatStemSeparation 5") && inserted.contains(var(kind))) { chain.selectRow(inserted.indexOf(var(kind))); return true; }
                    auto initialize = [&](var &value) {
                        fxui::reset(kind, value); fxui::defaults(value); fxui::enable(kind, value, true);
                        if(kind=="CatStemSeparation 5")put(value,"stemMix",stemMix::defaults());
                        if (kind == "Instruments") { put(value, "instrumentID", instrument); put(value, "instrumentParameters", fxui::instrumentParameters(instrument)); }
                        fxpresets::Store().applyDefault(kind, value);
                    };
                    if (inserted.contains(var(kind))) {
                        auto instance = object(), value = object(); initialize(value);
                        put(value, "inserted", Array<var>{kind});
                        const auto id = text(uuid()); put(instance, "id", id); put(instance, "kind", kind); put(instance, "settings", value);
                        auto instances = list(get(next, "instances")); instances.add(instance); put(next, "instances", instances);
                        key = "Native:" + id;
                    } else initialize(next);
                }
                inserted.add(key); put(next, "inserted", inserted); changes.emplace(target, next);
                if (target == track) ownKey = key;
            }
            session.configureEffects(changes);
            load(); fxui::defaults(settings); refreshPresets(); chain.updateContent();
            chain.selectRow(list(get(settings, "inserted")).indexOf(var(ownKey)));
            if (kind == "External") openExternalEditor();
            return true;
        } catch (const std::exception &e) { error(String::fromUTF8(e.what())); return false; }
    }
    void erase() {
        if (selected < 0)
            return;
        auto inserted = list(get(settings, "inserted"));
        const auto removed = key();
        inserted.remove(selected);
        put(settings, "inserted", inserted);
        fxui::reset(removed, settings);
        auto plugins=list(get(settings,"externalPlugins"));
        for(int i=plugins.size();--i>=0;)if("External:"+str(plugins[i],"id")==removed)plugins.remove(i);
        put(settings,"externalPlugins",plugins);
        if(removed==externalEditorKey)externalEditor.reset();
        auto instances = list(get(settings, "instances"));
        for (int i = instances.size(); --i >= 0;)
            if ("Native:" + str(instances[i], "id") == removed ||
                "Instance:" + str(instances[i], "id") == removed)
                instances.remove(i);
        put(settings, "instances", instances);
        commit();
        chain.updateContent();
        if (inserted.isEmpty()) {
            selected = -1;
            chain.deselectAllRows();
            show();
        } else {
            selected = std::min(selected, inserted.size() - 1);
            chain.selectRow(selected);
            show();
        }
    }
    bool commit() {
        try {
            if (session.busy)
                return false;
            session.configureEffects(track, settings);
            load();fxui::defaults(settings);
            refreshPresets();
            return true;
        } catch (const std::exception &e) {
            load();
            fxui::defaults(settings);
            MessageManager::callAsync(
                [safe = SafePointer<EffectsPanel>(this), message = String::fromUTF8(e.what())] {
                    if (safe) {
                        safe->show();
                        safe->error(message);
                    }
                });
            return false;
        }
    }
    var factoryPreset() const {
        auto value = object(); fxui::defaults(value);
        if (kind() == "Instruments") {
            put(value, "instrumentID", str(current(), "instrumentID"));
            put(value, "instrumentParameters", fxui::instrumentParameters(str(current(), "instrumentID")));
        }
        return fxpresets::capture(kind(), value, "Factory");
    }
    void refreshPresets(bool reload = false) {
        const bool available = fxpresets::fields(kind()).size() > 0;
        presets.setVisible(available); savePreset.setVisible(available); defaultPreset.setVisible(available);
        if (!available) return;
        try {
            if (reload || !presetsLoaded) { presetLibrary = fxpresets::Store().read(); presetRevision = fxpresets::Store().revision(); presetsLoaded = true; }
            const auto identity = fxpresets::identity(kind(), current());
            presetEntries = fxpresets::Store::entries(presetLibrary, identity);
            const auto defaultID = str(get(presetLibrary, "defaults"), Identifier(identity));
            presets.clear(dontSendNotification);
            const auto star = String::fromUTF8(" ★");
            presets.addItem("Default" + (defaultID.isEmpty() ? star : ""), 1);
            int selection = fxpresets::matches(kind(), current(), factoryPreset()) ? 1 : 0;
            for (int i = 0; i < presetEntries.size(); ++i) {
                const auto &preset = presetEntries[i];
                presets.addItem(str(preset,"name") + (str(preset,"id") == defaultID ? star : ""), i + 2);
                if (fxpresets::matches(kind(), current(), preset)) selection = i + 2;
            }
            presets.setTextWhenNothingSelected("Personalizado"); presets.setSelectedId(selection, dontSendNotification);
            defaultPreset.setEnabled(selection != 0);
        } catch (const std::exception &e) { presets.setText(String::fromUTF8(e.what()), dontSendNotification); defaultPreset.setEnabled(false); }
    }
    void loadPreset() {
        const int index = presets.getSelectedId(); if (index < 1) return;
        try {
            const auto preset = index == 1 ? factoryPreset() : presetEntries[index - 2];
            auto value = current(); fxpresets::apply(kind(), value, preset);
            commit(); show();
        } catch (const std::exception &e) { error(String::fromUTF8(e.what())); }
    }
    void saveCurrentPreset() {
        const auto effect = key();
        auto *dialog = new AlertWindow("Salvar preset", String::fromUTF8("Nome da configuração deste plugin"), MessageBoxIconType::NoIcon);
        dialog->addTextEditor("name", ""); dialog->addButton("Salvar", 1, KeyPress(KeyPress::returnKey)); dialog->addButton("Cancelar", 0, KeyPress(KeyPress::escapeKey));
        dialog->enterModalState(true, ModalCallbackFunction::create([safe = SafePointer<EffectsPanel>(this), dialog, effect](int result) {
            if (!safe || result != 1 || safe->key() != effect) return;
            try {
                fxpresets::Store store; auto library = store.read();
                fxpresets::Store::save(library, fxpresets::capture(safe->kind(), safe->current(), dialog->getTextEditorContents("name")));
                store.write(library); safe->refreshPresets(true);
            } catch (const std::exception &e) { safe->error(String::fromUTF8(e.what())); }
        }), true);
    }
    void makePresetDefault() {
        const int index = presets.getSelectedId(); if (index < 1) return;
        try {
            fxpresets::Store store; auto library = store.read();
            fxpresets::Store::setDefault(library, fxpresets::identity(kind(), current()), index == 1 ? String() : str(presetEntries[index - 2], "id"));
            store.write(library); refreshPresets(true);
        } catch (const std::exception &e) { error(String::fromUTF8(e.what())); }
    }
    void timerCallback() override {
        if(externalEditor&&!externalEditor->uses(session.audio.externalEffect(track,externalEditorKey))) {externalEditor.reset();openExternalEditor();}
        for(auto plugin:list(get(settings,"externalPlugins")))if(auto processor=session.audio.externalEffect(track,"External:"+str(plugin,"id")))
            if(processor->consumeEdited())session.dirty=true;
        if (loadedRevision != session.revision) {
            const auto previous = JSON::toString(settings, true), selectedKey = key();
            load(); fxui::defaults(settings);
            if (JSON::toString(settings, true) != previous) {
                const auto keys = list(get(settings, "inserted"));
                selected = keys.indexOf(var(selectedKey));
                if (selected < 0 && !keys.isEmpty()) selected = 0;
                chain.updateContent();
                if (selected < 0) chain.deselectAllRows(); else chain.selectRow(selected);
                show();
            }
        }
        if (++presetPoll % 10 == 0 && isShowing() && fxpresets::Store().revision() != presetRevision) refreshPresets(true);
        if (isShowing())
            repaint();
    }
    void paintMeters(Graphics &g) {
        const auto r = content();
        const int top = rackY + std::max(38, (rackHeight - 116) / 2), height = 110,
                  x = r.getX() + 28;
        g.setColour(theme::secondary);
        g.setFont(theme::font(8));
        g.drawText("IN", x - 5, top - 20, 26, 18, Justification::centred);
        g.drawText("OUT", x + 45, top - 20, 30, 18, Justification::centred);
        const auto levels = session.audio.fxLevels(track);
        for (int i = 0; i < 4; ++i) {
            const int bx = x + (i / 2) * 50 + (i % 2) * 10;
            g.setColour(Colours::black);
            g.fillRect(bx, top, 7, height);
            const float level = i < 2 ? levels.first : levels.second;
            const auto amount =
                jlimit(0.f, 1.f, (Decibels::gainToDecibels(level, -60.f) + 60) / 60);
            g.setColour(level >= 1 ? Colours::red : theme::green);
            g.fillRect(bx, top + height - (int)(amount * height), 7, (int)(amount * height));
        }
        g.setColour(theme::secondary);
        for (int db : {0, -24, -60})
            g.drawText(String(db), x + 20, top + (int)(-db / 60.f * height) - 5, 24, 12,
                       Justification::centred);
    }
};
} // namespace catlive
