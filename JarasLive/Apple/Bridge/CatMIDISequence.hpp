#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <vector>

struct CatMIDINote {
    double start, end; uint8_t pitch, velocity, channel;
    // Stable source identity survives tempo remapping. Zero means unidentified,
    // and cannot authorize preserving a note across a changed sequence.
    uint64_t identityHigh=0,identityLow=0;
};
struct CatMIDIEvent { unsigned offset; uint8_t status, pitch, velocity; };

// Published on the control thread; scanned on the audio thread. No locks,
// file access, allocations, timers, or main-thread callbacks during rendering.
class CatMIDISequence {
    struct Event { double time; unsigned note; bool on; };
    struct Plan { std::vector<CatMIDINote> notes; std::vector<Event> events; uint64_t generation=0; bool preserveHeld=false; };
    struct Clock {
        std::atomic<uint64_t> generation{0};
        std::atomic<double> position{0},time{0},loopStart{0},loopEnd{0};
        std::atomic<bool> running{false};
    };
    struct Held {
        uint32_t count=0,unidentified=0;
        uint64_t identityHigh=0,identityLow=0;
        void include(const CatMIDINote& note) {
            ++count; if(!note.identityHigh&&!note.identityLow)++unidentified;
            identityHigh^=note.identityHigh;identityLow^=note.identityLow;
        }
        void exclude(const CatMIDINote& note) {
            if(!count)return;
            --count;if(!note.identityHigh&&!note.identityLow&&unidentified)--unidentified;
            identityHigh^=note.identityHigh;identityLow^=note.identityLow;
            if(!count)*this={};
        }
        bool sameIdentifiedNotes(const Held& other)const {
            return !unidentified&&!other.unidentified&&count==other.count&&
                identityHigh==other.identityHigh&&identityLow==other.identityLow;
        }
    };
    struct State { std::array<Held,2048> held{}; double end=-1; uint64_t plan=0; };
    struct Chase { std::array<Held,2048> held{}; std::array<uint8_t,2048> velocities{}; };
    std::array<Clock,2> clocks;
    std::array<State,2> states;
    std::array<Chase,2> chases;
    std::atomic<Plan*> published{nullptr};
    std::atomic<unsigned> readers{0};
    std::unique_ptr<Plan> current;
    std::vector<std::unique_ptr<Plan>> retired;
    uint64_t generation=0;
    enum class TransitionKind { reset,reconcile,note };
    // Keep indices into the immutable plan instead of copying note identities
    // into the large, preallocated render transition buffer.
    struct Transition { unsigned offset,head,note; TransitionKind kind; bool on; };
    std::array<Transition,32768> transitions{};
    unsigned transitionCount=0;
    bool overflow=false;
    void enqueue(Transition value) {
        if(transitionCount<transitions.size()) transitions[transitionCount++]=value;else overflow=true;
    }
    void emit(unsigned offset,int key,bool on,uint8_t velocity) {
        if(count<events.size()) events[count++]={offset,uint8_t((on?0x90:0x80)|(key/128)),uint8_t(key%128),uint8_t(on?velocity:0)};
    }
    void release(unsigned head,unsigned offset) {
        enqueue({offset,head,0,TransitionKind::reset,false});states[head].end=-1;
    }
    void apply(unsigned head,unsigned note,bool on,unsigned offset) { enqueue({offset,head,note,TransitionKind::note,on}); }
    void releaseNow(unsigned head,unsigned offset) {
        for(int key=0;key<2048;++key) if(states[head].held[key].count) {
            states[head].held[key]={};
            if(!states[1-head].held[key].count) emit(offset,key,false,0);
        }
    }
    void reconcileNow(unsigned head,unsigned offset) {
        for(int key=0;key<2048;++key) {
            auto& held=states[head].held[key];const auto& wanted=chases[head].held[key];
            if(held.sameIdentifiedNotes(wanted))continue;
            const bool shared=states[1-head].held[key].count!=0;
            if(held.count&&!shared)emit(offset,key,false,0);
            held=wanted;
            if(held.count&&!shared)emit(offset,key,true,chases[head].velocities[key]);
        }
    }
public:
    std::array<CatMIDIEvent,16384> events{};
    unsigned count=0;
    void setNotes(std::vector<CatMIDINote> notes,bool preserveHeld=false) {
        auto next=std::make_unique<Plan>(); next->generation=++generation;next->preserveHeld=preserveHeld;
        for(const auto& n:notes) if(std::isfinite(n.start)&&std::isfinite(n.end)&&n.start>=0&&n.end>n.start&&n.channel<16&&n.pitch<128&&n.velocity>0&&n.velocity<128) next->notes.push_back(n);
        next->events.reserve(next->notes.size()*2);
        for(unsigned index=0;index<next->notes.size();++index) {
            const auto& n=next->notes[index];
            next->events.push_back({n.start,index,true});next->events.push_back({n.end,index,false});
        }
        std::sort(next->events.begin(),next->events.end(),[](const auto&a,const auto&b){return a.time==b.time ? a.on<b.on : a.time<b.time;});
        auto old=std::move(current);current=std::move(next);published.store(current.get(),std::memory_order_seq_cst);
        if(old)retired.push_back(std::move(old));if(readers.load(std::memory_order_seq_cst)==0)retired.clear();
    }
    void configure(unsigned head,double position,double clock,bool running,double loopStart,double loopEnd) {
        if(head>=2)return;auto& c=clocks[head];c.generation.fetch_add(1);
        c.position=position;c.time=clock;c.loopStart=loopStart;c.loopEnd=loopEnd;c.running=running;
        c.generation.fetch_add(1,std::memory_order_release);
    }
    void stop() {for(unsigned h=0;h<2;++h) configure(h,0,0,false,0,0);}
    void render(double clock,double rate,unsigned frames) {
        count=0;transitionCount=0;overflow=false;if(rate<=0||!std::isfinite(clock))return;
        readers.fetch_add(1,std::memory_order_seq_cst);auto* plan=published.load(std::memory_order_seq_cst);
        for(unsigned head=0;head<2;++head) {
            auto& c=clocks[head];auto serial=c.generation.load(std::memory_order_acquire);if(serial&1)continue;
            const double origin=c.position.load(),anchor=c.time.load(),lo=c.loopStart.load(),hi=c.loopEnd.load();const bool running=c.running.load();
            if(serial!=c.generation.load(std::memory_order_acquire))continue;
            if(!running||!plan) {release(head,0);continue;}
            double position=origin+clock-anchor;
            unsigned offset=0;
            if(clock<anchor) {
                release(head,0);
                const double delay=(anchor-clock)*rate;
                if(delay>=frames)continue;
                offset=unsigned(std::ceil(delay));position=origin;
            }
            const bool loop=std::isfinite(lo)&&std::isfinite(hi)&&hi-lo>=.001;
            while(offset<frames) {
                const bool wrapped=loop&&position>=hi;
                if(wrapped) position=lo+std::fmod(position-lo,hi-lo);
                auto& state=states[head];
                if(state.plan!=plan->generation || state.end<0 || std::abs(position-state.end)>2/rate) {
                    // Only an explicit timing edit can preserve a held note.
                    // Ordinary edits, seeks, stopped heads and loop boundaries
                    // continue to release/chase and therefore retrigger.
                    const bool preserve=state.plan!=plan->generation&&plan->preserveHeld&&state.end>=0&&!wrapped&&
                        !(loop&&state.end>=hi-2/rate&&position<state.end-2/rate);
                    if(preserve)chases[head]={};else release(head,offset);
                    state.plan=plan->generation;
                    for(unsigned index=0;index<plan->notes.size();++index) {
                        const auto& note=plan->notes[index];
                        if(note.start<position-1e-10&&note.end>position) {
                            if(preserve) {
                                const int key=int(note.channel)*128+note.pitch;
                                chases[head].held[key].include(note);chases[head].velocities[key]=note.velocity;
                            } else apply(head,index,true,offset);
                        }
                    }
                    if(preserve)enqueue({offset,head,0,TransitionKind::reconcile,false});
                }
                double end=position+double(frames-offset)/rate;
                unsigned countFrames=frames-offset;
                if(loop&&position<hi&&end>=hi) {countFrames=std::max(1u,unsigned(std::ceil((hi-position)*rate)));countFrames=std::min(countFrames,frames-offset);end=hi;}
                auto first=std::lower_bound(plan->events.begin(),plan->events.end(),position-1e-10,[](const Event&e,double t){return e.time<t;});
                for(auto it=first;it!=plan->events.end()&&it->time<end-1e-10;++it) {
                    const unsigned frame=std::min(countFrames-1,unsigned(std::max(0.0,std::round((it->time-position)*rate))));
                    apply(head,it->note,it->on,offset+frame);
                }
                offset+=countFrames;state.end=end;position=end;
                if(loop&&end>=hi) {if(offset<frames)release(head,offset);position=lo;}
            }
        }
        std::sort(transitions.begin(),transitions.begin()+transitionCount,[](const Transition&a,const Transition&b){
            if(a.offset!=b.offset)return a.offset<b.offset;
            if(a.kind!=b.kind)return a.kind<b.kind;
            return a.on<b.on;
        });
        if(overflow) {releaseNow(0,0);releaseNow(1,0);states[0].end=states[1].end=-1;}
        else for(unsigned i=0;i<transitionCount;++i) {
            const auto& t=transitions[i];
            if(t.kind==TransitionKind::reset) {releaseNow(t.head,t.offset);continue;}
            if(t.kind==TransitionKind::reconcile) {reconcileNow(t.head,t.offset);continue;}
            const auto& note=plan->notes[t.note];
            const int key=int(note.channel)*128+note.pitch;auto& held=states[t.head].held[key];
            if(t.on) {
                const bool start=held.count==0&&!states[1-t.head].held[key].count;
                held.include(note);if(start)emit(t.offset,key,true,note.velocity);
            } else if(held.count) {
                held.exclude(note);if(!held.count&&!states[1-t.head].held[key].count)emit(t.offset,key,false,0);
            }
        }
        readers.fetch_sub(1,std::memory_order_seq_cst);
        std::sort(events.begin(),events.begin()+count,[](const CatMIDIEvent&a,const CatMIDIEvent&b){return a.offset==b.offset ? (a.status&0xf0)<(b.status&0xf0) : a.offset<b.offset;});
    }
};
