#pragma once
#include "Common.h"
namespace catlive::fxui {
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
