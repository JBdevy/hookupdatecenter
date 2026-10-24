#pragma once
#include "Common.h"
namespace catlive::meterDisplay {
class PeakHold {
    std::atomic<float> maximum{0};
public:
    void record(float amplitude) noexcept {
        if(!std::isfinite(amplitude)||amplitude<std::pow(10.f,-24.f/20))return;
        auto previous=maximum.load(std::memory_order_relaxed);
        while(amplitude>previous&&!maximum.compare_exchange_weak(previous,amplitude,std::memory_order_relaxed)){}
    }
    float amplitude()const noexcept{return maximum.load(std::memory_order_relaxed);}
    void clear()noexcept{maximum.store(0,std::memory_order_relaxed);}
};
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
// Show the current measured block without holding a previous bar level.
// Numeric peak retention is handled separately by PeakHold.
inline float measuredLevel(float input) noexcept {
    return std::isfinite(input) && input >= .001f ? input : 0.f;
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
    // Match the dark macOS CAGradientLayer after its colour-space interpolation.
    // Three sRGB stops alone produce different intermediate hues in JUCE.
    ColourGradient gradient(Colour(0xff30d158), bounds.getX(), bounds.getBottom(),
                            Colour(0xffff4245), bounds.getX(), bounds.getY(), false);
    gradient.addColour(0.001953125, Colour(0xff31d157));
    gradient.addColour(0.029296875, Colour(0xff41d154));
    gradient.addColour(0.060546875, Colour(0xff53d250));
    gradient.addColour(0.091796875, Colour(0xff62d24c));
    gradient.addColour(0.123046875, Colour(0xff71d247));
    gradient.addColour(0.154296875, Colour(0xff7ed243));
    gradient.addColour(0.185546875, Colour(0xff8cd33e));
    gradient.addColour(0.216796875, Colour(0xff98d339));
    gradient.addColour(0.248046875, Colour(0xffa4d334));
    gradient.addColour(0.279296875, Colour(0xffb1d42f));
    gradient.addColour(0.310546875, Colour(0xffbcd42a));
    gradient.addColour(0.341796875, Colour(0xffc8d424));
    gradient.addColour(0.373046875, Colour(0xffd3d41f));
    gradient.addColour(0.404296875, Colour(0xffdfd518));
    gradient.addColour(0.435546875, Colour(0xffe9d511));
    gradient.addColour(0.466796875, Colour(0xfff5d608));
    gradient.addColour(0.498046875, Colour(0xfffed601));
    gradient.addColour(0.529296875, Colour(0xffffcf05));
    gradient.addColour(0.560546875, Colour(0xffffc60c));
    gradient.addColour(0.591796875, Colour(0xffffbd11));
    gradient.addColour(0.623046875, Colour(0xffffb417));
    gradient.addColour(0.654296875, Colour(0xffffac1b));
    gradient.addColour(0.685546875, Colour(0xffffa220));
    gradient.addColour(0.716796875, Colour(0xffff9a24));
    gradient.addColour(0.748046875, Colour(0xffff9128));
    gradient.addColour(0.779296875, Colour(0xffff872c));
    gradient.addColour(0.810546875, Colour(0xffff7e30));
    gradient.addColour(0.841796875, Colour(0xffff7434));
    gradient.addColour(0.873046875, Colour(0xffff6a37));
    gradient.addColour(0.904296875, Colour(0xffff603b));
    gradient.addColour(0.935546875, Colour(0xffff573e));
    gradient.addColour(0.966796875, Colour(0xffff4c42));
    gradient.addColour(0.998046875, Colour(0xffff4345));
    g.setGradientFill(gradient);
    g.fillRect(bounds.withTop(bounds.getBottom() - bounds.getHeight() * fraction));
}
}
