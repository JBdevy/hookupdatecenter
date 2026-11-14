#include "../../Core/Transport/Engine.hpp"
#include "../../Core/Songs/ItemDuration.hpp"
#include <iostream>
using namespace jaras;
static void near(double actual,double expected,const char* message) {
    if(std::abs(actual-expected)>1e-8)throw std::runtime_error(std::string(message)+": "+std::to_string(actual)+" vs "+std::to_string(expected));
}
int main(){try {
    Project project;project.id="project";project.name="Retention";
    Song song;song.id="song";song.duration=20;song.timeSettings=ProjectTimeSettings{};song.timeSettings->timebase=ProjectTimebase::relative;
    Track track;track.id="track";track.name="Audio";
    AudioClip clip;clip.id="clip";clip.duration=10;clip.playbackRate=1.2;clip.audioFile=AudioFile{"tone.wav",{}};
    track.clips={clip};song.tracks={track};
    TimelineMarker a{"first","Tempo",0,0},b{"second","Tempo",5,0};
    a.tempoBPM=150;a.tempoReferenceBPM=120;a.tempoTimebase="global";
    b.tempoBPM=90;b.tempoReferenceBPM=90;b.tempoTimebase="global";
    song.markers=std::vector<TimelineMarker>{a,b};project.songs={song};
    Engine engine;engine.loadProject(project);
    const auto rate=[&](double at){const auto& s=*engine.currentSong();return TempoEditMap::playbackRate(s,s.tracks[0].clips[0],at);};
    near(rate(1),1.5,"Initial tempo factor");near(rate(9),1.2,"Second tempo factor");
    auto settings=*song.timeSettings;settings.timebase=ProjectTimebase::free;
    engine.setProjectTiming(120,4,4,settings);
    near(rate(1),1.5,"Disabling timebase undid rate");near(rate(9),1.2,"Disabling changed another tempo section");
    near(engine.currentSong()->tracks[0].clips[0].duration,10,"Disabling changed item duration");
    engine.setMarker("first","Tempo",0,0,180,4,4,"global");
    near(rate(1),1.5,"BPM changed frozen audio");near(engine.currentSong()->tracks[0].clips[0].duration,10,"Free BPM moved item end");
    settings.timebase=ProjectTimebase::relative;engine.setProjectTiming(120,4,4,settings);
    near(rate(1),1.5,"Re-enabling applied frozen BPM again");
    engine.setMarker("first","Tempo",0,0,198,4,4,"global");near(rate(1),1.65,"Future BPM lost retained ratio");
    auto next=engine.project();auto& s=next.songs[0];auto original=s.tracks[0].clips[0];
    auto reset=resettingItemRate(s,original);s.tracks[0].clips[0]=reset;
    auto untouched=original;untouched.id="other";s.tracks[0].clips.push_back(untouched);
    engine.applyProjectEdit(next);
    near(rate(.1),1,"Reset left the first tempo factor active");near(rate(reset.duration-.01),1,"Reset left the second tempo factor active");
    near(engine.currentSong()->tracks[0].clips[0].duration,original.duration,"Reset changed geometry");
    engine.setMarker("first","Tempo",0,0,217.8,4,4,"global");near(rate(.1),1.1,"Reset disabled future tempo following");
    const auto& current=*engine.currentSong();near(TempoEditMap::playbackRate(current,current.tracks[0].clips[1],.1),1.815,"Reset altered another item");
    engine.setMarker("inserted","Tempo",1,0,217.8,4,4,"global");near(rate(1.1),1.1,"New marker lost the item's rate reference");
    // A persisted snapshot contains both applied factors and item references.
    Engine restored;restored.loadProject(engine.project());
    const auto& saved=*restored.currentSong();near(TempoEditMap::playbackRate(saved,saved.tracks[0].clips[0],1.1),1.1,"Restoring lost rate references");
    std::cout<<"TIMEBASE_FREEZE_RESUME_ITEM_RESET_FUTURE_BPM_AND_INSERTED_MARKER_OK\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
