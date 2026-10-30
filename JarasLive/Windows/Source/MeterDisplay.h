#pragma once
#include "Common.h"
#include "../../Core/Audio/MeterState.hpp"
namespace catlive::meterDisplay {
using PeakHold = audio::PeakHold;
class PeakReadout final : public Component, private Timer {
    std::function<float()> read;
    std::function<void()> clear;
    std::function<Colour()> colour;
    float shown=-1;
    void timerCallback()override{const auto value=read();if(value!=shown){shown=value;repaint();}}
public:
    PeakReadout(std::function<float()> get,std::function<void()> reset,std::function<Colour()> foreground=[] {return Colours::white;})
        :read(std::move(get)),clear(std::move(reset)),colour(std::move(foreground)){
        setComponentID("peakReadout");setTitle("Reset peak");startTimerHz(20);
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
    const float fraction = amplitude > 0 && std::isfinite(amplitude)
        ? jlimit(0.f, 1.f, (20 * std::log10(amplitude) + 60) / 60) : 0;
    if (fraction <= 0) return;
    ColourGradient gradient(Colour(0xff0a84ff), bounds.getX(), bounds.getBottom(),
                            Colour(0xffff4245), bounds.getX(), bounds.getY(), false);
    gradient.addColour(.5,Colour(0xffffd600));
    g.setGradientFill(gradient);
    g.fillRect(bounds.withTop(bounds.getBottom() - bounds.getHeight() * fraction));
}
}
