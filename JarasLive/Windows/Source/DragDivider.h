#pragma once
#include "Common.h"
namespace catlive {
// The same narrow sidebar rail scrolls vertically and resizes horizontally.
class DragDivider final : public Component {
  public:
    struct ScrollMetrics { int offset=0, viewport=0, document=0; };
    explicit DragDivider(bool horizontalMotion = true) : alongX(horizontalMotion) {
        setMouseCursor(alongX ? MouseCursor::LeftRightResizeCursor : MouseCursor::UpDownResizeCursor);
    }
    std::function<void()> started, ended, doubleClicked;
    std::function<void(int)> moved, scrollTo;
    std::function<ScrollMetrics()> scrollMetrics;
    void setThinRail(bool value) { thinRail=value;repaint(); }
    void refreshScroll() {
        const auto next = scrollMetrics ? scrollMetrics() : ScrollMetrics{};
        if (metrics.offset != next.offset || metrics.viewport != next.viewport || metrics.document != next.document) {
            metrics=next; repaint();
        }
    }
    void mouseDown(const MouseEvent &e) override {
        if (!e.mods.isLeftButtonDown()) return;
        refreshScroll(); origin=e.getScreenPosition(); initialScroll=metrics.offset; axis=Axis::pending;
        const auto thumb=thumbBounds();
        const float travel=getHeight()-4.f-thumb.getHeight();
        scrollPerPoint=travel>0 && metrics.document>metrics.viewport ? (metrics.document-metrics.viewport)/travel : 0;
    }
    void mouseDrag(const MouseEvent &e) override {
        if (!e.mods.isLeftButtonDown()) return;
        const auto delta=e.getScreenPosition()-origin;
        if (axis==Axis::pending) {
            if (std::max(std::abs(delta.x),std::abs(delta.y))<3) return;
            if (alongX && scrollPerPoint>0 && std::abs(delta.y)>std::abs(delta.x)) axis=Axis::scroll;
            else if (!alongX || std::abs(delta.x)>=std::abs(delta.y)) { axis=Axis::resize; if(started)started(); }
            else return;
        }
        if(axis==Axis::scroll && scrollTo) { scrollTo(initialScroll+roundToInt(delta.y*scrollPerPoint)); refreshScroll(); }
        if(axis==Axis::resize && moved) moved(alongX?delta.x:delta.y);
    }
    void mouseUp(const MouseEvent &) override { if(axis==Axis::resize && ended)ended();axis=Axis::pending; }
    void mouseDoubleClick(const MouseEvent &) override { if(doubleClicked)doubleClicked(); }
    void mouseWheelMove(const MouseEvent &, const MouseWheelDetails &wheel) override {
        refreshScroll(); if(scrollTo) { scrollTo(metrics.offset-roundToInt(wheel.deltaY*320));refreshScroll(); }
    }
    void mouseEnter(const MouseEvent &) override { repaint(); }
    void mouseExit(const MouseEvent &) override { repaint(); }
    void paint(Graphics &g) override {
        g.setColour(Colour::fromFloatRGBA(.18f,.18f,.18f,1));
        if(alongX) {
            const float width=thinRail?2.f:4.f;
            g.fillRect(getWidth()/2.f-width/2,0.f,width,(float)getHeight());
            if(metrics.document>metrics.viewport && metrics.viewport>0) {
                const auto green=Colour::fromFloatRGBA(.22f,1,.55f,1);
                g.setColour(green.withAlpha(.25f));g.fillRect(getWidth()/2.f-1,0.f,2.f,(float)getHeight());
                g.setColour(green);g.fillRoundedRectangle(thumbBounds(),3);
            } else {
                g.setColour(Colour::fromFloatRGBA(.55f,.55f,.55f,1));
                g.fillRoundedRectangle(getWidth()/2.f-1,getHeight()/2.f-14,2,28,1);
            }
        } else {
            g.fillRect(0,getHeight()/2,getWidth(),1);
            g.setColour(isMouseOverOrDragging()?theme::green:theme::secondary);
            g.fillRoundedRectangle(getWidth()/2.f-24,getHeight()/2.f-1,48,2,1);
        }
    }
  private:
    enum class Axis { pending, resize, scroll };
    Axis axis=Axis::pending;
    bool alongX,thinRail=false; Point<int> origin; ScrollMetrics metrics;
    int initialScroll=0;float scrollPerPoint=0;
    juce::Rectangle<float> thumbBounds() const {
        const float height=std::max(0,getHeight()-4),width=std::min(thinRail?2:6,getWidth());
        const float thumb=std::min(height,std::max(24.f,height*metrics.viewport/std::max(1,metrics.document)));
        const float fraction=jlimit(0.f,1.f,(float)metrics.offset/std::max(1,metrics.document-metrics.viewport));
        return {getWidth()/2.f-width/2,2+(height-thumb)*fraction,width,thumb};
    }
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
