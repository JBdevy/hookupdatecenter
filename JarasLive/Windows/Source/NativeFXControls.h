#pragma once
#include "Common.h"
namespace catlive::fxui {
inline Colour dialAccent(const String &kind) {
    if (kind == "EQ" || kind == "Arpeggiator" || kind == "Pitch") return Colour(0xffc2a8f7);
    if (kind == "Compressor" || kind == "Limiter" || kind == "Cat Gate" || kind == "CatLive Trigger" || kind == "Amp")
        return Colour(0xffedb869);
    if (kind == "Chorus" || kind == "Phaser") return Colour(0xff7ac7ed);
    return Colour(0xff7dd9bf);
}
inline void paintRack(Graphics &g, juce::Rectangle<float> area) {
    g.setGradientFill(ColourGradient(Colour(0xff1b1d24), area.getTopLeft(), Colour(0xff121418), area.getBottomLeft(), false));
    g.fillRoundedRectangle(area, 9);
    g.setColour(Colours::white.withAlpha(.1f));
    g.drawRoundedRectangle(area.reduced(.5f), 9, 1);
}
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
class KnobLook final : public LookAndFeel_V4 {
  public:
    float diameter = 78;
    Colour accent = dialAccent({});
    Font getSliderPopupFont(Slider &) override { return theme::font(12); }
    Label *createSliderTextBox(Slider &s) override {
        auto *l = LookAndFeel_V4::createSliderTextBox(s);
        l->setFont(theme::semiboldFont(12));
        return l;
    }
    void drawRotarySlider(Graphics &g, int x, int y, int w, int h, float value, float start,
                          float end, Slider &) override {
        Graphics::ScopedSaveState state(g);
        const float size = std::min(diameter, float(std::min(w, h)));
        const float scale = size / 78.f;
        g.addTransform(AffineTransform::scale(scale).translated(x + (w - size) * .5f, y + (h - size) * .5f));
        const auto r = juce::Rectangle<float>(0, 0, 78, 78);
        const float cx = r.getCentreX(), cy = r.getCentreY(), radius = 31,
                    angle = start + value * (end - start);
        g.setColour(Colours::white.withAlpha(.5f));
        for (int i = 0; i <= 10; ++i) {
            const float mark = start + (end - start) * i / 10.f;
            const float inner = i % 5 == 0 ? 34.f : 36.f;
            g.drawLine(cx + std::sin(mark) * inner, cy - std::cos(mark) * inner,
                       cx + std::sin(mark) * 38, cy - std::cos(mark) * 38, 1);
        }
        Path base;
        base.addCentredArc(cx, cy, radius, radius, 0, start, end, true);
        g.setColour(Colour(0xff303030));
        g.strokePath(base, PathStrokeType(4, PathStrokeType::curved, PathStrokeType::rounded));
        Path fill;
        fill.addCentredArc(cx, cy, radius, radius, 0, start, angle, true);
        g.setColour(accent);
        g.strokePath(fill, PathStrokeType(3, PathStrokeType::curved, PathStrokeType::rounded));
        g.setGradientFill(ColourGradient(Colour(0xff525252), cx, cy - 26, Colour(0xff262626), cx, cy + 26, false));
        g.fillEllipse(cx - 26, cy - 26, 52, 52);
        g.setColour(Colours::white.withAlpha(.17f));
        g.drawEllipse(cx - 26, cy - 26, 52, 52, 1);
        g.setColour(accent);
        g.drawLine(cx + std::sin(angle) * 11, cy - std::cos(angle) * 11,
                   cx + std::sin(angle) * 23, cy - std::cos(angle) * 23, 3);
    }
};
class DynamicsThresholdMeter final : public Component, private Timer {
    // JUCE handles focus, keyboard adjustments and drag lifetime. The paint and
    // hit-test use exactly the same slider bounds, including at both endpoints.
    class Input final : public ParameterSlider {
        struct MeterLook final : LookAndFeel_V4 {
            int getSliderThumbRadius(Slider &) override { return 0; }
            Slider::SliderLayout getSliderLayout(Slider &s) override {
                Slider::SliderLayout layout;
                layout.sliderBounds = s.getLocalBounds();
                return layout;
            }
        } look;
      public:
        Input() { setLookAndFeel(&look); }
        ~Input() override { setLookAndFeel(nullptr); }
        void paint(Graphics &) override {}
    };
    static Path makeHandle() {
        Path shape;
        shape.startNewSubPath(2.f, 0.5f);
        shape.quadraticTo(0.5f, -0.3f, 0.5f, 1.5f);
        shape.lineTo(0.5f, 8.5f);
        shape.quadraticTo(0.5f, 10.3f, 2.f, 9.5f);
        shape.lineTo(9.f, 6.f);
        shape.lineTo(37.f, 6.f);
        shape.quadraticTo(39.f, 5.f, 37.f, 4.f);
        shape.lineTo(9.f, 4.f);
        shape.closeSubPath();
        return shape;
    }
    const Path handle = makeHandle();
    Input input;
    bool compressor;
    std::array<float, 3> displayed{};
    std::function<std::array<float, 3>()> poll;
    juce::Rectangle<int> rail() const { return {7, 24, 60, std::max(1, getHeight() - 49)}; }
    void timerCallback() override {
        if (!isShowing() || !poll) return;
        auto next = poll();
        for (size_t ch = 0; ch < 2; ++ch) {
            next[ch] = std::max(next[ch], displayed[ch] * .858f);
            if (next[ch] < .0001f) next[ch] = 0;
        }
        next[2] = std::max(next[2], displayed[2] - 1.4f);
        if (next != displayed) { displayed = next; repaint(); }
    }
  public:
    DynamicsThresholdMeter(bool isCompressor, double value, std::function<void(double)> change,
                           std::function<void()> commit, std::function<std::array<float, 3>()> read)
        : compressor(isCompressor), poll(std::move(read)) {
        input.setSliderStyle(Slider::LinearBarVertical);
        input.setTextBoxStyle(Slider::NoTextBox, false, 0, 0);
        input.setRange(compressor ? -60 : -80, 0, .1);
        input.setComponentID(compressor ? "compressor_threshold" : "gate_threshold");
        input.setTitle("Threshold");
        input.setTextValueSuffix(" dB");
        input.setValue(value, dontSendNotification);
        input.setDoubleClickReturnValue(true, compressor ? -20 : -40);
        input.onValueChange = [this, change, commit] {
            change(input.getValue()); repaint();
            if (!input.isMouseButtonDown()) commit();
        };
        input.onDragEnd = std::move(commit);
        addAndMakeVisible(input);
        startTimerHz(30);
    }
    void resized() override { input.setBounds(rail().withLeft(0)); }
    void paint(Graphics &g) override {
        const auto area = rail().toFloat();
        const float top = area.getY(), height = area.getHeight(), left = area.getX();
        const float floor = float(input.getMinimum());
        g.setFont(theme::semiboldFont(11)); g.setColour(theme::secondary);
        g.drawText("Threshold", 0, 0, 70, 22, Justification::centred);
        for (int c = 0; c < 2; ++c) {
            const float x = left + c * 14.f;
            auto bar = juce::Rectangle<float>(x, top, 11.f, height);
            g.setColour(Colour(0xff101013)); g.fillRoundedRectangle(bar, 2);
            const auto db = Decibels::gainToDecibels(displayed[size_t(c)], floor);
            auto fraction = jlimit(0.f, 1.f, 1 - db / floor);
            ColourGradient fill(theme::yellow, x, top, theme::green, x, area.getBottom(), false);
            g.setGradientFill(fill); g.fillRect(bar.removeFromBottom(height * fraction));
        }
        g.setColour(theme::secondary); g.setFont(theme::font(9));
        for (int db = 0; db >= int(floor); db -= 20) {
            const int y = roundToInt(jlimit(top, area.getBottom() - 11, top + height * db / floor - 5));
            g.drawText(String(db), int(left + 31), y, 23, 11, Justification::centredRight);
        }
        const float y = top + height * float(input.getValue()) / floor;
        g.setColour(Colours::white);
        g.fillPath(handle, AffineTransform::translation(left - 7.f, y - 5.f));
        g.setFont(theme::semiboldFont(10));
        g.drawText(String(input.getValue(), 1) + " dB", 0, getHeight()-22, 70, 20, Justification::centred);
        if (!compressor) return;
        const int x = getWidth() - 46;
        g.setFont(theme::semiboldFont(11)); g.setColour(theme::secondary);
        g.drawText("Reduce", x, 0, 46, 22, Justification::centred);
        auto bar = juce::Rectangle<float>(float(x + 16), top, 14, height);
        g.setColour(Colour(0xff101013)); g.fillRoundedRectangle(bar, 2);
        g.setColour(theme::trackMute);
        g.fillRect(bar.removeFromTop(height * jlimit(0.f, 1.f, displayed[2]/24.f)));
        g.setColour(Colours::white); g.setFont(theme::semiboldFont(10));
        g.drawText(String(displayed[2], 1) + " dB", x, getHeight()-22, 46, 20, Justification::centred);
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
        slider.setColour(Slider::textBoxTextColourId, look.accent);
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
    void setAccent(Colour colour) {
        look.accent = colour;
        slider.setColour(Slider::textBoxTextColourId, colour);
        repaint();
    }
    void setDiameter(float size) { look.diameter = size; repaint(); }
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
} // namespace catlive::fxui
