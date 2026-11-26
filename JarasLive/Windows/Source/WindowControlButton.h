#pragma once
#include "Common.h"
namespace catlive {
class WindowControlButton final : public Button {
  public:
    explicit WindowControlButton(int value)
        : Button(value == DocumentWindow::closeButton ? "Fechar"
                 : value == DocumentWindow::minimiseButton ? "Minimizar" : "Maximizar / Restaurar"),
          kind(value) { setWantsKeyboardFocus(false); }
    void paintButton(Graphics &g, bool hover, bool down) override {
        if (hover || down) {
            const auto colour = kind == DocumentWindow::closeButton ? Colour(0xffc42b1c)
                                                                   : Colour(0xff454545);
            g.fillAll(down ? colour.darker(.18f) : colour);
        }
        g.setColour(isEnabled() ? Colours::white.withAlpha(.9f) : theme::secondary);
        const auto r = getLocalBounds().toFloat().withSizeKeepingCentre(10, 10);
        if (kind == DocumentWindow::closeButton) {
            g.drawLine(r.getX(), r.getY(), r.getRight(), r.getBottom(), 1);
            g.drawLine(r.getRight(), r.getY(), r.getX(), r.getBottom(), 1);
        } else if (kind == DocumentWindow::minimiseButton) {
            g.drawLine(r.getX(), r.getCentreY(), r.getRight(), r.getCentreY(), 1);
        } else {
            auto *peer = getTopLevelComponent()->getPeer();
            if (peer && IsZoomed((HWND)peer->getNativeHandle())) {
                g.drawRect(r.withTrimmedLeft(2).withTrimmedBottom(2), 1);
                g.setColour(theme::titlebar);
                g.fillRect(r.withTrimmedRight(2).withTrimmedTop(2));
                g.setColour(Colours::white.withAlpha(.9f));
                g.drawRect(r.withTrimmedRight(2).withTrimmedTop(2), 1);
            } else g.drawRect(r, 1);
        }
    }
  private:
    int kind;
};
}
