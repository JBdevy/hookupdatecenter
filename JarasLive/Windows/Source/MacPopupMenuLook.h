#pragma once
#include "Common.h"

namespace catlive {
// Presentation only: JUCE keeps keyboard navigation, accessibility, selection
// and submenu placement. No screenshots/raster scaling or new menu commands.
class MacPopupMenuLook : public LookAndFeel_V4 {
  public:
    static Colour menuSurface() { return Colour(0xf52b2b2d); }
    MacPopupMenuLook() { setColour(PopupMenu::backgroundColourId, menuSurface()); }
    int getPopupMenuBorderSize() override { return 6; }
    void drawPopupMenuBackground(Graphics &g, int width, int height) override {
        const juce::Rectangle<float> bounds(.5f, .5f, width - 1.f, height - 1.f);
        if (!Desktop::canUseSemiTransparentWindows()) g.fillAll(Colour(0xff2b2b2d));
        g.setGradientFill(ColourGradient(menuSurface(), 0, 0, Colour(0xf5262628), 0, (float)height, false));
        g.fillRoundedRectangle(bounds, 10);
        g.setColour(Colours::white.withAlpha(.17f));
        g.drawRoundedRectangle(bounds, 10, 1);
    }
    void getIdealPopupMenuItemSize(const String &label, bool separator, int standard,
                                  int &width, int &height) override {
        height = separator ? 9 : std::max(24, standard > 0 ? standard : (int)std::ceil(getPopupMenuFont().getHeight() + 10));
        width = separator ? 60 : std::max(160, (int)std::ceil(GlyphArrangement::getStringWidth(getPopupMenuFont(), label)) + 58);
    }
    void drawPopupMenuItem(Graphics &g, const juce::Rectangle<int> &area, bool separator,
                           bool active, bool highlighted, bool ticked, bool submenu,
                           const String &label, const String &shortcut, const Drawable *icon,
                           const Colour *customColour) override {
        auto row = area.toFloat().reduced(2, 1);
        if (separator) {
            g.setColour(Colours::white.withAlpha(.13f));
            g.drawHorizontalLine((int)row.getCentreY(), row.getX() + 7, row.getRight() - 7);
            return;
        }
        if (active && highlighted) {
            g.setColour(Colour(0xff48484b));
            g.fillRoundedRectangle(row, 5);
        }
        const auto foreground = (customColour ? *customColour : Colour(0xfff2f2f2))
            .withMultipliedAlpha(active ? 1.f : .42f);
        g.setColour(foreground);
        auto content = area.reduced(7, 0);
        const auto mark = content.removeFromLeft(19).toFloat().withSizeKeepingCentre(12, 12);
        if (icon) icon->drawWithin(g, mark, RectanglePlacement::centred | RectanglePlacement::onlyReduceInSize, active ? 1.f : .42f);
        else if (ticked) {
            Path check;
            check.startNewSubPath(mark.getX() + 2, mark.getCentreY());
            check.lineTo(mark.getX() + 5, mark.getBottom() - 3);
            check.lineTo(mark.getRight() - 1, mark.getY() + 2);
            g.strokePath(check, PathStrokeType(1.5f, PathStrokeType::curved, PathStrokeType::rounded));
        }
        const auto arrow = content.removeFromRight(13).toFloat();
        if (submenu) {
            Path chevron;
            chevron.startNewSubPath(arrow.getCentreX() - 2, arrow.getCentreY() - 3.5f);
            chevron.lineTo(arrow.getCentreX() + 1.5f, arrow.getCentreY());
            chevron.lineTo(arrow.getCentreX() - 2, arrow.getCentreY() + 3.5f);
            g.strokePath(chevron, PathStrokeType(1.4f, PathStrokeType::curved, PathStrokeType::rounded));
        }
        if (shortcut.isNotEmpty()) {
            const auto shortcutFont = getPopupMenuFont().withHeight(std::max(10.f, getPopupMenuFont().getHeight() - 1));
            const int width = (int)std::ceil(GlyphArrangement::getStringWidth(shortcutFont, shortcut)) + 14;
            const auto bounds = content.removeFromRight(std::min(width, content.getWidth() / 2));
            g.setFont(shortcutFont); g.setColour(foreground.withMultipliedAlpha(.72f));
            g.drawText(shortcut, bounds, Justification::centredRight, true);
        }
        g.setFont(getPopupMenuFont()); g.setColour(foreground);
        g.drawText(label, content, Justification::centredLeft, true);
    }
};
} // namespace catlive
