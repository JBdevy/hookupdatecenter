#include "../../Apple/Bridge/CatMIDISequence.hpp"
#include <cassert>
#include <iostream>
int main() {
    auto s=std::make_unique<CatMIDISequence>();
    s->setNotes({{.01,.02,60,100,0},{.025,.04,64,90,0}});
    s->configure(0,0,0,true,0,0);s->render(0,48000,1024);
    assert(s->count==2 && s->events[0].offset==480 && s->events[1].offset==960);
    assert(s->events[0].status==0x90 && s->events[1].status==0x80);
    s->configure(0,.03,1,true,0,0);s->render(1,48000,128);
    assert(s->count==1 && s->events[0].pitch==64 && s->events[0].offset==0);
    s->stop();s->render(1.01,48000,128);assert(s->count==1&&s->events[0].status==0x80);
    s->setNotes({{0,.1,60,100,0}});s->configure(0,0,2,true,0,.05);s->render(2,48000,4800);
    assert(s->count==3&&s->events[0].offset==0&&s->events[1].offset==2400&&s->events[2].offset==2400);
    assert(s->events[1].status==0x80&&s->events[2].status==0x90);
    s->stop();s->render(3,48000,1);
    s->setNotes({{0,.015,60,100,0}});s->configure(0,0,4,true,0,0);s->configure(1,0,4.01,true,0,0);s->render(4,48000,1920);
    assert(s->count==2&&s->events[0].offset==0&&s->events[1].offset==1200); // shared pitch stops after both heads
    s->setNotes({{0,1,67,100,0}});s->configure(0,.1,5,true,0,0);s->configure(1,0,0,false,0,0);s->render(5,48000,128);
    assert(s->count==1&&s->events[0].pitch==67);
    s->setNotes({});s->render(5+128./48000,48000,128);assert(s->count==1&&s->events[0].status==0x80);
    s->setNotes({{0,.5,60,100,0}});s->configure(0,0,6.1,true,0,0);s->render(6,48000,128);assert(s->count==0);
    s->render(6.1,48000,128);assert(s->count==1&&s->events[0].offset==0);
    std::cout<<"MIDI_AUDIO_CLOCK_SAMPLE_OFFSETS_SEEK_CHASE_STOP_LOOP_DUAL_HEAD_AND_REPLACEMENT_OK\n";
}
