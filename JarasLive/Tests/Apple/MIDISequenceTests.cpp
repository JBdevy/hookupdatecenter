#include "../../Apple/Bridge/CatMIDISequence.hpp"
#include <cassert>
#include <iostream>
static unsigned attacks(const CatMIDISequence& sequence) {
    unsigned count=0;for(unsigned i=0;i<sequence.count;++i)if((sequence.events[i].status&0xf0)==0x90)++count;return count;
}
static unsigned releases(const CatMIDISequence& sequence) {
    unsigned count=0;for(unsigned i=0;i<sequence.count;++i)if((sequence.events[i].status&0xf0)==0x80)++count;return count;
}
static void timingEditRegressions(double rate) {
    const double block=128/rate;
    {
        auto sequence=std::make_unique<CatMIDISequence>();
        sequence->setNotes({{0,10,60,100,0,1,100}});
        sequence->configure(0,0,0,true,0,0);sequence->render(0,rate,128);
        unsigned attackCount=attacks(*sequence);assert(attackCount==1);
        // Realistic sustained-note synths restart their attack on each note-on.
        // A constant output amplitude would not expose this regression.
        for(unsigned edit=1;edit<=40;++edit) {
            const double clock=edit*block,position=1+edit*.02;
            // Some control publications can be superseded before the audio
            // thread renders; stable source identity must survive that too.
            sequence->setNotes({{0,10+edit*.1,60,100,0,1,100}},true);
            sequence->setNotes({{0,12+edit*.1,60,100,0,1,100}},true);
            sequence->configure(0,position,clock,true,0,0);sequence->render(clock,rate,128);
            attackCount+=attacks(*sequence);assert(sequence->count==0);
        }
        assert(attackCount==1);
        // A later real seek still retriggers even though the published plan
        // was a timing-only edit. Preservation is consumed by that generation.
        sequence->configure(0,4,41*block,true,0,0);sequence->render(41*block,rate,128);
        attackCount+=attacks(*sequence);assert(attackCount==2&&releases(*sequence)==1);
        // Ordinary note edits retain their original release/chase semantics.
        sequence->setNotes({{0,20,60,100,0,1,100}});
        sequence->render(42*block,rate,128);assert(attacks(*sequence)==1&&releases(*sequence)==1);
        sequence->stop();sequence->render(43*block,rate,128);assert(attacks(*sequence)==0&&releases(*sequence)==1);
        sequence->render(44*block,rate,128);assert(sequence->count==0);
    }
    {
        auto sequence=std::make_unique<CatMIDISequence>();
        sequence->setNotes({{0,5,60,100,0,1,100},{0,4,60,90,0,1,101}});
        sequence->configure(0,0,0,true,0,0);sequence->render(0,rate,128);assert(attacks(*sequence)==1);
        sequence->setNotes({{0,.01,60,100,0,1,100},{0,.008,60,90,0,1,101}},true);
        sequence->configure(0,.005,block,true,0,0);sequence->render(block,rate,128);assert(sequence->count==0);
        sequence->render(2*block,rate,128);
        assert(attacks(*sequence)==0&&releases(*sequence)==1); // only final overlapping note releases
        sequence->render(3*block,rate,128);assert(sequence->count==0);
    }
    {
        auto sequence=std::make_unique<CatMIDISequence>();
        sequence->setNotes({{0,10,60,100,0,1,100}});
        sequence->configure(0,0,0,true,0,0);sequence->render(0,rate,128);
        // Matching pitch/channel alone must not preserve a different note.
        sequence->setNotes({{0,11,60,100,0,1,101}},true);
        sequence->render(block,rate,128);assert(attacks(*sequence)==1&&releases(*sequence)==1);
        sequence->setNotes({},true);sequence->render(2*block,rate,128);
        assert(attacks(*sequence)==0&&releases(*sequence)==1);
        // Old clients without stable identities cannot claim the note survived.
        sequence->setNotes({{0,10,60,100,0}});sequence->render(3*block,rate,128);
        sequence->setNotes({{0,11,60,100,0}},true);sequence->render(4*block,rate,128);
        assert(attacks(*sequence)==1&&releases(*sequence)==1);
    }
    {
        auto sequence=std::make_unique<CatMIDISequence>();
        sequence->setNotes({{0,10,60,100,0,2,200}});
        sequence->configure(0,0,0,true,0,0);sequence->configure(1,1,0,true,0,0);
        sequence->render(0,rate,128);assert(attacks(*sequence)==1);
        sequence->setNotes({{0,12,60,100,0,2,200}},true);
        sequence->configure(0,2,block,true,0,0);sequence->configure(1,3,block,true,0,0);
        sequence->render(block,rate,128);assert(sequence->count==0);
        sequence->configure(0,0,0,false,0,0);sequence->render(2*block,rate,128);
        assert(sequence->count==0); // secondary head still owns the shared note
        sequence->stop();sequence->render(3*block,rate,128);assert(releases(*sequence)==1);
    }
    {
        auto sequence=std::make_unique<CatMIDISequence>();
        sequence->setNotes({{0,1,60,100,0,3,300}});
        sequence->configure(0,0,0,true,0,.01);sequence->render(0,rate,128);
        sequence->setNotes({{0,2,60,100,0,3,300}},true);
        sequence->render(block,rate,128);assert(sequence->count==0);
        sequence->render(2*block,rate,128);assert(sequence->count==0);
        sequence->render(3*block,rate,128);
        assert(attacks(*sequence)==1&&releases(*sequence)==1); // loop edge retriggers
        sequence->stop();sequence->render(4*block,rate,128);assert(releases(*sequence)==1);
        sequence->setNotes({{0,3,60,100,0,3,300}},true);
        sequence->configure(0,.5,5*block,true,0,0);sequence->render(5*block,rate,128);
        assert(attacks(*sequence)==1&&releases(*sequence)==0); // a new Play chases
    }
    std::cout<<"MIDI_TIMING_EDITS_PRESERVE_IDENTIFIED_HELD_NOTES_WITHOUT_REATTACK_AND_KEEP_SEEK_LOOP_STOP_DUAL_HEAD_OK "<<rate<<"\n";
}
int main() {
    {
        auto sequence=std::make_unique<CatMIDISequence>();
        sequence->setNotes({{0,10,60,100,0,1,1,0},{0,10,67,100,0,2,2,2}});
        sequence->configure(0,1,0,true,0,0);sequence->configure(1,1,0,true,0,0);
        sequence->render(0,48000,128);
        assert(attacks(*sequence)==1 && sequence->events[0].pitch==67);
        sequence->setNotes({{0,10,60,100,0,1,1,0},{0,10,67,100,0,2,2,1}});
        sequence->configure(0,1.5,1,true,0,0);sequence->configure(1,0,1,false,0,0);
        sequence->render(1,48000,128);
        for(unsigned i=0;i<sequence->count;++i)assert(sequence->events[i].pitch==67);
        assert(attacks(*sequence)==1);
    }

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
    timingEditRegressions(44100);timingEditRegressions(48000);
}
