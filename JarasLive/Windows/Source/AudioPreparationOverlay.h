#pragma once
#include "Common.h"
#include "Localization.h"
namespace catlive {
class AudioPreparationOverlay final : public Component, private Timer {
public:
    AudioPreparationOverlay() { setComponentID("audioPreparationOverlay");startTimerHz(30); }
    void paint(Graphics &g) override {
        g.fillAll(Colours::black.withAlpha(.35f));
        const auto card=getLocalBounds().withSizeKeepingCentre(280,128).toFloat();
        g.setColour(theme::panel);g.fillRoundedRectangle(card,18);
        getLookAndFeel().drawSpinningWaitAnimation(g,theme::green,(int)card.getCentreX()-16,(int)card.getY()+23,32,32);
        g.setColour(Colours::white);g.setFont(theme::semiboldFont(12));
        g.drawText(localization::english?"Preparing audio...":String::fromUTF8("Preparando áudio..."),card.withTrimmedTop(72).withHeight(24),Justification::centred);
    }
private:
    void timerCallback() override { repaint(getLocalBounds().withSizeKeepingCentre(280,128)); }
};
}
