#include "../../Core/Transport/Engine.hpp"
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
 e.advance(5);assert(near(e.transport().position,50.1));assert(!e.transport().queuedSectionMarkerId);
 Engine cancel;cancel.loadProject(fixture());cancel.execute({CommandKind::play});cancel.advance(5.1);cancel.execute({CommandKind::cancelSection});cancel.advance(5.1);assert(near(cancel.transport().position,10.2));assert(!cancel.transport().queuedSectionMarkerId);
 cancel.execute({CommandKind::seek,"",0});cancel.advance(5.1);assert(cancel.transport().queuedSectionMarkerId=="target");
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
 std::cout<<"Automatic section timing, cancellation, replacement, replay and missing destination passed\n";
}
