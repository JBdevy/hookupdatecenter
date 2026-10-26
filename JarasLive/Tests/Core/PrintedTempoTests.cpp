#include "../../Core/Transport/Engine.hpp"
#include "../../Core/Songs/TempoEditMap.hpp"
#include <cmath>
#include <iostream>
#include <stdexcept>
using namespace jaras;
static void require(bool ok,const char* why) {if(!ok)throw std::runtime_error(why);}
static void near(double a,double b,const char* why) {require(std::abs(a-b)<1e-8,why);}
static Project fixture(int flag) {
    Project p;p.id="printed-project";p.name="Printed tempo";
    Song s;s.id="song";s.name="Song";s.duration=20;s.bpm=120;
    s.regionOwnershipInitialized=true;s.regionOwnershipVersion=3;
    s.timeSettings=ProjectTimeSettings{};s.timeSettings->timebase=ProjectTimebase::relative;
    s.parts={{"a","A",0,10},{"b","B",10,20}};
    TimelineMarker a{"tempo-a","TEMPO",0,0x999999};a.tempoBPM=180;a.tempoReferenceBPM=120;a.tempoTimebase="global";a.regionOwnerID="a";
    TimelineMarker b{"tempo-b","TEMPO",10,0x999999};b.tempoBPM=140;b.tempoReferenceBPM=140;b.tempoTimebase="global";b.regionOwnerID="b";s.markers=std::vector<TimelineMarker>{a,b};
    Track t;t.id="audio";t.name="Audio";
    AudioClip c;c.id="printed";c.name="Printed";c.audioFile=AudioFile{"Stems/printed.wav"};c.startTime=0;c.duration=10;c.sourceOffset=2;c.regionOwnerID="a";
    if(flag==0)c.renderedTempo=true;else if(flag==1)c.renderedTiming=true;else c.frozenMIDI=true;
    t.clips={c};auto next=c;next.id="next";next.regionOwnerID="b";next.startTime=10;t.clips.push_back(next);s.tracks={t};p.songs={s};return p;
}
int main() {try {
    for(int flag=0;flag<3;++flag)for(bool batch:{false,true}) {
        Engine engine;engine.loadProject(fixture(flag));const auto original=engine.project();
        const auto change=[&](double bpm) {auto marker=engine.currentSong()->markers->front();marker.tempoBPM=bpm;if(batch)engine.setMarkers({marker},{},true);else engine.setMarker(marker.id,marker.name,marker.position,marker.color,bpm,4,4,"global");};
        change(210);
        const auto& sped=engine.currentSong()->tracks.front().clips.front();
        near(sped.playbackRate,210./180.,"Printed audio did not react to a later tempo edit");
        near(sped.duration*sped.playbackRate,10,"Printed source span changed after tempo edit");
        near(sped.sourceOffset,2,"Printed source trim changed");
        require(sped.tempoBasePlaybackRate==1,"Printed item did not retain original rate for display");
        near(TempoEditMap::playbackRate(*engine.currentSong(),sped,sped.startTime+sped.duration*.5),210./180.,"Printed marker ratio was applied twice");
        near(engine.currentSong()->tracks.front().clips.back().playbackRate,1,"Next song printed audio changed rate");
        near(*engine.currentSong()->markers->back().tempoBPM,140,"Next song BPM changed");
        change(180);const auto& restored=engine.currentSong()->tracks.front().clips.front();
        near(restored.playbackRate,1,"Returning to printed BPM retained altered rate");near(restored.duration,10,"Returning to printed BPM lost duration");
        change(150);const auto& slow=engine.currentSong()->tracks.front().clips.front();near(slow.playbackRate,150./180.,"Printed slowdown uses wrong reference");
        engine.applyProjectEdit(original);near(engine.currentSong()->tracks.front().clips.front().playbackRate,1,"Undo did not restore printed audio rate");
    }
    std::cout<<"PRINTED_TEMPO_RERENDER_GLUE_FROZEN_REVERSAL_AND_OWNERSHIP_OK\n";
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}}
