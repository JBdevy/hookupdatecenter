#pragma once
#include "Common.h"
namespace catlive {
// AudioStatusView on Mac grows toward the left and turns green over 120 ms.
// Own the text and animation here so hover never repaints the whole workspace.
class FooterAudioStatusButton final : public QuietButton, private Timer {
  public:
    std::function<String()> status;
    void paintButton(Graphics &g,bool,bool) override {
        auto area=getLocalBounds().toFloat().reduced(8,0);
        area.setX(std::max(area.getX(),area.getRight()-370.f));
        if(area.isEmpty())return;
        const auto font=theme::font(9);
        g.setFont(font);g.setColour(theme::secondary.interpolatedWith(theme::green,progress));
        const float scale=1.f+.04f*progress;
        Graphics::ScopedSaveState saved(g);
        g.addTransform(AffineTransform::scale(scale,scale,area.getRight(),area.getCentreY()));
        g.drawText(truncated(status?status():String(),font,area.getWidth()),area,Justification::centredRight,false);
    }
    void mouseEnter(const MouseEvent &event) override {QuietButton::mouseEnter(event);animate(true);}
    void mouseExit(const MouseEvent &event) override {QuietButton::mouseExit(event);animate(false);}
    void visibilityChanged() override {
        if(!isVisible()){stopTimer();progress=0;target=0;repaint();}
    }
  private:
    float progress=0,from=0,target=0;
    double started=0;
    static String truncated(const String &text,const Font &font,float width) {
        if(GlyphArrangement::getStringWidth(font,text)<=width)return text;
        const auto ellipsis=String::fromUTF8("…");
        const auto shortened=[&](int count){return text.substring(0,(count+1)/2)+ellipsis+text.substring(text.length()-count/2);};
        int low=0,high=std::max(0,text.length()-1);
        while(low<high){const int mid=(low+high+1)/2;if(GlyphArrangement::getStringWidth(font,shortened(mid))<=width)low=mid;else high=mid-1;}
        return shortened(low);
    }
    void animate(bool hovered) {
        from=progress;target=hovered?1.f:0.f;started=Time::getMillisecondCounterHiRes();
        startTimerHz(60);repaint();
    }
    void timerCallback() override {
        const float elapsed=jlimit(0.f,1.f,(float)((Time::getMillisecondCounterHiRes()-started)/120.));
        const float remaining=1.f-elapsed;
        progress=from+(target-from)*(1.f-remaining*remaining*remaining);
        repaint();if(elapsed>=1)stopTimer();
    }
};
}
