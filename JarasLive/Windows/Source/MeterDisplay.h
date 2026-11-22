#pragma once
#include "Common.h"
#include "MeterRepaint.h"
#include "../../Core/Audio/MeterState.hpp"
namespace catlive::meterDisplay {
using PeakHold = audio::PeakHold;
inline bool visibleInViewport(const Component& component) {
    if (!component.isShowing()) return false;
    auto bounds = component.getLocalBounds();
    for (auto* child = &component; auto* parent = child->getParentComponent(); child = parent) {
        bounds = parent->getLocalArea(child, bounds).getIntersection(parent->getLocalBounds());
        if (bounds.isEmpty()) return false;
    }
    return !bounds.isEmpty();
}
class PeakReadout final : public Component {
    std::function<float()> read;
    std::function<void()> clear;
    std::function<Colour()> colour;
    float shown=-1;
    static float displayDB(float amplitude) {
        const auto rounded = std::round(20.f * std::log10(amplitude) * 100.f) / 100.f;
        if (amplitude == 1.f) return 0.f;
        return amplitude < 1.f ? std::min(-.01f, rounded) : std::max(.01f, rounded);
    }
public:
    // The owning mixer polls visible meters together. One timer per peak
    // multiplied the idle workload by every track, including offscreen rows.
    void refresh(){
        if (!visibleInViewport(*this)) return;
        const auto amplitude=read();
        const auto value=amplitude>0 && std::isfinite(amplitude)
            ? displayDB(amplitude) : -1000.f;
        if(value!=shown){shown=value;repaint();}
    }
    PeakReadout(std::function<float()> get,std::function<void()> reset,std::function<Colour()> foreground=[] {return Colours::white;})
        :read(std::move(get)),clear(std::move(reset)),colour(std::move(foreground)){
        setComponentID("peakReadout");setTitle("Reset peak");
    }
    bool hitTest(int x, int y) override {
        const auto amplitude=read();
        if(amplitude<=0)return false;
        const auto db=displayDB(amplitude);
        const auto value=(db>=0?"+":"")+String(db,2);
        const auto field=getLocalBounds().toFloat().withSizeKeepingCentre(
            std::min((float)getWidth(),GlyphArrangement::getStringWidth(theme::semiboldFont(8),value)+4.f),
            std::min(12.f,(float)getHeight()));
        return field.contains((float)x,(float)y);
    }
    void paint(Graphics &g)override{
        const auto amplitude=read();if(amplitude<=0)return;
        const auto db=displayDB(amplitude);
        const auto text=(db>=0?"+":"")+String(db,2);
        const auto font=theme::semiboldFont(8);g.setFont(font);
        const auto field=getLocalBounds().toFloat().withSizeKeepingCentre(std::min((float)getWidth(),GlyphArrangement::getStringWidth(font,text)+4.f),std::min(12.f,(float)getHeight()));
        if(db>0){g.setColour(Colours::black);g.fillRoundedRectangle(field,2);}
        g.setColour(db>0?Colours::red:colour());
        g.drawText(text,field,Justification::centred,false);
    }
    void mouseDown(const MouseEvent &e)override{if(e.mods.isLeftButtonDown()){clear();repaint();}}
};
// Match TrackMeterLevel: immediate attack, no hold, 40 dB/s fall.
// The independent numeric peak is retained by PeakHold.
inline float envelope(float previous, float input, double elapsed) noexcept {
    input = std::isfinite(input) ? std::max(0.f, input) : 0.f;
    const auto level = std::max(input, previous * (float)std::pow(10., -40. * std::max(0., elapsed) / 20.));
    return level < .001f ? 0.f : level;
}
inline constexpr float railThickness = 14.f;
inline constexpr float yellowTransitionStart = fractionForDB(-20.f), yellowTransitionEnd = fractionForDB(-17.f);
inline const Colour signalGreen{0xff239653}, railBorder{0xff2d3236};
inline void rail(Graphics &g, juce::Rectangle<float> bounds, const std::array<float, 2>& levels,
                 bool vertical, bool fixedUpperSpan = false) {
    if (bounds.isEmpty()) return;
    Path outline;
    const float radius = std::min(bounds.getWidth(), bounds.getHeight()) / 2;
    outline.addRoundedRectangle(bounds, radius);
    g.setColour(theme::faderRail);
    g.fillPath(outline);
    Graphics::ScopedSaveState saved(g);
    g.reduceClipRegion(outline);
    const auto start = vertical ? Point<float>(bounds.getCentreX(), bounds.getBottom())
                                : Point<float>(bounds.getX(), bounds.getCentreY());
    const auto end = vertical ? Point<float>(bounds.getCentreX(), bounds.getY())
                              : Point<float>(bounds.getRight(), bounds.getCentreY());
    const Colour red(0xfff44336);
    ColourGradient gradient(signalGreen, start, theme::yellow, end, false);
    const auto dbPosition = [&](float db) {
        return fixedUpperSpan ? (float)horizontalTrackFraction(db, bounds.getWidth()) : fractionForDB(db);
    };
    gradient.addColour(dbPosition(-20.f), signalGreen);
    gradient.addColour(dbPosition(-17.f), theme::yellow);
    for (int channel = 0; channel < 2; ++channel) {
        const auto amplitude = levels[(size_t)channel];
        const auto amount = amplitude > 0.f && std::isfinite(amplitude) ? dbPosition(20.f * std::log10(amplitude)) : 0.f;
        const auto gap = std::min(1.f, vertical ? bounds.getWidth() : bounds.getHeight());
        const auto thickness = ((vertical ? bounds.getWidth() : bounds.getHeight()) - gap) / 2;
        const auto fill = vertical
            ? bounds.withX(bounds.getX() + channel * (thickness + gap)).withWidth(thickness)
                .withTop(bounds.getBottom() - bounds.getHeight() * amount)
            : bounds.withY(bounds.getY() + channel * (thickness + gap)).withHeight(thickness)
                .withWidth(bounds.getWidth() * amount);
        g.setGradientFill(gradient);
        g.fillRect(fill);
        if (levels[(size_t)channel] > 1.f) {
            g.setColour(red);
            const auto threshold = dbPosition(0.f);
            g.fillRect(vertical ? fill.withBottom(bounds.getBottom() - bounds.getHeight() * threshold)
                                : fill.withLeft(bounds.getX() + bounds.getWidth() * threshold));
        }
    }
    g.setColour(railBorder);
    g.drawRoundedRectangle(bounds.reduced(.375f), std::max(0.f, radius - .375f), .75f);
}
inline void gainReduction(Graphics &g, juce::Rectangle<float> bounds, float db) {
    if (db < 0.f || bounds.isEmpty()) return;
    g.setColour(theme::faderRail);
    g.fillRoundedRectangle(bounds, 1.f);
    if (db <= 0.f) return;
    g.setColour(Colour(0xfff44336));
    const float fraction = std::min(1.f, db / 24.f);
    const auto fill = bounds.getHeight() > bounds.getWidth() ? bounds.withHeight(bounds.getHeight() * fraction)
        : bounds.withLeft(bounds.getRight() - bounds.getWidth() * fraction);
    g.fillRoundedRectangle(fill, 1.f);
}
inline void faderThumb(Graphics &g, Point<float> centre, bool vertical) {
    const float width = vertical ? 18.f : 10.f;
    const float height = vertical ? 10.f : 18.f;
    const juce::Rectangle<float> face(centre.x - width / 2, centre.y - height / 2, width, height);
    g.setGradientFill(ColourGradient(Colour(0xffa0abb5), centre.x, face.getY(),
                                    Colour(0xff2c353d), centre.x, face.getBottom(), false));
    g.fillRoundedRectangle(face, 2.5f);
    const auto interior = face.reduced(.75f);
    g.setGradientFill(ColourGradient(Colour(0xff78848d), centre.x, interior.getY(),
                                    Colour(0xff4a555e), centre.x, interior.getBottom(), false));
    g.fillRoundedRectangle(interior, 1.75f);
    g.setColour(Colour(0xffeff4f4));
    g.fillRect(face.withSizeKeepingCentre(vertical ? 9.f : 1.5f, vertical ? 1.5f : 9.f));
}
inline void compactRail(Graphics &g, juce::Rectangle<float> bounds, const std::array<float, 2>& levels) {
    rail(g, bounds.withSizeKeepingCentre(std::min(8.f, bounds.getWidth()), std::min(20.f, bounds.getHeight())),
         levels, true);
}
inline void bar(Graphics &g, juce::Rectangle<float> bounds, float amplitude) {
    if (bounds.isEmpty()) return;
    // Give both narrow channels equal physical widths at fractional UI/DPI scales.
    const float scale=g.getInternalContext().getPhysicalPixelScaleFactor();
    if(scale>0) bounds={std::round(bounds.getX()*scale)/scale,std::round(bounds.getY()*scale)/scale,
        std::max(1.f,std::round(bounds.getWidth()*scale))/scale,std::max(1.f,std::round(bounds.getHeight()*scale))/scale};
    g.setColour(Colours::black.withAlpha(.55f));
    g.fillRect(bounds);
    const float level = fraction(amplitude);
    if (level <= 0) return;
    ColourGradient gradient(signalGreen, bounds.getX(), bounds.getBottom(),
                            theme::yellow, bounds.getX(), bounds.getY(), false);
    gradient.addColour(yellowTransitionStart, signalGreen);
    gradient.addColour(yellowTransitionEnd, theme::yellow);
    g.setGradientFill(gradient);
    g.fillRect(bounds.withTop(bounds.getBottom() - bounds.getHeight() * level));
    if (amplitude > 1.f) {
        g.setColour(Colour(0xfff44336));
        g.fillRect(bounds.withTop(bounds.getBottom() - bounds.getHeight() * level)
                         .withBottom(bounds.getBottom() - bounds.getHeight() * fractionForDB(0.f)));
    }
}
}
