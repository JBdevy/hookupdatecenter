#pragma once
#include "Common.h"
#include "Appearance.h"
#include <mmsystem.h>
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
        setSize(600, 280);
        addToDesktop(ComponentPeer::windowIsTemporary | ComponentPeer::windowIgnoresMouseClicks);
        auto &displays = Desktop::getInstance().getDisplays();
        auto *display = ownerBounds.isEmpty() ? displays.getPrimaryDisplay()
                                             : displays.getDisplayForRect(ownerBounds);
        if (display) setCentrePosition(display->userBounds.getCentre().roundToInt());
        setVisible(true);
        if (!closingMode) {
            static bool played = false;
            if (!played && (bool)Appearance().value("jaras.startup.sound", true))
                ::PlaySoundA(BinaryData::StartupSound_wav, nullptr, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
            played = true;
        }
        startTimerHz(30);
    }
    ~StartupSplash() override { stopTimer(); }
    void advanceClosing(double completed) {
        remaining = std::min(remaining, jlimit(0.0, 1.0, 1.0 - completed));
        repaint();
    }
    void paint(Graphics &g) override {
        g.setOpacity(1.f);
        g.setColour(theme::panel);
        g.fillRoundedRectangle(getLocalBounds().toFloat(), 12.f);
        g.setColour(Colours::white.withAlpha(.12f));
        g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(.5f), 12.f, 1.f);
        // The content row uses the same 40/60 split as the native Mac card.
        const int logoWidth = roundToInt(getWidth() * .4f);
        const int contentWidth = getWidth() - logoWidth - 49;
        g.setColour(Colours::white.withAlpha(.12f));
        g.fillRect(logoWidth, 0, 1, getHeight());
        // Image drawing also uses the current graphics opacity.
        g.setOpacity(1.f);
        g.drawImageWithin(logo, 24, 24, logoWidth - 48, getHeight() - 48, RectanglePlacement::centred);
        const int titleLeft = 25 + logoWidth;
        g.setGradientFill(ColourGradient(Colour(0xff72ffb3), (float)titleLeft, 79.f,
                                        Colour(0xff00cf64), (float)getWidth() - 24, 145.f, false));
        const float waveHeights[] = {10, 20, 30, 38, 26, 18, 8};
        for (int bar = 0; bar < 7; ++bar)
            g.fillRoundedRectangle((float)titleLeft + bar * 5, 112.f - waveHeights[bar] / 2,
                                   3.f, waveHeights[bar], 1.5f);
        g.setFont(theme::font(54, true));
        g.drawText("CatLive", titleLeft + 43, 79, contentWidth - 43, 66, Justification::centredLeft);
        g.setColour(theme::secondary);
        g.setFont(theme::font(12));
        g.drawText("Version " + JUCEApplication::getInstance()->getApplicationVersion(), titleLeft, 153,
                   contentWidth, 18, Justification::centredLeft);
        g.setColour(theme::green.withAlpha(.14f));
        g.fillRoundedRectangle((float)titleLeft, 207, (float)contentWidth, 5, 2.5f);
        g.setColour(theme::green);
        float progress = closingMode ? (float)remaining
                                     : .55f + .45f * (float)(.5 - .5 * std::cos(elapsed * 3.4));
        g.fillRoundedRectangle((float)titleLeft, 207, contentWidth * progress, 5, 2.5f);
        g.setFont(theme::font(12));
        g.setColour(theme::secondary);
        g.drawText(closingMode ? String::fromUTF8("Closing…") : String::fromUTF8("Iniciando CatLive…"), titleLeft, 222, contentWidth, 16,
                   Justification::centredLeft);
        g.setFont(theme::font(10));
        g.drawText(String::fromUTF8("© reivsoficial"), titleLeft, 242, contentWidth, 12, Justification::centredLeft);
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
