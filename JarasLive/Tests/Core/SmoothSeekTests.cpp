#include "../../Core/Transport/Engine.hpp"
#include <cassert>
#include <algorithm>
#include <cmath>
#include <iostream>
using namespace jaras;
static bool near(double a,double b) { return std::abs(a-b)<1e-7; }
static Project fixture() {
    Project p; p.id="p";p.name="Seek";
    p.songs={{"song","Song",60,120,{{"track","Track",{"other"}}},{{"r1","One",0,30},{"r2","Two",35,60}}}};
    auto& s=p.songs[0];
    s.markers=std::vector<TimelineMarker>{{"a","Verse",0,0},{"normal","Cue",3,0},{"b","Chorus",10,0},{"c","Bridge",20,0},{"d","Next song",40,0},{"z","Closing",30,0}};
    for(auto& m:*s.markers) if(m.id!="normal") m.section=true;
    return p;
}
int main() {
    // Moving to another song carries the edit cursor to the exact target,
    // even when the playback tick has overshoot. Arming alone cannot move it.
    for (bool drawer : {false, true}) for (bool beginning : {false, true}) {
        auto project = fixture();
        if (drawer) {
            project.songs[0].parts.push_back({"parent", "Unified", 0, 60});
            project.songs[0].parts[0].parentRegionID = "parent";
            project.songs[0].parts[1].parentRegionID = "parent";
        }
        Engine jump; jump.loadProject(project);
        jump.execute({CommandKind::seek,"",5}); jump.execute({CommandKind::play});
        jump.execute({CommandKind::editSeek,"",2});
        jump.execute({CommandKind::queueSection,beginning ? "r2" : "d"});
        jump.advance(4.75);
        assert(near(jump.transport().editPosition,2));
        jump.advance(0.5);
        const double destination = beginning ? 35 : 40;
        assert(jump.transport().playing && near(jump.transport().position,destination + 0.25));
        assert(near(jump.transport().editPosition,destination));
        jump.advance(0.5);
        assert(near(jump.transport().editPosition,destination)); // Editing head stays at the jump target.
    }
    Engine e; e.loadProject(fixture());
    e.execute({CommandKind::editSeek,"",1});e.execute({CommandKind::toggleLoop});
    assert(e.transport().loop.end==10); // ordinary cue at 3 cannot delimit Repeat
    e.execute({CommandKind::toggleLoop});
    e.execute({CommandKind::queueSection,"b"}); assert(near(e.transport().editPosition,10)); assert(!e.transport().playing);
    e.execute({CommandKind::seek,"",0});e.execute({CommandKind::play});e.execute({CommandKind::queueSection,"c"});
    e.advance(4);assert(near(e.transport().position,4));assert(e.transport().queuedSectionMarkerId=="c");
    e.advance(7);assert(near(e.transport().position,21));assert(!e.transport().queuedSectionMarkerId);assert(e.transport().sectionJumpSerial==1);
    e.execute({CommandKind::queueSection,"a"});e.execute({CommandKind::queueSection,"a"});assert(!e.transport().queuedSectionMarkerId);
    e.execute({CommandKind::seek,"",2});e.execute({CommandKind::queueSection,"a"});e.execute({CommandKind::queueSection,"b"});
    e.execute({CommandKind::pause});e.advance(20);assert(near(e.transport().position,2));
    e.execute({CommandKind::play});e.advance(8);assert(near(e.transport().position,10));assert(!e.transport().queuedSectionMarkerId);
    e.execute({CommandKind::seek,"",1});e.execute({CommandKind::subSeek,"",40});e.execute({CommandKind::subPlay});e.execute({CommandKind::queueSection,"c"});
    e.advance(10);assert(near(e.transport().position,21));assert(near(e.transport().subPlay.position,50));
    e.execute({CommandKind::subStop});e.execute({CommandKind::seek,"",5});e.execute({CommandKind::queueSection,"d"});e.advance(6);
    assert(near(e.transport().position,41));assert(e.transport().regionId=="r2");
    e.execute({CommandKind::seek,"",1});e.execute({CommandKind::queueSection,"c"});
    auto edited=e.project();auto& m=*edited.songs[0].markers;m.erase(std::remove_if(m.begin(),m.end(),[](const auto& x){return x.id=="c";}),m.end());
    e.applyProjectEdit(edited);e.advance(10);assert(near(e.transport().position,11));assert(!e.transport().queuedSectionMarkerId);
    bool rejected=false;try { e.setMarker("outside","Outside",32,0,{},{},{},{},true); }catch(...) {rejected=true;}assert(rejected);
    e.execute({CommandKind::stopAll});e.loadProject(fixture());
    auto loopProject=e.project(); MultiLoop loop;loop.id="loop";loop.name="Loop";loop.marker1="b";loop.marker2="c";loopProject.songs[0].parts[0].multiLoops={loop};
    e.applyProjectEdit(loopProject);e.execute({CommandKind::seek,"",15});e.execute({CommandKind::play});e.advance(6);
    assert(near(e.transport().position,11));auto serial=e.transport().sectionJumpSerial;assert(serial==1);
    e.execute({CommandKind::queueSection,"a"});e.advance(10);assert(near(e.transport().position,1));assert(e.transport().sectionJumpSerial==serial+1);
    // A trigger at the loop end wins over repeating; long ticks retain overshoot.
    e.execute({CommandKind::seek,"",18});e.execute({CommandKind::queueSection,"d"});e.advance(2.25);assert(near(e.transport().position,40.25));
    // Escape never clears a lower-priority transport action in the same press.
    for (double selection : {0.0, 1.0}) {
        Engine cancel; auto project = fixture();
        RegionSetlist setlist; setlist.autoAdvance = true; project.regionSetlist = setlist;
        cancel.loadProject(project); cancel.execute({CommandKind::play}); cancel.advance(2);
        cancel.execute({CommandKind::toggleLoop});
        cancel.execute({CommandKind::queueSection,"c"});
        cancel.execute({CommandKind::queue,"song"});
        assert(cancel.transport().queuedRegionId == "r2" && cancel.transport().loop.enabled);
        auto serial = cancel.transport().sectionJumpSerial;
        cancel.execute({CommandKind::cancelSection});
        cancel.execute({CommandKind::cancelSection}); // A late/repeated Remote cancel cannot touch the loop or song.
        assert(!cancel.transport().queuedSectionMarkerId && cancel.transport().loop.enabled);
        assert(cancel.transport().queuedRegionId == "r2" && cancel.project().regionSetlist->autoAdvance);
        cancel.execute({CommandKind::queueSection,"c"});
        cancel.execute({CommandKind::escape,"",selection});
        assert(cancel.transport().queuedSectionMarkerId == "c" && near(cancel.transport().sectionQueueStartedAt,2));
        assert(!cancel.transport().loop.enabled && !cancel.transport().loop.start && !cancel.transport().loop.end);
        assert(cancel.transport().queuedRegionId == "r2");
        assert(cancel.transport().queue.songId == "song");
        assert(cancel.project().regionSetlist->autoAdvance);
        cancel.execute({CommandKind::escape,"",selection});
        assert(!cancel.transport().queuedSectionMarkerId && !cancel.transport().sectionQueueStartedAt);
        assert(cancel.transport().queuedRegionId == "r2" && cancel.project().regionSetlist->autoAdvance);
        assert(cancel.transport().queue.songId == "song");
        cancel.execute({CommandKind::escape,"",selection});
        assert(!cancel.transport().queuedRegionId && !cancel.transport().queue.songId && cancel.transport().playing && near(cancel.transport().position,2));
        assert(!cancel.project().regionSetlist->autoAdvance);
        assert(cancel.transport().sectionJumpSerial == serial);
        cancel.advance(9); assert(near(cancel.transport().position,11)); // No late jump or repeated loop.
        assert(!cancel.transport().queuedRegionId); // Auto cannot silently re-arm the canceled song.
    }
    // Releasing a multiloop keeps its fader release and the armed section. Auto
    // remains active until the song queue is explicitly reached by Escape.
    {
        Engine cancel; auto project = loopProject;
        project.regionSetlist = RegionSetlist{}; project.regionSetlist->autoAdvance = true;
        cancel.loadProject(project); cancel.execute({CommandKind::seek,"",15}); cancel.execute({CommandKind::play});
        cancel.execute({CommandKind::queueSection,"a"});
        assert(cancel.transport().multiLoop && cancel.transport().loop.enabled);
        cancel.execute({CommandKind::escape});
        assert(!cancel.transport().loop.enabled && cancel.transport().multiLoop->released);
        assert(cancel.transport().queuedSectionMarkerId == "a" && cancel.transport().queuedRegionId == "r2");
        assert(cancel.project().regionSetlist->autoAdvance);
        cancel.execute({CommandKind::escape});
        assert(!cancel.transport().queuedSectionMarkerId && cancel.transport().queuedRegionId == "r2");
        assert(cancel.project().regionSetlist->autoAdvance);
        cancel.execute({CommandKind::escape});
        assert(!cancel.transport().queuedRegionId && !cancel.project().regionSetlist->autoAdvance);
    }
    // The currently playing section can queue a return to its own start.
    Engine same; same.loadProject(fixture());
    same.execute({CommandKind::seek,"",15}); same.execute({CommandKind::play});
    same.execute({CommandKind::queueSection,"b"});
    assert(same.transport().queuedSectionMarkerId=="b" && near(same.transport().sectionQueueStartedAt,15));
    same.advance(4.5); assert(near(same.transport().position,19.5));
    same.advance(0.75);
    assert(same.transport().playing && near(same.transport().position,10.25));
    assert(!same.transport().queuedSectionMarkerId && same.transport().sectionJumpSerial==1);
    // INÍCIO uses the region identity, not a persisted/duplicated marker.
    Engine start; start.loadProject(fixture());
    start.execute({CommandKind::queueSection,"r2"});
    assert(!start.transport().playing && near(start.transport().editPosition,35));
    start.execute({CommandKind::seek,"",5}); start.execute({CommandKind::play});
    start.execute({CommandKind::queueSection,"r1"}); start.advance(5.25);
    assert(near(start.transport().position,0.25) && !start.transport().queuedSectionMarkerId);
    start.execute({CommandKind::queueSection,"r2"}); start.advance(10);
    assert(near(start.transport().position,35.25) && start.transport().regionId=="r2");
    start.execute({CommandKind::queueSection,"r2"}); start.execute({CommandKind::cancelSection});
    start.advance(5); assert(near(start.transport().position,40.25));
    start.execute({CommandKind::queueSection,"r1"});
    auto moved=start.project(); moved.songs[0].parts[0].startTime=2;
    start.applyProjectEdit(moved);
    start.execute({CommandKind::stopAll}); start.execute({CommandKind::queueSection,"r1"});
    assert(near(start.transport().editPosition,2));
    // The end of the playing song is a seek trigger without an explicit marker.
    // It wins over the normal Stop/Auto/fila action and consumes overshoot once.
    for (int mode = 0; mode < 4; ++mode) {
        auto project = fixture();
        auto& markers = *project.songs[0].markers;
        markers.erase(std::remove_if(markers.begin(), markers.end(), [](const auto& marker) { return marker.id == "z"; }), markers.end());
        RegionSetlist list; list.stopAtRegionEnd = mode == 1; list.autoAdvance = mode == 2;
        project.regionSetlist = list;
        Engine boundary; boundary.loadProject(project);
        boundary.execute({CommandKind::seek,"",25}); boundary.execute({CommandKind::play});
        if (mode == 3) boundary.execute({CommandKind::queueRegion,"r2"});
        boundary.execute({CommandKind::queueSection,"r1"});
        boundary.advance(4.75);
        assert(boundary.transport().queuedSectionMarkerId == "r1" && near(boundary.transport().position,29.75));
        boundary.advance(0.5);
        assert(boundary.transport().playing && near(boundary.transport().position,0.25));
        assert(!boundary.transport().queuedSectionMarkerId && boundary.transport().sectionJumpSerial == 1);
    }
    {
        Engine finalSong; finalSong.loadProject(fixture());
        finalSong.execute({CommandKind::seek,"",55}); finalSong.execute({CommandKind::play});
        finalSong.execute({CommandKind::queueSection,"b"}); finalSong.advance(5.75);
        assert(finalSong.transport().playing && near(finalSong.transport().position,10.75));
        assert(finalSong.transport().sectionJumpSerial == 1);
        // A completely marker-free song can still jump to its virtual INÍCIO.
        auto project = fixture(); project.songs[0].markers.reset();
        finalSong.execute({CommandKind::stopAll}); finalSong.loadProject(project); finalSong.execute({CommandKind::seek,"",29}); finalSong.execute({CommandKind::play});
        finalSong.execute({CommandKind::queueSection,"r1"}); finalSong.advance(1.5);
        assert(finalSong.transport().playing && near(finalSong.transport().position,0.5));
    }
    // Ignore Next follows its own final audio item, even beyond the following
    // region and its markers. Crossing that region cannot cancel the armed seek.
    for (double audioEnd : {18.0, 25.0}) {
        auto project = fixture(); auto& song = project.songs[0]; song.duration = 100;
        song.parts = {{"root","Unified",0,60},{"first","First",0,20},{"second","Second",20,60},{"target","Target",80,100}};
        song.parts[1].parentRegionID = "root"; song.parts[2].parentRegionID = "root";
        AudioClip clip; clip.id="tail"; clip.name="Tail"; clip.startTime=0; clip.duration=audioEnd; clip.audioFile=AudioFile{"tail.wav"};
        song.tracks[0].clips = {clip};
        TimelineMarker foreign{"foreign","Next song section",21,0}; foreign.section=true; foreign.regionOwnerID="second";
        song.markers = std::vector<TimelineMarker>{foreign};
        Engine tail; tail.loadProject(project); tail.execute({CommandKind::selectRegion,"first"}); tail.execute({CommandKind::play});
        tail.advance(15); tail.execute({CommandKind::ignoreNext}); tail.execute({CommandKind::queueSection,"target"});
        assert(tail.transport().ignoreNextEnd == audioEnd);
        if (audioEnd > 20) {
            tail.advance(6.5);
            assert(near(tail.transport().position,21.5) && tail.transport().queuedSectionMarkerId=="target");
            tail.advance(1.5);
            assert(near(tail.transport().position,23) && tail.transport().queuedSectionMarkerId=="target");
            tail.advance(2.25);
        } else tail.advance(3.25);
        assert(tail.transport().playing && near(tail.transport().position,80.25));
        assert(tail.transport().regionId=="target" && !tail.transport().ignoreNextEnd && !tail.transport().queuedSectionMarkerId);
        assert(tail.transport().sectionJumpSerial==1);
    }
    // Atomic tempo batch: all markers change together, preserving later BPM.
    for (bool relative : {false,true}) {
        auto project=fixture();
        TimelineMarker first{"tempo1","TEMPO",0,0x999999}, second{"tempo2","TEMPO",10,0x999999}, outside{"tempo3","TEMPO",30,0x999999};
        first.tempoBPM=120; second.tempoBPM=150; outside.tempoBPM=90;
        for(auto* marker : {&first,&second,&outside}) {
            marker->tempoBeats=4; marker->tempoUnit=4;
            marker->tempoTimebase=relative ? "relative" : "free";
            marker->tempoReferenceBPM=marker->tempoBPM;
        }
        project.songs[0].markers=std::vector<TimelineMarker>{first,second,outside};
        Engine tempo; tempo.loadProject(project); tempo.execute({CommandKind::seek,"",15});
        first.tempoBPM=121; second.tempoBPM=151;
        tempo.setMarkers({first,second},{},true);
        const auto& markers=*tempo.project().songs[0].markers;
        assert(markers[0].tempoBPM==121 && markers[1].tempoBPM==151 && markers[2].tempoBPM==90);
        assert(markers[0].tempoReferenceBPM==120 && markers[1].tempoReferenceBPM==150);
        if(relative) { assert(markers[1].position<10 && tempo.transport().position<15); }
        else { assert(near(markers[1].position,10) && near(tempo.transport().position,15)); }
        auto invalid=first; invalid.tempoBPM=301; bool refused=false;
        try { tempo.setMarkers({invalid},{},true); } catch(...) {refused=true;}
        assert(refused && tempo.project().songs[0].markers->at(0).tempoBPM==121);
    }
    std::cout<<"SMOOTH_SEEK_OK\n";
}
