#pragma once
#include "Common.h"
namespace catlive {
// Scroll the rows and the grid from the same observation, rather than polling
// the viewport from the workspace's slower status timer.
class TrackMixerViewport final : public Viewport, private Timer {
  public:
    std::function<void()> moved;
    std::function<void(const MouseEvent &)> pressed, doubleClicked;
    std::function<void(const MouseEvent &,const MouseWheelDetails &)> wheel;
    TrackMixerViewport() {
        selection.owner=this;addMouseListener(&selection,true);
        setScrollBarsShown(false,false,false,false);
    }
    ~TrackMixerViewport() override { clearCallbacks();removeMouseListener(&selection); }
    void clearCallbacks() { stopTimer();moved={};pressed={};doubleClicked={};wheel={}; }
    void cancelWheel() { stopTimer();origin=target=getViewPositionY();direction=0; }
    void scrollTo(int y) { cancelWheel();setViewPosition(0,jlimit(0,maximum(),y)); }
    void scrollByWheel(double delta,bool precise) {
        if(!std::isfinite(delta) || delta==0)return;
        const int nextDirection=delta>0?1:-1;
        if(precise) {
            stopTimer();
            if(std::abs(target-getViewPositionY())>1)target=getViewPositionY();
            target=jlimit(0.,(double)maximum(),target+delta);apply(target);return;
        }
        if(!isTimerRunning() || nextDirection!=direction)target=getViewPositionY();
        direction=nextDirection;origin=getViewPositionY();
        target=jlimit(0.,(double)maximum(),target+delta);
        started=Time::getMillisecondCounterHiRes();
        if(target==origin){stopTimer();return;}
        startTimerHz(60);
    }
    void mouseWheelMove(const MouseEvent &event,const MouseWheelDetails &details) override {
        if(wheel)wheel(event,details);
    }
  private:
    friend struct WorkspaceLayoutTests;
    struct SelectionObserver final : MouseListener {
        TrackMixerViewport *owner=nullptr;
        void mouseDown(const MouseEvent &event) override { if(owner->pressed)owner->pressed(event); }
        void mouseDoubleClick(const MouseEvent &event) override { if(owner->doubleClicked)owner->doubleClicked(event); }
    } selection;
    bool applying=false;
    int direction=0;
    double origin=0,target=0,started=0;
    int maximum() const { const auto *view=getViewedComponent();return view?std::max(0,view->getHeight()-getViewHeight()):0; }
    void apply(double y) {
        const ScopedValueSetter<bool> publishing(applying,true);
        setViewPosition(0,jlimit(0,maximum(),roundToInt(y)));
    }
    void visibleAreaChanged(const juce::Rectangle<int> &) override {
        if(!applying)cancelWheel();
        if(moved)moved();
    }
    void timerCallback() override {
        const auto fraction=jlimit(0.,1.,(Time::getMillisecondCounterHiRes()-started)/110.);
        const auto eased=1-std::pow(1-fraction,3.);
        apply(origin+(target-origin)*eased);
        if(fraction>=1)stopTimer();
    }
};
}
