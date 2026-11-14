#include "../../Core/Transport/Engine.hpp"
#include "../../Core/Songs/TempoEditMap.hpp"
namespace catlive { using jaras::ID; }
#include "../../Windows/Source/RegionLanes.h"
#include <iostream>
#include <stdexcept>
using namespace jaras;
static void check(bool value,const char* message){if(!value)throw std::runtime_error(message);}
static void near(double value,double expected,const char* message){check(std::abs(value-expected)<1e-8,message);}
static double point(const std::optional<std::string>& saved,const ID& id){
    const auto value=nlohmann::json::parse(*saved);
    for(const auto& p:value["envelopes"][0]["points"])if(p["id"]==id)return p["time"].get<double>();
    throw std::runtime_error("Missing automation point");
}
static const Track& track(const Song& song,const ID& id){
    for(const auto& t:song.tracks)if(t.id==id)return t;
    throw std::runtime_error("Missing track");
}
static Project fixture(){
    Project p;p.id="coverage";p.name="Coverage";
    Song s;s.id="song";s.name="Song";s.duration=500;s.bpm=120;
    s.regionOwnershipInitialized=true;s.regionOwnershipVersion=3;
    s.parts={{"a","20 seconds",0,40},{"b","60 seconds",40,100}};
    s.timeSettings=ProjectTimeSettings{};s.timeSettings->timebase=ProjectTimebase::relative;s.timeSettings->affectsAutomationLength=false;
    Track t;t.id="audio";t.name="Audio";t.role.id="other";
    AudioClip crossing;crossing.id="crossing";crossing.name="Crossing";crossing.startTime=20;crossing.duration=80;
    crossing.sourceOffset=3;crossing.playbackRate=.75;crossing.regionOwnerID="a";
    AudioClip loose=crossing;loose.id="loose";loose.name="Loose";loose.startTime=5;loose.duration=5;loose.regionOwnerID.reset();
    AudioClip outside=loose;outside.id="outside";outside.startTime=150;
    t.clips={crossing,loose,outside};
    Track programs;programs.id="programs";programs.name="Program Change";programs.role.id="programChange";
    programs.programChanges={{"program-a",20,4,1,"A"},{"program-b",70,5,1,"B"},{"program-out",150,6,1,"Outside"}};
    t.automationJSON=R"({"enabled":true,"mode":"read","envelopes":[{"id":"envelope","name":"Volume","target":{"kind":"volume"},"defaultValue":0.5,"custom":"preserve","points":[{"id":"a","time":15,"value":0.2,"shape":"smooth"},{"id":"b","time":85,"value":0.7,"shape":"linear"},{"id":"out","time":150,"value":0.5,"shape":"square"}]}]})";
    p.masterAutomationJSON=t.automationJSON;
    s.tracks={t,programs};
    TimelineMarker tempo{"tempo","TEMPO",60,0x999999};tempo.tempoBPM=144;tempo.tempoTimebase="relative";tempo.tempoReferenceBPM=120;
    s.markers=std::vector<TimelineMarker>{tempo,{"cue","Cue",65,0},{"outside-marker","Outside",150,0}};
    p.songs={s};return p;
}
int main(){try{
    auto p=fixture();Engine engine;engine.loadProject(p);
    check(regionMovementOwner(*engine.currentSong(),20,100,std::optional<ID>{"a"})=="b","60 seconds must win over the persisted 20-second owner");
    const auto previewA=catlive::previewRegionEdit(*engine.currentSong(),"a",200,240,false);
    check(bool(previewA),"Windows move preview failed");
    near(track(*previewA,"audio").clips[0].startTime,20,"Smaller overlap must not steal the crossing item in preview");
    near(track(*previewA,"audio").clips[1].startTime,205,"Loose material within the source area must follow the drag");
    engine.moveRegion("a",200);
    near(track(*engine.currentSong(),"audio").clips[0].startTime,20,"Smaller overlap must not move the crossing item");
    const auto previewB=catlive::previewRegionEdit(*engine.currentSong(),"b",400,460,false);
    engine.moveRegion("b",400);
    const auto& moved=*engine.currentSong();
    near(track(moved,"audio").clips[0].startTime,380,"The largest covered portion must carry the complete item");
    near(track(moved,"audio").clips[0].duration,80,"Region movement cannot stretch an item");
    near(track(moved,"audio").clips[0].playbackRate,.75,"Suspending timebase cannot change source speed");
    near(track(moved,"audio").clips[0].sourceOffset,3,"Region movement cannot retrim audio");
    check(track(moved,"audio").clips[0].regionOwnerID=="b","Committed movement records its new owner");
    near(track(*previewB,"audio").clips[0].startTime,track(moved,"audio").clips[0].startTime,"Windows preview differs from commit");
    near(point(track(moved,"audio").automationJSON,"a"),215,"First region automation did not follow");
    near(point(track(moved,"audio").automationJSON,"b"),445,"Second region automation did not follow");
    near(point(track(moved,"audio").automationJSON,"out"),150,"Outside automation moved");
    near(point(engine.project().masterAutomationJSON,"b"),445,"Master automation did not follow");
    near((*moved.markers)[0].position,420,"Tempo marker did not follow");
    near((*moved.markers)[1].position,425,"Cue marker did not follow");
    check((*moved.markers)[0].tempoBPM==144 && moved.timeSettings->timebase==ProjectTimebase::relative,"Movement changed saved tempo/timebase");
    auto cue=std::find_if(track(moved,"programs").programChanges.begin(),track(moved,"programs").programChanges.end(),[](const auto& m){return m.id=="program-b";});
    near(cue->position,430,"Program Change did not follow");
    engine.setProjectTiming(60,4,4,moved.timeSettings);
    near(point(track(*engine.currentSong(),"audio").automationJSON,"b"),890,"Automation must always follow BPM, even with the obsolete option false");
    near(point(engine.project().masterAutomationJSON,"b"),890,"Master automation must follow BPM");
    std::cout<<"REGION_MAXIMUM_OVERLAP_LOOSE_CONTENT_MARKERS_AUTOMATION_PROGRAMS_PREVIEW_AND_TIMEBASE_OK\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
