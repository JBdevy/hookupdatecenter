#include "../../Core/MIDI/RealtimeMIDIQueue.hpp"
#include <cassert>
#include <cstdlib>
#include <new>
#include <thread>
#include <vector>
#include <iostream>
static thread_local bool watch=false;
static thread_local unsigned allocations=0;
void* operator new(std::size_t size) { if(watch)++allocations; if(auto*p=std::malloc(size?size:1))return p;throw std::bad_alloc(); }
void operator delete(void*p)noexcept{std::free(p);}
void* operator new[](std::size_t size){return ::operator new(size);}
void operator delete[](void*p)noexcept{::operator delete(p);}
int main() {
    jaras::RealtimeMIDIQueue<8> queue;
    std::uint8_t note[]{0x90,60,100};
    jaras::RealtimeMIDIQueue<8>::Event event;
    watch=true;
    for(unsigned cycle=0;cycle<10000;++cycle) {
        for(unsigned i=0;i<8;++i)assert(queue.push(note,3,double(i)));
        assert(!queue.push(note,3,0));
        const auto epoch=queue.epoch();
        for(unsigned i=0;i<8;++i){assert(queue.pop(event));assert(event.seconds==i);assert(event.data[1]==60);assert(event.generation<epoch);}
        assert(!queue.pop(event));
    }
    assert(allocations==0);watch=false;
    assert(queue.droppedCount()==10000);
    assert(!queue.push(note,4,0));assert(queue.unsupportedCount()==1);
    watch=true;
    const auto beforeRestart=queue.epoch();
    for(unsigned i=0;i<queue.capacity;++i)assert(queue.push(note,3,i));
    queue.invalidate();
    assert(queue.epoch()==beforeRestart+1);
    assert(queue.discardPending()==queue.capacity);
    assert(queue.discardPending()==0);
    // A full queue at restart must immediately have room for the first new note.
    assert(queue.push(note,3,123));
    assert(queue.pop(event));
    assert(event.generation==queue.epoch() && event.seconds==123);
    assert(!queue.pop(event));
    assert(allocations==0);watch=false;
    jaras::RealtimeMIDIQueue<1024> concurrent;
    constexpr int producers=4,events=20000;
    std::vector<std::thread> threads;
    for(int producer=0;producer<producers;++producer)threads.emplace_back([&,producer]{
        watch=true;
        for(int i=0;i<events;++i){std::uint8_t bytes[]{std::uint8_t(producer),std::uint8_t(i),std::uint8_t(i>>8)};while(!concurrent.push(bytes,3,i))std::this_thread::yield();}
        assert(allocations==0);
    });
    std::array<int,producers> next{};
    jaras::RealtimeMIDIQueue<1024>::Event received;
    watch=true;
    for(int count=0;count<producers*events;) {
        if(!concurrent.pop(received)){std::this_thread::yield();continue;}
        auto producer=received.data[0];assert(producer<producers);
        const int sequence=received.data[1]+(int(received.data[2])<<8);
        assert(sequence==next[producer]++);assert(received.seconds==sequence);++count;
    }
    assert(allocations==0);watch=false;
    for(auto &thread:threads)thread.join();
    std::cout<<"REALTIME_MIDI_FIXED_STORAGE_WRAP_OVERFLOW_RESTART_4_PRODUCERS_NO_ALLOCATIONS_OK\n";
}
