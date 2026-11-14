#include "../../Core/Tracks/SharedItemBoundary.hpp"
#include <cassert>
#include <iostream>
int main() {
    using namespace jaras;
    AudioClip a; a.id="left"; a.startTime=5; a.duration=5; a.playbackRate=1.5; a.sourceOffset=2;
    AudioClip b; b.id="right"; b.startTime=10; b.duration=8; b.playbackRate=2; b.sourceOffset=6;
    auto moved=sharedItemBoundary(a,b,12,40,40);
    assert(moved && moved->first.startTime==5 && moved->first.duration==7);
    assert(moved->second.startTime==12 && moved->second.duration==6 && moved->second.sourceOffset==10);
    assert(moved->first.playbackRate==1.5 && moved->second.playbackRate==2);
    moved=sharedItemBoundary(a,b,8,40,40);
    assert(moved && moved->first.duration==3 && moved->second.sourceOffset==2 && moved->second.duration==10);
    moved=sharedItemBoundary(a,b,4,40,40);
    assert(moved && moved->first.duration>=.01-1e-9 && moved->second.startTime+moved->second.duration==18);
    b.recordingLane=1;assert(!sharedItemBoundary(a,b,11));b.recordingLane.reset();
    b.startTime+=.001;assert(!sharedItemBoundary(a,b,11));b.startTime=10;
    assert(!sharedItemBoundary(a,b,std::numeric_limits<double>::quiet_NaN()));
    a.text="first";b.text="second";
    moved=sharedItemBoundary(a,b,11);assert(moved && moved->first.text==a.text && moved->second.text==b.text);
    std::cout<<"SHARED_BOUNDARY_SOURCE_RATE_OUTER_ENDS_MINIMUM_GAPS_LANES_OK\n";
}
