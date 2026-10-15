#pragma once
#include "Common.h"
namespace catlive {
class DragDivider final : public Component {
  public:
    explicit DragDivider(bool horizontalMotion = true) : alongX(horizontalMotion) {
        setMouseCursor(alongX ? MouseCursor::LeftRightResizeCursor : MouseCursor::UpDownResizeCursor);
    }
    std::function<void()> started, ended, doubleClicked;
    std::function<void(int)> moved;
    void mouseDown(const MouseEvent &e) override { origin = e.getScreenPosition(); if (started) started(); }
    void mouseDrag(const MouseEvent &e) override { if (moved) moved(alongX ? e.getScreenPosition().x - origin.x : e.getScreenPosition().y - origin.y); }
    void mouseUp(const MouseEvent &) override { if (ended) ended(); }
    void mouseDoubleClick(const MouseEvent &) override { if (doubleClicked) doubleClicked(); }
    void mouseEnter(const MouseEvent &) override { repaint(); }
    void mouseExit(const MouseEvent &) override { repaint(); }
    void paint(Graphics &g) override {
        g.setColour(isMouseOverOrDragging() ? theme::green : theme::line);
        if (alongX) g.fillRect(getWidth() / 2, 0, 1, getHeight());
        else g.fillRect(0, getHeight() / 2, getWidth(), 1);
    }
  private:
    bool alongX; Point<int> origin;
};
class SongDisplayLabel final : public Label {
  public:
    void paint(Graphics &g) override {
        g.fillAll(theme::display);
        const auto text = getText();
        const auto heading = text.upToFirstOccurrenceOf(String::fromUTF8("›"), false, false).trim();
        const auto song = text.fromFirstOccurrenceOf(String::fromUTF8("›"), false, false).trim();
        g.setFont(theme::font(10, true, true)); g.setColour(theme::secondary);
        const auto width = std::min(getWidth() / 2, (int)std::ceil(GlyphArrangement::getStringWidth(g.getCurrentFont(), heading)) + 16);
        g.drawText(heading, 8, 0, std::max(0, width - 16), getHeight(), Justification::centredLeft);
        g.drawText(String::fromUTF8("›"), width, 0, 10, getHeight(), Justification::centred);
        g.setFont(theme::semiboldFont(12)); g.setColour(findColour(Label::textColourId));
        g.drawFittedText(song, width + 15, 0, std::max(0, getWidth() - width - 23), getHeight(), Justification::centredLeft, 1, .6f);
    }
};
inline String regionCaption(const jaras::Song &song, const jaras::Part *part, std::optional<double> at = {}) {
    if (!part) return String::fromUTF8("—");
    const jaras::TimelineMarker *first = nullptr, *active = nullptr;
    if (song.markers) for (const auto &marker : *song.markers)
        if (marker.tempoBPM && marker.position >= part->startTime && marker.position < part->endTime) {
            if (!first || marker.position < first->position) first = &marker;
            if (at && marker.position <= *at && (!active || marker.position > active->position)) active = &marker;
        }
    auto *tempo = active ? active : first;
    return text(part->name) + (tempo ? " - " + String(*tempo->tempoBPM, *tempo->tempoBPM == std::floor(*tempo->tempoBPM) ? 0 : 1) + " bpm" : String());
}
}
