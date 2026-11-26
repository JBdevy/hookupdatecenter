#include "../../Core/Transport/PluginTransportClock.hpp"
#include "../../Core/Transport/SongPluginTempo.hpp"
#include <cassert>
#include <iostream>
using namespace jaras;
static void near(double actual, double expected) { assert(std::abs(actual - expected) < 1e-8); }
int main() {
    PluginTempoMap map({{0,120,4,4},{10,90,7,8},{20,60,3,4}});
    auto t = map.at(12,true);
    near(t.tempo,90); near(t.quarterNotes,23); near(t.barStartQuarterNotes,20);
    assert(t.numerator == 7 && t.denominator == 8 && t.playing);
    near(map.at(15,true).barStartQuarterNotes,27);
    near(map.at(22,false).quarterNotes,37);
    // Last marker at a shared position wins without counting the interval twice.
    PluginTempoMap duplicate({{0,80,4,4},{0,120,4,4},{10,150,4,4},{10,90,7,8}});
    near(duplicate.at(12,true).quarterNotes,23);
    PluginTransportClock clock;
    clock.publish(9.99,100,true);
    t=clock.render(100.02,48000,480,&map);
    near(t.seconds,10.01);near(t.tempo,90);near(t.quarterNotes,20.015);
    clock.publish(22,101,false);
    near(clock.render(102,48000,480,&map).seconds,22);
    near(clock.render(103,48000,480,&map).seconds,22);
    clock.publish(10,110,true,10,12);
    t=clock.render(109,48000,480,&map);near(t.seconds,10);assert(!t.playing);
    near(clock.render(113,48000,480,&map).seconds,11);
    clock.publish(12,NAN,true);
    near(clock.render(0,48000,480,&map).seconds,12);
    near(clock.render(0,48000,480,&map).seconds,12.01);
    clock.publish(2,NAN,false);
    near(clock.render(0,48000,480,&map).seconds,2);
    near(clock.render(0,48000,480,&map).seconds,2);
    Project project;project.id="none-project";project.name="Input None";
    Song song;song.id="song";song.name="Song";song.duration=60;song.bpm=95;
    Track track;track.id="instrument";track.name="Instrument";track.inputPatch=OutputPatch{-1,2};
    song.tracks.push_back(track);project.songs.push_back(song);validate(project);
    near(pluginTempoMap(song).at(30,false).tempo,95);
    auto& tracks=project.songs[0].tracks;
    tracks.push_back(track);tracks[1].id="partner";
    tracks[0].stereoLinkPartner="partner";tracks[0].stereoLinkLeft=true;
    tracks[1].stereoLinkPartner="instrument";tracks[1].stereoLinkLeft=false;
    validate(project);
    tracks[1].inputPatch=OutputPatch{2,1};
    bool rejected=false;try{validate(project);}catch(...){rejected=true;}assert(rejected);
    std::cout<<"PLUGIN_TEMPO_MAP_CLOCK_SEEK_STOP_LOOP_AND_INPUT_NONE_OK\n";
}
