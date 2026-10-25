#pragma once
#include "Session.h"

namespace catlive {
class TransportFadeoutOverlay final : public Component {
  public:
    explicit TransportFadeoutOverlay(Session &value, std::function<void()> cancel = {})
        : session(value), cancelFade(std::move(cancel)) {
        setComponentID("transportFadeoutOverlay");
        setInterceptsMouseClicks(false, true); setWantsKeyboardFocus(false);
        addAndMakeVisible(cancelButton); cancelButton.setButtonText("Cancelar");
        cancelButton.setComponentID("transportFadeoutCancel");
        cancelButton.setWantsKeyboardFocus(false); cancelButton.setMouseClickGrabsKeyboardFocus(false);
        cancelButton.getProperties().set("flat", true); cancelButton.getProperties().set("fontSize", 12.f);
        cancelButton.onClick = [this] {
            try { if (cancelFade) cancelFade(); else session.cancelTransportFadeout(); }
            catch (const std::exception &error) { showWarning(String::fromUTF8(error.what())); }
            update();
        };
        setVisible(false);
    }
    bool isActive() const { return session.transportFadeoutActive(); }
    void showWarning(String message) {
        warning = std::move(message);
        warningUntil = warning.isEmpty() ? 0 : Time::getMillisecondCounterHiRes() + 3500;
        update();
    }
    void update() {
        const bool nextActive = isActive();
        const double now = Time::getMillisecondCounterHiRes();
        if (warningUntil <= now) warning.clear();
        const auto remaining = session.transportFadeoutRemaining();
        const auto duration = session.transportFadeoutDuration();
        secondsLeft = std::isfinite(remaining) ? std::max(0., remaining) : 0;
        secondsTotal = std::isfinite(duration) ? std::max(.001, duration) : 1;
        active = nextActive;
        cancelButton.setVisible(active); cancelButton.setEnabled(active);
        const bool shown = active || warning.isNotEmpty();
        if (isVisible() != shown) setVisible(shown);
        if (shown) { toFront(false); resized(); repaint(); }
    }
    void resized() override {
        const int margin = 12;
        const int width = std::max(0, std::min(280, getWidth() - margin * 2));
        const int height = std::max(0, std::min(110, getHeight() * 35 / 100));
        countdownBounds = {std::max(0, (getWidth() - width) / 2), std::max(0, (getHeight() - height) / 2), width, height};
        const int warningWidth = std::max(0, std::min(380, getWidth() - margin * 2));
        const int warningHeight = std::max(0, std::min(70, countdownBounds.getY() - margin * 2));
        warningBounds = {std::max(0, (getWidth() - warningWidth) / 2), margin, warningWidth, warningHeight};
        cancelButton.setBounds(countdownBounds.getRight() - 94, countdownBounds.getBottom() - 38, 80, 26);
    }
    void paint(Graphics &g) override {
        if (active) {
            card(g, countdownBounds, theme::green);
            auto content = countdownBounds.reduced(14, 10);
            g.setColour(Colours::white); g.setFont(theme::semiboldFont(12));
            g.drawText("Fadeout", content.removeFromTop(24), Justification::centredLeft);
            g.setFont(theme::semiboldFont(22));
            g.drawText(String(secondsLeft, 1) + " s", countdownBounds.reduced(14, 10).removeFromTop(27), Justification::centredRight);
            auto bar = juce::Rectangle<float>((float)countdownBounds.getX() + 14, (float)countdownBounds.getY() + 43,
                                              std::max(0.f, (float)countdownBounds.getWidth() - 28), 5);
            g.setColour(Colours::white.withAlpha(.12f)); g.fillRoundedRectangle(bar, 2.5f);
            g.setColour(theme::green); g.fillRoundedRectangle(bar.withWidth(bar.getWidth() * (float)jlimit(0., 1., secondsLeft / secondsTotal)), 2.5f);
        }
        if (warning.isNotEmpty() && !warningBounds.isEmpty()) {
            card(g, warningBounds, theme::yellow);
            g.setColour(Colours::white); g.setFont(theme::font(12));
            g.drawFittedText(warning, warningBounds.reduced(14, 10), Justification::centred, 2, 1.f);
        }
    }
    juce::Rectangle<int> countdownArea() const { return countdownBounds; }
    juce::Rectangle<int> warningArea() const { return warningBounds; }
  private:
    Session &session; std::function<void()> cancelFade;
    TextButton cancelButton;
    bool active = false;
    double secondsLeft = 0, secondsTotal = 1, warningUntil = 0;
    String warning;
    juce::Rectangle<int> countdownBounds, warningBounds;
    static void card(Graphics &g, juce::Rectangle<int> rectangle, Colour accent) {
        const auto bounds = rectangle.toFloat();
        g.setColour(Colour(0xf52b2b2d)); g.fillRoundedRectangle(bounds, 10);
        g.setColour(accent.withAlpha(.65f)); g.drawRoundedRectangle(bounds.reduced(.5f), 10, 1);
    }
};
} // namespace catlive
