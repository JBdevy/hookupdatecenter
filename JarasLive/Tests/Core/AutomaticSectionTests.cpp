#include "../../Core/Transport/Engine.hpp"
#include "../../Core/Project/UnifiedRegionNaming.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
using namespace jaras;
static Project fixture(){
 Project p;p.id="project";p.name="Auto parts";
 p.songs={{"song","Song",80,120,{{"track","Track",{"other"}}},{{"one","One",0,40},{"two","Two",40,80}}}};
 auto& s=p.songs[0];s.markers=std::vector<TimelineMarker>{{"source","Source",10,0},{"target","Target",50,0},{"other","Other",60,0}};
 for(auto& m:*s.markers)m.section=true;
 s.markers->front().automaticSectionTargetID="target";return p;
}
static bool near(double a,double b){return std::abs(a-b)<1e-7;}
int main(){
 Engine e;e.loadProject(fixture());e.execute({CommandKind::play});e.advance(4.9);assert(!e.transport().queuedSectionMarkerId);
 e.advance(.2);assert(e.transport().queuedSectionMarkerId=="target");assert(near(e.transport().sectionQueueStartedAt,5));
 assert(e.transport().automaticSectionNotice=="1/Infinite saltos");
 e.advance(5);assert(near(e.transport().position,50.1));assert(!e.transport().queuedSectionMarkerId);
 assert(e.transport().automaticSectionNotice);e.advance(1.9);assert(e.transport().automaticSectionNotice);
 e.advance(.2);assert(!e.transport().automaticSectionNotice);
 Engine cancel;cancel.loadProject(fixture());cancel.execute({CommandKind::play});cancel.advance(5.1);cancel.execute({CommandKind::cancelSection});cancel.advance(5.1);assert(near(cancel.transport().position,10.2));assert(!cancel.transport().queuedSectionMarkerId);
 cancel.execute({CommandKind::seek,"",0});cancel.advance(5.1);assert(!cancel.transport().queuedSectionMarkerId);
 cancel.execute({CommandKind::stop});cancel.execute({CommandKind::seek,"",0});cancel.execute({CommandKind::play});cancel.advance(5.1);assert(cancel.transport().queuedSectionMarkerId=="target");
 Engine manual;manual.loadProject(fixture());manual.execute({CommandKind::play});manual.advance(5.1);manual.execute({CommandKind::queueSection,"other"});manual.advance(5);assert(near(manual.transport().position,60.1));
 Engine prior;prior.loadProject(fixture());prior.execute({CommandKind::play});prior.advance(2);prior.execute({CommandKind::queueSection,"other"});prior.advance(8.1);assert(near(prior.transport().position,60.1));
 auto missing=fixture();missing.songs[0].markers->erase(missing.songs[0].markers->begin()+1);Engine invalid;invalid.loadProject(missing);invalid.execute({CommandKind::play});invalid.advance(10.1);assert(near(invalid.transport().position,10.1));
 Engine large;large.loadProject(fixture());large.execute({CommandKind::play});large.advance(11);assert(near(large.transport().position,51));
 auto close=fixture();TimelineMarker earlier{"earlier","Earlier",8,0};earlier.section=true;close.songs[0].markers->push_back(earlier);
 Engine precise;precise.loadProject(close);precise.execute({CommandKind::play});precise.advance(5.1);
 assert(precise.transport().queuedSectionMarkerId=="target" && precise.nextSectionTrigger()==10);
 auto frame=projectSync::decode(projectSync::encode(precise.projectSyncFrame()).data(),projectSync::encode(precise.projectSyncFrame()).size());
 assert(frame.transport.automaticSectionTriggerId=="source");
 precise.advance(3);assert(near(precise.transport().position,8.1));precise.advance(2);assert(near(precise.transport().position,50.1));
 for(int limit : {0,1,2,3,4,5,20}) {
  auto project=fixture();auto& song=project.songs[0];
  song.markers->at(1).position=2;
  if(limit) song.markers->front().automaticSectionRepeatCount=limit;
  Engine counted;counted.loadProject(project);counted.execute({CommandKind::play});
  for(int index=0;index<(limit ? limit : 25);++index) {
   const auto serial=counted.transport().sectionJumpSerial;
   for(int tick=0;tick<110 && counted.transport().sectionJumpSerial==serial;++tick)counted.advance(.1);
   if(counted.transport().sectionJumpSerial!=serial+1) {
    std::cerr<<"Repeat limit="<<limit<<" occurrence="<<index+1<<" position="<<counted.transport().position<<" queued="<<counted.transport().queuedSectionMarkerId.value_or("none")<<'\n';
    return 1;
   }
  }
  if(limit) {
   const auto serial=counted.transport().sectionJumpSerial;
   counted.advance(.1);counted.advance(12);
   assert(counted.transport().sectionJumpSerial==serial);
   counted.execute({CommandKind::stop});counted.execute({CommandKind::seek,"",0});counted.execute({CommandKind::play});
   counted.advance(10.1);assert(counted.transport().sectionJumpSerial==serial+1);
  }
 }
 auto cancelledProject=fixture();cancelledProject.songs[0].markers->at(1).position=2;
 cancelledProject.songs[0].markers->front().automaticSectionRepeatCount=1;
 Engine retry;retry.loadProject(cancelledProject);retry.execute({CommandKind::play});retry.advance(5.1);
 retry.execute({CommandKind::cancelSection});retry.advance(6);assert(retry.transport().sectionJumpSerial==0);
 retry.execute({CommandKind::seek,"",0});retry.advance(10.1);assert(retry.transport().sectionJumpSerial==0);
 retry.execute({CommandKind::stop});retry.execute({CommandKind::seek,"",0});retry.execute({CommandKind::play});
 retry.advance(10.1);assert(retry.transport().sectionJumpSerial==1);
 auto triple=fixture();triple.songs[0].markers->at(1).position=2;
 triple.songs[0].markers->front().automaticSectionRepeatCount=3;
 Engine cancellations;cancellations.loadProject(triple);cancellations.execute({CommandKind::play});
 cancellations.advance(5.1);assert(cancellations.transport().automaticSectionNotice=="1/3 saltos");
 cancellations.execute({CommandKind::cancelSection});
 for(int occurrence=0;occurrence<5;++occurrence) {
  cancellations.execute({CommandKind::seek,"",0});cancellations.advance(10.1);
  assert(!cancellations.transport().queuedSectionMarkerId && cancellations.transport().sectionJumpSerial==0);
 }
 cancellations.execute({CommandKind::stop});cancellations.execute({CommandKind::seek,"",0});cancellations.execute({CommandKind::play});
 cancellations.advance(10.1);assert(cancellations.transport().sectionJumpSerial==1);
 assert(nextUnifiedRegionName("Group",{})=="001 - Group");
 assert(nextUnifiedRegionName("001 - 001 - Group",{"001 - First"})=="002 - Group");
 assert(nextUnifiedRegionName("Group",{"001 - First","002 - Second"})=="003 - Group");
 std::cout<<"Automatic section timing, cancellation, replacement, replay and missing destination passed\n";
}
