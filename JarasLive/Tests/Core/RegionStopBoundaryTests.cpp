#include "../../Core/Transport/Engine.hpp"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>
using namespace jaras;
static void require(bool ok, const char* why) { if (!ok) throw std::runtime_error(why); }
static void near(double a, double b, const char* why) { require(std::abs(a - b) < 1e-7, why); }
static Project fixture(bool stop = true) {
    Project p; p.id = "stop-boundary"; p.name = "STOP boundary";
    p.songs = {{"song", "Timeline", 60, 120, {}, {{"a", "A", 5, 10}, {"b", "B", 20, 30}}}};
    p.regionSetlist = RegionSetlist{}; p.regionSetlist->stopAtRegionEnd = stop;
    return p;
}
static void start(Engine& e, Project p, double position) {
    e.loadProject(std::move(p)); e.execute({CommandKind::seek, "", position}); e.execute({CommandKind::play});
}
static void advance(Engine& e, double duration, bool small) {
    while (duration > 1e-9) { const double step = small ? std::min(duration, .01) : duration; e.advance(step); duration -= step; }
}
int main() { try {
    int cases = 0;
    for (double position : {0., 4.999, 5., 9.999, 11., 29.999})
        for (bool stop : {false, true}) for (bool bypass : {false, true}) for (bool small : {false, true}) {
            Engine e; start(e, fixture(stop), position);
            if (bypass) e.execute({CommandKind::toggleMultiLoopBypass});
            advance(e, 31 - position, small);
            require(e.transport().playing == !stop, "STOP mode depends on tick size, starting position or Bypass");
            near(e.transport().position, stop ? (position < 10 ? 10 : 30) : 31, "STOP missed first region end after entering from empty space"); ++cases;
        }
    for (bool small : {false, true}) {
        Engine e; start(e, fixture(false), 7); auto settings = *e.project().regionSetlist; settings.stopAtRegionEnd = true; e.configureRegionSetlist(settings);
        advance(e, 5, small); require(!e.transport().playing, "Enabling STOP while playing failed"); near(e.transport().position, 10, "Runtime STOP crossed region end"); ++cases;
    }
    for (bool automatic : {false, true}) for (bool prepare : {false, true}) for (bool small : {false, true}) {
        auto p = fixture(); p.regionSetlist->autoAdvance = automatic; p.regionSetlist->prepareWithoutPlayback = prepare;
        Engine e; start(e, p, 0); if (!automatic) e.execute({CommandKind::queueRegion, "b"});
        advance(e, 10.25, small);
        require(e.transport().playing == !prepare && e.transport().regionId == "b", "Queue priority changed when entering region from empty space");
        near(e.transport().position, prepare ? 20 : 20.25, "Queued entry time consumed incorrectly");
        if (!prepare) { advance(e, 12, small); require(!e.transport().playing, "Final queued region ignored STOP"); near(e.transport().position, 30, "Final queued region end changed"); } ++cases;
    }
    for (bool small : {false, true}) {
        Engine e; start(e, fixture(), 0); e.execute({CommandKind::subPlay}); e.execute({CommandKind::subSeek, "", 20});
        advance(e, 10.25, small);
        require(e.transport().playing && !e.transport().subPlay.playing && e.transport().subPlayPromotion == 1, "STOP silenced already playing Subplay");
        near(e.transport().position, 30.25, "Entrance subdivision advanced Subplay twice"); ++cases;
    }
    for (bool small : {false, true}) {
        Engine e; start(e, fixture(), 0); e.execute({CommandKind::loopStart, "", 6}); e.execute({CommandKind::loopEnd, "", 8}); e.execute({CommandKind::toggleLoop});
        advance(e, 11, small); require(e.transport().playing && e.transport().loop.enabled, "STOP overrode explicit Repeat loop");
        near(e.transport().position, 7, "Repeat position changed with delayed tick"); ++cases;
    }
    for (bool small : {false, true}) {
        auto p = fixture(); p.songs.front().parts.front().totalLoop = true;
        Engine e; start(e, p, 0); advance(e, 11, small);
        require(e.transport().playing && e.transport().multiLoop.has_value(), "STOP overrode total-region loop");
        near(e.transport().position, 6, "Total-region loop lost elapsed time at entrance"); ++cases;
    }
    for (double position : {0., 6.5}) for (bool small : {false, true}) {
        auto p = fixture(); Part child{"child", "Drawer song", 6, 8}; child.parentRegionID = "a"; p.songs.front().parts.push_back(child);
        Engine e; start(e, p, position); advance(e, 12, small);
        require(!e.transport().playing, "Unified region failed to stop"); near(e.transport().position, 10, "STOP used drawer child end instead of unified end"); ++cases;
    }
    std::cout << "REGION_STOP_BOUNDARY_OK " << cases << " cases\n";
} catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; } }
