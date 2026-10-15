#pragma once
#include "Session.h"
#include "Localization.h"
#include "EffectInsertPanel.h"
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
    return kind == "EQ"            ? "eqEnabled"
           : kind == "Compressor"  ? "compressorEnabled"
           : kind == "Delay"       ? "delayEnabled"
           : kind == "Reverb"      ? "reverbEnabled"
           : kind == "Limiter"     ? "limiterEnabled"
           : kind == "Pitch"       ? "pitchEnabled"
           : kind == "Instruments" ? "instrumentBypassed"
                                   : "";
}
inline bool isEnabled(const String &kind, const var &settings) {
    const auto key = enabledKey(kind);
    return key.isNotEmpty() && (kind == "Instruments" ? !flag(settings, "instrumentBypassed")
                                                      : flag(settings, Identifier(key)));
}
inline void enable(const String &kind, var &settings, bool value) {
    const auto key = enabledKey(kind);
    if (key.isNotEmpty())
        put(settings, Identifier(key), kind == "Instruments" ? !value : value);
}
inline void defaults(var &s) {
    if (!s.isObject())
        s = object();
    const std::map<String, double> values{
        {"threshold", -20},       {"ratio", 4},         {"attack", .005},
        {"release", .1},          {"makeup", 0},        {"delayTime", .25},
        {"feedback", 25},         {"delayMix", 20},     {"reverbMix", 20},
        {"reverbRoom", 1},        {"reverbDecay", 2},   {"reverbLowCut", 80},
        {"reverbHighCut", 12000}, {"pitchSemitones", 0}};
    for (auto &v : values)
        if (get(s, Identifier(v.first)).isVoid())
            put(s, Identifier(v.first), v.second);
    if (!get(s, "limiter").isObject()) {
        auto l = object();
        put(l, "ceiling", -.1);
        put(l, "release", .1);
        put(l, "inputGain", 0);
        put(s, "limiter", l);
    }
    if (!get(s, "inserted").isArray())
        put(s, "inserted", Array<var>{});
    if (!get(s, "bands").isArray()) {
        Array<var> bands;
        const double frequencies[]{30, 200, 1000, 5000, 18000};
        for (int i = 0; i < 5; ++i) {
            auto b = object();
            put(b, "id", text(uuid()));
            put(b, "frequency", frequencies[i]);
            put(b, "gain", 0);
            put(b, "q", .707);
            put(b, "type", i == 0 ? "lowCut" : i == 4 ? "highCut" : "bell");
            put(b, "slope", 12);
            put(b, "enabled", true);
            bands.add(b);
        }
        put(s, "bands", bands);
    }
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
    Slider slider;

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
        if (e.mods.isPopupMenu())
            menu(e.position);
        repaint();
    }
    void mouseDoubleClick(const MouseEvent &e) override {
        if (!e.mods.isPopupMenu() && selected < 0)
            add(e.position);
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
        if (dragging && commit)
            commit();
        dragging = false;
    }
    void mouseWheelMove(const MouseEvent &, const MouseWheelDetails &wheel) override {
        auto bands = list(get(settings, "bands"));
        if (selected < 0 || selected >= bands.size())
            return;
        auto &b = bands.getReference(selected);
        put(b, "q", jlimit(.1, 18., num(b, "q", .707) * std::pow(1.15, wheel.deltaY > 0 ? 1 : -1)));
        put(settings, "bands", bands);
        if (changed)
            changed();
        if (commit)
            commit();
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
    bool dragging = false;
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
    void menu(Point<float> p) {
        PopupMenu menu;
        auto bands = list(get(settings, "bands"));
        if (selected < 0)
            menu.addItem(1, "Adicionar banda", bands.size() < 10);
        else {
            auto band = bands[selected];
            menu.addItem(2, "Excluir banda");
            menu.addItem(3, "Ativada", true, flag(band, "enabled", true));
            menu.addSeparator();
            const StringArray types{"bell", "lowCut", "highCut", "lowShelf", "highShelf"},
                names{"Bell", "Low Cut", "High Cut", "Low Shelf", "High Shelf"};
            for (int i = 0; i < 5; ++i)
                menu.addItem(10 + i, names[i], true, str(band, "type") == types[i]);
            PopupMenu slopes;
            const int values[]{6, 12, 24, 36, 48, 72, 96, 192};
            for (int i = 0; i < 8; ++i)
                slopes.addItem(20 + i, String(values[i]) + " dB/oct", true,
                               (int)num(band, "slope", 12) == values[i]);
            menu.addSubMenu("Slope", slopes);
        }
        menu.showMenuAsync(PopupMenu::Options().withTargetComponent(this),
                           [safe = SafePointer<EQGraph>(this), p](int action) {
                               if (!safe || !action)
                                   return;
                               if (action == 1) {
                                   safe->add(p);
                                   return;
                               }
                               if (action == 2) {
                                   safe->remove();
                                   return;
                               }
                               auto bands = list(get(safe->settings, "bands"));
                               if (safe->selected < 0 || safe->selected >= bands.size())
                                   return;
                               auto &b = bands.getReference(safe->selected);
                               if (action == 3)
                                   put(b, "enabled", !flag(b, "enabled", true));
                               if (action >= 10 && action < 15) {
                                   const char *types[]{"bell", "lowCut", "highCut", "lowShelf",
                                                       "highShelf"};
                                   put(b, "type", types[action - 10]);
                               }
                               if (action >= 20 && action < 28) {
                                   const int values[]{6, 12, 24, 36, 48, 72, 96, 192};
                                   put(b, "slope", values[action - 20]);
                               }
                               put(safe->settings, "bands", bands);
                               safe->update();
                           });
    }
};
} // namespace fxui
class EffectsPanel final : public Component, private ListBoxModel, private Timer {
  public:
    EffectsPanel(Session &s, ID target, std::function<void(String)> report)
        : session(s), track(std::move(target)), error(std::move(report)), chain("FX", this) {
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
        startTimerHz(20);
    }
    void paint(Graphics &g) override {
        g.fillAll(Colour(0xff242424));
        g.setColour(Colour(0xff181818));
        g.fillRect(0, 0, 190, getHeight());
        g.setColour(Colour(0xff202020));
        g.fillRect(0, getHeight() - 40, 190, 40);
        auto r = content();
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(14));
        if (kind().isEmpty()) {
            g.drawText("Adicionar efeito", r, Justification::centred);
            return;
        }
        g.drawText("CatLive " + kind() + String::fromUTF8(" · ") + trackName, r.getX(), headerY, r.getWidth() - 36,
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
        headerY = eq ? 24 : std::max(24, (getHeight() - (rackHeight + 124)) / 2);
        rackY = headerY + 118;
        removeEffect.setBounds(r.getRight() - 100, headerY + 42, 100, 22);
        enabled.setBounds(eq ? r.getX() : r.getCentreX() - 55, headerY + 76, 110, 24);
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
    ID track;
    String trackName = "Master";
    std::function<void(String)> error;
    var settings;
    ListBox chain;
    TextButton add, remove, removeEffect;
    fxui::EnableButton enabled;
    OwnedArray<TextButton> rooms;
    OwnedArray<fxui::Knob> knobs;
    fxui::EQGraph graph;
    int selected = -1, headerY = 24, rackY = 140, rackHeight = 180;
    juce::Rectangle<int> content() const {
        return {210, 0, std::max(200, getWidth() - 230), getHeight()};
    }
    void load() {
        settings = var();
        if (track.empty()) {
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
        for (auto instance : list(get(settings, "instances")))
            if ("Native:" + str(instance, "id") == k || "Instance:" + str(instance, "id") == k)
                return str(instance, "kind");
        return k;
    }
    var current() const {
        auto k = key();
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
        g.setColour(Colours::white.withAlpha(fxui::isEnabled(name, s) ? .18f : .05f));
        g.fillRect(0, 0, 30, height);
        g.setColour(fxui::isEnabled(name, s) ? Colours::white : theme::secondary);
        g.setFont(theme::semiboldFont(10));
        g.drawText("By", 0, 0, 30, height, Justification::centred);
        g.setFont(theme::semiboldFont(12));
        g.drawText(name, 35, 0, width - 40, height, Justification::centredLeft);
    }
    void selectedRowsChanged(int row) override {
        selected = row;
        show();
    }
    void listBoxItemClicked(int row, const MouseEvent &e) override {
        chain.selectRow(row);
        if (e.position.x < 30 && !e.mods.isPopupMenu()) {
            auto s = current();
            auto k = fxui::enabledKey(kind());
            if (k.isNotEmpty()) {
                fxui::enable(kind(), s, !fxui::isEnabled(kind(), s));
                commit();
                show();
            }
        }
        if (e.mods.isPopupMenu()) {
            PopupMenu m;
            m.addItem(1, "Mover acima", row > 0);
            m.addItem(2, "Mover abaixo", row + 1 < getNumRows());
            m.addItem(3, "Excluir");
            m.showMenuAsync(PopupMenu::Options().withTargetComponent(&chain),
                            [safe = SafePointer<EffectsPanel>(this)](int a) {
                                if (!safe || !a)
                                    return;
                                if (a == 3)
                                    safe->erase();
                                else {
                                    auto items = list(get(safe->settings, "inserted"));
                                    const int next = safe->selected + (a == 1 ? -1 : 1);
                                    if (next < 0 || next >= items.size())
                                        return;
                                    items.move(safe->selected, next);
                                    put(safe->settings, "inserted", items);
                                    safe->commit();
                                    safe->chain.updateContent();
                                    safe->chain.selectRow(next);
                                    safe->chain.repaint();
                                }
                            });
        }
    }
    void show() {
        knobs.clear();
        const auto k = kind();
        const bool available = k.isNotEmpty() && fxui::enabledKey(k).isNotEmpty();
        enabled.setVisible(available);
        removeEffect.setVisible(k.isNotEmpty());
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
        fxui::defaults(s);
        enabled.setToggleState(fxui::isEnabled(k, s), dontSendNotification);
        graph.settings = s;
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
            });
        panel->setSize(460, 214);
        insertWindow->setContentOwned(panel, true);
        panel->updateLayout();
        insertWindow->centreAroundComponent(this, 460, 246);
        insertWindow->setVisible(true);
        insertWindow->toFront(true);
    }
    bool insert(const String &kind, const String &instrument) {
        try {
            if (kind == "Instruments") {
                auto source = instrumentAssets::resolve(instrument, session.mediaDirectory),
                     target =
                         session.mediaDirectory.getChildFile("Instruments/" + instrument + ".sf2");
                if (!instrumentAssets::validBank(source))
                    throw std::runtime_error("Download the instrument before applying it.");
                target.getParentDirectory().createDirectory();
                if (source != target && !source.copyFileTo(target))
                    throw std::runtime_error("Could not copy the instrument to the project.");
            }
            auto initialize = [&](var &s) {
                fxui::defaults(s);
                fxui::enable(kind, s, true);
                if (kind == "Instruments") {
                    put(s, "instrumentID", instrument);
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
                    put(s, "instrumentParameters", parameters);
                }
            };
            auto inserted = list(get(settings, "inserted"));
            String key = kind;
            if (inserted.contains(var(kind))) {
                auto instance = object(), s = object();
                initialize(s);
                put(s, "inserted", Array<var>{kind});
                const auto id = text(uuid());
                put(instance, "id", id);
                put(instance, "kind", kind);
                put(instance, "settings", s);
                auto instances = list(get(settings, "instances"));
                instances.add(instance);
                put(settings, "instances", instances);
                key = "Native:" + id;
            } else
                initialize(settings);
            inserted.add(key);
            put(settings, "inserted", inserted);
            if (!commit())
                return false;
            chain.updateContent();
            chain.selectRow(inserted.size() - 1);
            return true;
        } catch (const std::exception &e) {
            error(String::fromUTF8(e.what()));
            return false;
        }
    }
    void erase() {
        if (selected < 0)
            return;
        auto inserted = list(get(settings, "inserted"));
        const auto removed = key();
        inserted.remove(selected);
        put(settings, "inserted", inserted);
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
    void timerCallback() override {
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
