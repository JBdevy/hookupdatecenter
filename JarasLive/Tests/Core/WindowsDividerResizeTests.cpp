#include <iostream>
#include <stdexcept>

// The harness includes the real DragDivider class with its frame callback
// exposed, so a burst of input can be tested without depending on timer jitter.
int main() {
    juce::ScopedJuceInitialiser_GUI gui;
    using namespace juce;
    using catlive::DragDivider;
    const auto require=[](bool value,const char *message) {
        if(!value)throw std::runtime_error(message);
    };
    const auto event=[](Component &view,int x,int y,bool down=true) {
        const Point<float> point{float(x),float(y)};const auto time=Time::getCurrentTime();
        return MouseEvent(Desktop::getInstance().getMainMouseSource(),point,
            ModifierKeys(down?ModifierKeys::leftButtonModifier:0),1,0,0,0,0,
            &view,&view,time,point,time,1,false);
    };
    DragDivider divider(false);divider.setSize(1000,6);divider.setCoalescedResize(true);
    int starts=0,ends=0,height=300;std::vector<int> changes;
    divider.started=[&]{++starts;};
    divider.moved=[&](int delta){changes.push_back(delta);height=300-delta;};
    divider.ended=[&]{++ends;require(height==573,"Release saved an obsolete height");};
    divider.mouseDown(event(divider,200,0));
    for(int y=-3;y>=-200;--y)divider.mouseDrag(event(divider,200,y));
    require(starts==1 && changes.empty(),"High-frequency input ran a layout per mouse event");
    divider.flushResize();
    require(changes==std::vector<int>{-200} && height==500,"A frame must use only the latest absolute position");
    for(int y=-201;y>=-260;--y)divider.mouseDrag(event(divider,200,y));
    divider.mouseUp(event(divider,200,-273,false));
    require(changes==std::vector<int>({-200,-273}) && ends==1,"Release must commit the final pointer position");
    divider.flushResize();
    require(changes.size()==2 && !divider.isTimerRunning(),"Resize work continued after release");
    // Existing side rails preserve immediate dragging and vertical scrolling.
    DragDivider immediate(false);int direct=0;immediate.moved=[&](int){++direct;};
    immediate.mouseDown(event(immediate,0,0));
    for(int y=3;y<10;++y)immediate.mouseDrag(event(immediate,0,y));
    immediate.mouseUp(event(immediate,0,9,false));
    require(direct==7,"Non-coalesced dividers changed their input behavior");
    DragDivider rail;rail.setSize(8,400);int scroll=0,resizes=0;
    rail.scrollMetrics=[] {return DragDivider::ScrollMetrics{0,400,2000};};
    rail.scrollTo=[&](int y){scroll=y;};rail.moved=[&](int){++resizes;};
    rail.mouseDown(event(rail,4,200));rail.mouseDrag(event(rail,4,220));rail.mouseUp(event(rail,4,220,false));
    require(scroll>0 && resizes==0,"The scroll rail became a resizing gesture");
    std::cout<<"WINDOWS_DIVIDER_BURST_LATEST_POSITION_RELEASE_FLUSH_SCROLL_RAIL_OK\n";
}
