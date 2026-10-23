#pragma once
#include <algorithm>
#include <cmath>
#include <optional>

namespace catlive {
// Normalize to 0.1/notch, then match the Mac gesture's 40-point notches and
// 60-point travel threshold (two notches). JUCE Win32 reports 60/256 per notch.
class HozMixerFocusGesture {
  public:
    static double wheelDelta(double x,double y,bool smooth) {
        // Some mouse drivers remap Shift+wheel to the horizontal axis. Accept
        // only discrete X-only events, not a physical smooth horizontal swipe.
        const double delta=std::abs(y)>=std::abs(x)?y:!smooth&&std::abs(y)<1e-8?x:0;
        return smooth?delta:delta*(.1*256./60.);
    }
    void reset() { accumulated=0;direction=0;latched=false;lastTime=-1; }
    std::optional<bool> update(double delta, double seconds, bool inertial=false) {
        if(inertial || !std::isfinite(delta) || !std::isfinite(seconds) || delta==0)return {};
        const int nextDirection=delta>0?1:-1;
        if(lastTime<0 || seconds<lastTime || seconds-lastTime>.6 || nextDirection!=direction) {
            accumulated=0;latched=false;
        }
        direction=nextDirection;lastTime=seconds;
        if(latched || seconds-lastAction<.6)return {};
        // A driver spike must not turn one accidental wheel event into a full gesture.
        accumulated+=std::min(40.,std::abs(delta)*400.);
        if(accumulated<60.)return {};
        latched=true;lastAction=seconds;return direction>0;
    }
  private:
    double accumulated=0,lastTime=-1,lastAction=-1e9;
    int direction=0;
    bool latched=false;
};
}
