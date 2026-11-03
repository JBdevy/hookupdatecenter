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
public:
    // The owning mixer polls visible meters together. One timer per peak
    // multiplied the idle workload by every track, including offscreen rows.
    void refresh(){
        if (!visibleInViewport(*this)) return;
        const auto amplitude=read();
        const auto value=amplitude>0 && std::isfinite(amplitude)
            ? std::round(20*std::log10(amplitude)*100) : -100000.f;
        if(value!=shown){shown=value;repaint();}
    }
    PeakReadout(std::function<float()> get,std::function<void()> reset,std::function<Colour()> foreground=[] {return Colours::white;})
        :read(std::move(get)),clear(std::move(reset)),colour(std::move(foreground)){
        setComponentID("peakReadout");setTitle("Reset peak");
    }
    bool hitTest(int x, int y) override {
        const auto amplitude=read();
        if(amplitude<=0)return false;
        const auto db=std::round(20*std::log10(amplitude)*100)/100;
        const auto value=(db>=0?"+":"")+String(db,2);
        const auto field=getLocalBounds().toFloat().withSizeKeepingCentre(
            std::min((float)getWidth(),GlyphArrangement::getStringWidth(theme::semiboldFont(8),value)+4.f),
            std::min(12.f,(float)getHeight()));
        return field.contains((float)x,(float)y);
    }
    void paint(Graphics &g)override{
        const auto amplitude=read();if(amplitude<=0)return;
        const auto db=std::round(20*std::log10(amplitude)*100)/100;
        const auto text=(db>=0?"+":"")+String(db,2);
        const auto font=theme::semiboldFont(8);g.setFont(font);
        const auto field=getLocalBounds().toFloat().withSizeKeepingCentre(std::min((float)getWidth(),GlyphArrangement::getStringWidth(font,text)+4.f),std::min(12.f,(float)getHeight()));
        if(db>=0){g.setColour(Colours::black);g.fillRoundedRectangle(field,2);}
        g.setColour(db>=0?Colours::red:colour());
        g.drawText(text,field,Justification::centred,false);
    }
    void mouseDown(const MouseEvent &e)override{if(e.mods.isLeftButtonDown()){clear();repaint();}}
};
// Match TrackMeterLevel: immediate attack, no hold, short 120 dB/s fall.
// The independent numeric peak is retained by PeakHold.
inline float envelope(float previous, float input, double elapsed) noexcept {
    input = std::isfinite(input) ? std::max(0.f, input) : 0.f;
    const auto level = std::max(input, previous * (float)std::pow(10., -120. * std::max(0., elapsed) / 20.));
    return level < .001f ? 0.f : level;
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
    ColourGradient gradient(Colour(0xff0a84ff), bounds.getX(), bounds.getBottom(),
                            Colour(0xffff4245), bounds.getX(), bounds.getY(), false);
    gradient.addColour(.5,Colour(0xffffd600));
    g.setGradientFill(gradient);
    g.fillRect(bounds.withTop(bounds.getBottom() - bounds.getHeight() * level));
}
}
