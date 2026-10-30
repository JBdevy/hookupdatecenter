#include "../../Core/MIDI/BoundedMIDIBuilder.hpp"
#include <array>
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <new>

#if CATLIVE_TEST_JUCE_MIDI
#include "../../Windows/Source/BoundedMIDIBuffer.h"
#endif

static thread_local bool watch = false;
static thread_local unsigned allocations = 0;
void* operator new(std::size_t bytes) {
    if (watch) ++allocations;
    if (auto* memory = std::malloc(bytes ? bytes : 1)) return memory;
    throw std::bad_alloc();
}
void* operator new[](std::size_t bytes) { return ::operator new(bytes); }
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete[](void* memory) noexcept { std::free(memory); }
void operator delete(void* memory, std::size_t) noexcept { std::free(memory); }
void operator delete[](void* memory, std::size_t) noexcept { std::free(memory); }

struct Sink {
    struct Event { std::array<std::uint8_t,3> bytes{}; int offset = 0; };
    std::array<Event,64> events{};
    std::size_t size = 0;
    void clear() noexcept { size = 0; }
    void add(const std::uint8_t* bytes, std::size_t length, int offset) noexcept {
        assert(size < events.size() && length <= 3);
        auto& event = events[size++];
        std::copy_n(bytes, length, event.bytes.begin()); event.offset = offset;
    }
};
static void verifyPanic(const Sink& sink) {
    assert(sink.size == 48);
    std::array<unsigned,16> seen{};
    for (std::size_t i=0;i<sink.size;++i) {
        const auto& event=sink.events[i];
        assert((event.bytes[0]&0xf0)==0xb0 && event.bytes[2]==0 && event.offset==0);
        const unsigned mask=event.bytes[1]==64?1:event.bytes[1]==120?2:event.bytes[1]==123?4:0;
        assert(mask); seen[event.bytes[0]&15] |= mask;
    }
    for (auto channel:seen) assert(channel==7);
}
int main() {
    using Budget=jaras::BoundedMIDIBuilder<64,128>;
    Budget budget; Sink sink;
    const std::uint8_t on[]{0x90,60,100}, off[]{0x80,60,0};
    watch=true;
    for (unsigned cycle=0;cycle<1000;++cycle) {
        sink.clear(); budget.beginBlock();
        for (unsigned i=0;i<64;++i) assert(budget.append(sink,on,3,int(i)));
        assert(!budget.append(sink,off,3,64)); verifyPanic(sink);
        assert(!budget.append(sink,on,3,65));
        assert(budget.overflows()==cycle+1 && sink.size==48);
        sink.clear(); budget.beginBlock();
        assert(budget.append(sink,on,3,2) && budget.append(sink,off,3,9));
        assert(sink.size==2 && sink.events[1].bytes[0]==0x80 && sink.events[1].offset==9);
    }
    sink.clear(); budget.beginBlock();
    for (unsigned i=0;i<128;++i) assert(budget.inspect(sink));
    assert(!budget.inspect(sink)); verifyPanic(sink);
    assert(allocations==0); watch=false;

    struct Note { double start,end; };
    std::vector<Note> notes;
    for (unsigned i=0;i<100000;++i) notes.push_back({double(i)*2,double(i)*2+1});
    jaras::MIDINoteChaseIndex index; index.prepare(notes);
    watch=true;
    unsigned visits=0, found=0;
    assert(index.visit(notes,199998.5,[&]{++visits;return true;},[&](const auto& note){
        assert(note.start==199998);++found;return true;
    }));
    assert(found==1 && visits<100);
    assert(allocations==0);watch=false;

    for (unsigned i=0;i<notes.size();++i) notes[i]={i*.01,i*.01+(i%27)*.03};
    index.prepare(notes);
    watch=true;
    for (unsigned query=0;query<64;++query) {
        const double at=query*13.791;unsigned actual=0,expected=0;
        for (const auto& note:notes) if(note.start<at-1e-9&&note.end>at+1e-9)++expected;
        assert(index.visit(notes,at,[]{return true;},[&](const auto& note){
            assert(note.start<at-1e-9&&note.end>at+1e-9);++actual;return true;
        }));
        assert(actual==expected);
    }
    assert(allocations==0);watch=false;
    notes.assign(100000,{0,100});index.prepare(notes);
    sink.clear();budget.beginBlock();
    watch=true;
    assert(!index.visit(notes,1,[&]{return budget.inspect(sink);},[](const auto&){return true;}));
    verifyPanic(sink);assert(allocations==0);watch=false;

#if CATLIVE_TEST_JUCE_MIDI
    catlive::BoundedMIDIBuffer deferred[2]{catlive::BoundedMIDIBuffer(false),catlive::BoundedMIDIBuffer(false)};
    for(auto& buffer:deferred)buffer.prepare();
    catlive::BoundedMIDIBuffer first,second;
    const auto* storage=first.buffer().data.begin();
    watch=true;
    for(std::size_t i=0;i<first.maximumEvents;++i)
        assert(first.addEvent(juce::MidiMessage::noteOn(1,int(i%128),juce::uint8(100)),0));
    assert(!first.addEvent(juce::MidiMessage::noteOff(1,60),1));
    assert(first.overflowed()&&first.getNumEvents()==48&&first.buffer().data.begin()==storage);
    first.clear();
    assert(first.addEvent(juce::MidiMessage::noteOn(1,60,juce::uint8(100)),2));
    assert(second.addEvent(juce::MidiMessage::noteOff(1,60),9));
    first.addEvents(second,0,16,0);
    assert(first.getNumEvents()==2&&first.buffer().data.begin()==storage);
    second.panic();first.addEvents(second,0,16,0);
    assert(first.overflowed()&&first.getNumEvents()==48&&first.buffer().data.begin()==storage);
    assert(allocations==0);watch=false;
#endif
    std::cout << "BOUNDED_MIDI_OVERFLOW_PANIC_RECOVERY_CHASE_INDEX_NO_ALLOCATIONS_OK\n";
}
