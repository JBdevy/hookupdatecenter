#pragma once
#include "Common.h"
#include <BinaryData.h>
namespace catlive {
// Shared opening/closing artwork and geometry from JarasLiveApp.swift.
class StartupSplash final : public Component, private Timer {
  public:
    explicit StartupSplash(bool closing = false, juce::Rectangle<int> ownerBounds = {})
        : closingMode(closing) {
        // Layered transparent Windows peers use a software backing surface.
        logo = SoftwareImageType().convert(logo);
        setName(closing ? "CatLiveClosingSplash" : "CatLiveStartupSplash");
        setOpaque(false);
        setInterceptsMouseClicks(false, false);
        setAlwaysOnTop(true);
        setSize(390, 430);
        addToDesktop(ComponentPeer::windowIsTemporary | ComponentPeer::windowIgnoresMouseClicks);
        auto &displays = Desktop::getInstance().getDisplays();
        auto *display = ownerBounds.isEmpty() ? displays.getPrimaryDisplay()
                                             : displays.getDisplayForRect(ownerBounds);
        if (display) setCentrePosition(display->userBounds.getCentre().roundToInt());
        setVisible(true);
        startTimerHz(30);
    }
    ~StartupSplash() override { stopTimer(); }
    void advanceClosing(double completed) {
        remaining = std::min(remaining, jlimit(0.0, 1.0, 1.0 - completed));
        repaint();
    }
    void paint(Graphics &g) override {
        g.setOpacity(1.f);
        g.drawImageWithin(logo, 30, 8, 330, 330, RectanglePlacement::centred);
        g.setColour(theme::green.withAlpha(.14f));
        g.fillRoundedRectangle(45, 360, 300, 5, 2.5f);
        g.setColour(theme::green.withAlpha(.55f + .45f * (float)(.5 - .5 * std::cos(elapsed * 3.7))));
        float progress = closingMode ? (float)remaining
                                     : .55f + .45f * (float)(.5 - .5 * std::cos(elapsed * 3.4));
        g.fillRoundedRectangle(45, 360, 300 * progress, 5, 2.5f);
        g.setFont(theme::font(12));
        g.setColour(theme::secondary);
        g.drawText(closingMode ? String::fromUTF8("Closing…") : String::fromUTF8("Iniciando CatLive…"), 30, 382, 330, 22,
                   Justification::centred);
    }

  private:
    Image logo =
        ImageCache::getFromMemory(BinaryData::CatLiveSplash_png, BinaryData::CatLiveSplash_pngSize);
    double elapsed = 0;
    double remaining = 1;
    bool closingMode = false;
    void timerCallback() override {
        elapsed += 1.0 / 30;
        repaint();
    }
};
} // namespace catlive
