#include "../../Core/Transport/Engine.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
using namespace jaras;
bool near(double a,double b) { return std::abs(a-b)<1e-8; }
Project fixture() {
    Project p; p.id="project"; p.name="Test";
    p.songs={{"song","Song",60,120,{{"track","Track",{"other"}}},{{"region","Region",0,60}}}};
    auto& s=p.songs[0];
    s.markers=std::vector<TimelineMarker>{{"a","A",10,0},{"b","B",20,0}};
    for (auto& marker : *s.markers) { marker.section = true; marker.loopSection = true; }
    MultiLoop l; l.id="loop";l.name="Chorus";l.marker1="a";l.marker2="b";l.fadeSeconds=3;
    l.tracks={{"track",0.2,true,true,true}};s.parts[0].multiLoops={l};return p;
}
int main() {
    Engine bypass; bypass.loadProject(fixture()); bypass.execute({CommandKind::play}); bypass.advance(12);
    assert(bypass.transport().multiLoop && bypass.transport().loop.enabled);
    bypass.execute({CommandKind::toggleMultiLoopBypass});
    assert(bypass.transport().multiLoopsBypassed && !bypass.transport().multiLoop && !bypass.transport().loop.enabled);
    assert(bypass.project().songs[0].parts[0].multiLoops[0].enabled.value_or(true));
    assert(bypass.project().songs[0].parts[0].multiLoops[0].tracks[0].autoFader);
    bypass.advance(1);
    bypass.execute({CommandKind::toggleMultiLoopBypass});
    assert(!bypass.transport().multiLoopsBypassed && near(bypass.transport().position,13));
    assert(bypass.transport().multiLoop && bypass.transport().multiLoop->gates && bypass.transport().loop.enabled);
    assert(near(bypass.transport().multiLoop->amount,1));
    assert(bypass.transport().multiLoop->config.tracks[0].mute && bypass.transport().multiLoop->config.tracks[0].solo);
    bypass.execute({CommandKind::toggleMultiLoopBypass}); bypass.execute({CommandKind::seek,"",0}); bypass.advance(25);
    assert(near(bypass.transport().position,25) && !bypass.transport().multiLoop); // Long ticks must not discover bypassed pairs.
    bypass.execute({CommandKind::seek,"",8.5}); bypass.execute({CommandKind::toggleMultiLoopBypass});
    assert(bypass.transport().multiLoop && near(bypass.transport().multiLoop->amount,0.5) && !bypass.transport().multiLoop->gates);
    bypass.execute({CommandKind::toggleMultiLoopBypass}); bypass.execute({CommandKind::stop}); bypass.execute({CommandKind::play});
    assert(bypass.transport().multiLoopsBypassed && !bypass.transport().multiLoop);

    auto disabledProject = fixture();
    disabledProject.songs[0].parts[0].multiLoops[0].enabled = false;
    Engine disabled; disabled.loadProject(disabledProject); disabled.execute({CommandKind::play});
    disabled.advance(8.5);
    assert(!disabled.transport().multiLoop); // No pre-fade for a disabled imported pair.
    disabled.advance(17);
    assert(near(disabled.transport().position,25.5) && !disabled.transport().loop.enabled);
    disabled.execute({CommandKind::seek,"",12});
    assert(!disabled.transport().multiLoop && !disabled.transport().loop.enabled);
    auto enabledProject = disabled.project();
    enabledProject.songs[0].parts[0].multiLoops[0].enabled = true;
    enabledProject.songs[0].parts[0].multiLoops[0].mixerEnabled = false;
    disabled.applyProjectEdit(enabledProject);
    assert(disabled.transport().multiLoop && disabled.transport().loop.enabled);
    assert(disabled.transport().multiLoop->config.tracks[0].autoFader);
    assert(!disabled.transport().multiLoop->config.tracks[0].mute && !disabled.transport().multiLoop->config.tracks[0].solo);
    assert(disabled.project().songs[0].parts[0].multiLoops[0].tracks[0].mute); // Presets remain saved.
    enabledProject.songs[0].parts[0].multiLoops[0].mixerEnabled = true;
    disabled.applyProjectEdit(enabledProject);
    assert(disabled.transport().multiLoop->config.tracks[0].mute && disabled.transport().multiLoop->config.tracks[0].solo);
    enabledProject.songs[0].parts[0].multiLoops[0].enabled = false;
    disabled.applyProjectEdit(enabledProject);
    assert(!disabled.transport().multiLoop && !disabled.transport().loop.enabled);
    disabled.advance(12);
    assert(near(disabled.transport().position,24));
    Engine longTick; longTick.loadProject(disabledProject); longTick.execute({CommandKind::play}); longTick.advance(25);
    assert(near(longTick.transport().position,25) && !longTick.transport().multiLoop);
    auto sharedAnchorProject = fixture();
    sharedAnchorProject.songs[0].parts[0].startTime = 10;
    sharedAnchorProject.songs[0].parts[0].parentRegionID = "parent";
    sharedAnchorProject.songs[0].parts.push_back({"parent","Special",0,60});
    sharedAnchorProject.songs[0].markers->at(0).sourceRegionID = "region";
    sharedAnchorProject.songs[0].markers->at(0).unifiedRegionID = "parent";
    Engine sharedAnchor; sharedAnchor.loadProject(sharedAnchorProject); sharedAnchor.execute({CommandKind::play}); sharedAnchor.advance(25);
    assert(near(sharedAnchor.transport().position,15) && sharedAnchor.transport().loop.enabled);
    sharedAnchor.execute({CommandKind::seek,"",12});
    assert(sharedAnchor.transport().multiLoop && sharedAnchor.transport().loop.start == 10);
    Engine e;e.loadProject(fixture());e.execute({CommandKind::play});e.advance(8.5);
    assert(e.transport().multiLoop && near(e.transport().multiLoop->amount,0.5));
    assert(!e.transport().loop.enabled && !e.transport().multiLoop->gates);
    e.advance(1.5);assert(e.transport().loop.enabled && e.transport().multiLoop->gates);
    assert(near(e.transport().position,10));e.advance(25.25);assert(near(e.transport().position,15.25));
    assert(e.project().songs[0].tracks[0].volume==1 && !e.project().songs[0].tracks[0].mute && !e.project().songs[0].tracks[0].solo);
    e.execute({CommandKind::toggleLoop});assert(!e.transport().loop.enabled && e.transport().multiLoop->released);
    e.advance(2.375);assert(near(e.transport().multiLoop->amount,0.5) && e.transport().multiLoop->gates);
    e.execute({CommandKind::toggleLoop});assert(e.transport().loop.enabled && near(e.transport().multiLoop->amount,1));
    e.execute({CommandKind::toggleLoop});e.advance(2.375);assert(near(e.transport().position,20) && !e.transport().multiLoop && !e.transport().loop.enabled);
    e.execute({CommandKind::seek,"",12});e.advance(0);assert(e.transport().multiLoop && e.transport().loop.enabled);
    e.execute({CommandKind::stop});assert(!e.transport().multiLoop && !e.transport().loop.enabled);
    e.execute({CommandKind::editSeek,"",0});e.execute({CommandKind::play});e.advance(32);assert(near(e.transport().position,12));
    e.execute({CommandKind::pause});assert(e.transport().multiLoop);e.execute({CommandKind::play});e.advance(1);assert(near(e.transport().position,13));
    auto edited=e.project();edited.songs[0].markers->erase(edited.songs[0].markers->begin());e.applyProjectEdit(edited);e.advance(0.1);assert(!e.transport().multiLoop);
    auto unified=fixture();unified.songs[0].parts[0].id="child";unified.songs[0].parts[0].parentRegionID="parent";
    unified.songs[0].parts.push_back({"parent","Special",0,60});
    e.execute({CommandKind::stop});e.loadProject(unified);e.execute({CommandKind::play});e.advance(12);assert(e.transport().loop.enabled);
    auto excluded=fixture();excluded.songs[0].markers->at(0).tempoBPM=120;
    e.execute({CommandKind::stop});e.loadProject(excluded);e.execute({CommandKind::play});e.advance(25);assert(!e.transport().multiLoop && near(e.transport().position,25));
    for (const auto& marker : {"a", "b"}) {
        Engine deletion; deletion.loadProject(fixture()); deletion.execute({CommandKind::play}); deletion.advance(12);
        deletion.deleteManualMarker(marker);
        assert(deletion.project().songs[0].parts[0].multiLoops.empty());
        assert(!deletion.transport().multiLoop && !deletion.transport().loop.enabled);
    }
    Engine release; release.loadProject(fixture()); release.execute({CommandKind::play}); release.advance(12);
    release.execute({CommandKind::escape,"",1});
    assert(release.transport().multiLoop->released && release.transport().multiLoop->gates && !release.transport().loop.enabled);
    release.advance(4); assert(near(release.transport().multiLoop->amount,0.5));
    release.execute({CommandKind::toggleLoop}); assert(release.transport().loop.enabled && !release.transport().multiLoop->released);
    auto manual = fixture(); manual.songs[0].parts[0].multiLoops.clear();
    manual.songs[0].parts[0].endTime = 30;
    manual.songs[0].parts.push_back({"next", "Next", 30, 60});
    manual.regionSetlist = RegionSetlist{}; manual.regionSetlist->autoAdvance = true;
    Engine escape; escape.loadProject(manual); escape.execute({CommandKind::play});
    assert(escape.transport().queuedRegionId == "next"); // Auto already armed it; selecting it again now cancels.
    escape.execute({CommandKind::toggleLoop});
    assert(escape.transport().loop.start == 0 && escape.transport().loop.end == 10);
    escape.advance(12); assert(near(escape.transport().position, 2));
    escape.execute({CommandKind::escape,"",1});
    assert(!escape.transport().loop.enabled && !escape.project().regionSetlist->autoAdvance);
    assert(escape.transport().queuedRegionId == "next");
    escape.execute({CommandKind::escape}); assert(!escape.transport().queuedRegionId);
    escape.execute({CommandKind::queueRegion,"next"}); escape.execute({CommandKind::escape,"",1});
    assert(!escape.transport().queuedRegionId); // Queue cancellation wins over an area selection.
    escape.execute({CommandKind::escape}); assert(!escape.transport().queuedRegionId);
    escape.execute({CommandKind::loopStart,"",25}); escape.execute({CommandKind::loopEnd,"",35});
    escape.execute({CommandKind::toggleLoop}); escape.advance(36);
    assert(near(escape.transport().position,28));
    escape.execute({CommandKind::toggleLoop}); assert(!escape.transport().loop.start && !escape.transport().loop.end);
    manual.songs[0].parts.clear();
    Engine outside; outside.loadProject(manual); outside.execute({CommandKind::toggleLoop}); assert(!outside.transport().loop.enabled);
    outside.execute({CommandKind::loopStart,"",2}); outside.execute({CommandKind::loopEnd,"",5});
    outside.execute({CommandKind::toggleLoop}); outside.execute({CommandKind::play}); outside.advance(6);
    assert(outside.transport().loop.enabled && near(outside.transport().position,3));
    auto totalProject=fixture();totalProject.songs[0].parts[0].totalLoop=true;
    Engine total;total.loadProject(totalProject);total.execute({CommandKind::play});total.advance(65);
    assert(near(total.transport().position,5) && total.transport().loop.start==0 && total.transport().loop.end==60);
    assert(total.transport().multiLoop->id=="region" && total.transport().multiLoop->config.tracks.empty());
    assert(total.project().songs[0].parts[0].multiLoops.size()==1);
    total.execute({CommandKind::seek,"",12});total.execute({CommandKind::toggleLoop});total.advance(10);
    assert(near(total.transport().position,22) && !total.transport().loop.enabled && total.transport().multiLoop->released);
    total.execute({CommandKind::toggleLoop});assert(total.transport().loop.enabled);
    total.execute({CommandKind::seek,"",12});
    auto disabledTotal=total.project();disabledTotal.songs[0].parts[0].totalLoop=false;total.applyProjectEdit(disabledTotal);
    assert(total.transport().multiLoop->id=="loop" && total.transport().loop.start==10 && total.transport().loop.end==20);
    auto noMarkers=fixture();noMarkers.songs[0].markers.reset();noMarkers.songs[0].parts[0].multiLoops.clear();
    noMarkers.songs[0].parts[0].startTime=5;noMarkers.songs[0].parts[0].endTime=30;noMarkers.songs[0].parts[0].totalLoop=true;
    Engine crossing;crossing.loadProject(noMarkers);crossing.execute({CommandKind::play});crossing.advance(36);
    assert(near(crossing.transport().position,11) && crossing.transport().loop.start==5 && crossing.transport().loop.end==30);
    auto totalGroup=unified;totalGroup.songs[0].parts.back().totalLoop=true;
    Engine groupedTotal;groupedTotal.loadProject(totalGroup);groupedTotal.execute({CommandKind::play});groupedTotal.advance(25);
    assert(near(groupedTotal.transport().position,25) && groupedTotal.transport().multiLoop->id=="parent");
    assert(groupedTotal.project().songs[0].parts[0].multiLoops.size()==1);
    std::cout<<"MULTILOOP_FADE_ARM_WRAP_RELEASE_REARM_STOP_PAUSE_LONG_TICK_UNIFIED_OK\n";
}
