#include "../../../Core/Audio/RealtimeCommandQueue.hpp"
#include "../../../Core/Audio/PreparedAudioEdits.hpp"
#include "../../../Core/Audio/SingleReaderSlots.hpp"
#include "../../../Core/Audio/RealtimeRunState.hpp"
#include "../../../Core/Audio/RealtimeLatestValue.hpp"
#include "../../../Core/Audio/RealtimePCMQueue.hpp"
#include "../../../Core/Audio/RealtimeBorrowedPointer.hpp"
#include "../../../WindowsNative/Source/AudioLatency.h"
#include <atomic>
#include <cmath>
#include <chrono>
#include <cstdlib>
#include <cstdint>
#include <iostream>
#include <new>
#include <stdexcept>
#include <thread>
#if defined(_WIN32)
#include <malloc.h>
#endif
namespace {
thread_local bool auditRealtime = false;
std::atomic<unsigned> realtimeAllocations { 0 }, realtimeDeallocations { 0 };
void allocation() noexcept { if (auditRealtime) ++realtimeAllocations; }
void deallocation() noexcept { if (auditRealtime) ++realtimeDeallocations; }
void* allocate(std::size_t size)
{
    allocation();
    if (auto* value = std::malloc(size ? size : 1)) return value;
    throw std::bad_alloc();
}
void* allocateAligned(std::size_t size, std::size_t alignment)
{
    allocation();
#if defined(_WIN32)
    if (auto* value = _aligned_malloc(size ? size : 1, alignment)) return value;
#else
    void* value = nullptr;
    if (posix_memalign(&value, alignment, size ? size : 1) == 0) return value;
#endif
    throw std::bad_alloc();
}
void freeAligned(void* value) noexcept
{
    deallocation();
#if defined(_WIN32)
    _aligned_free(value);
#else
    std::free(value);
#endif
}
}
void* operator new(std::size_t size) { return allocate(size); }
void* operator new[](std::size_t size) { return allocate(size); }
void operator delete(void* value) noexcept { deallocation(); std::free(value); }
void operator delete[](void* value) noexcept { deallocation(); std::free(value); }
void operator delete(void* value, std::size_t) noexcept { deallocation(); std::free(value); }
void operator delete[](void* value, std::size_t) noexcept { deallocation(); std::free(value); }
void* operator new(std::size_t size, std::align_val_t alignment) { return allocateAligned(size, static_cast<std::size_t>(alignment)); }
void* operator new[](std::size_t size, std::align_val_t alignment) { return allocateAligned(size, static_cast<std::size_t>(alignment)); }
void operator delete(void* value, std::align_val_t) noexcept { freeAligned(value); }
void operator delete[](void* value, std::align_val_t) noexcept { freeAligned(value); }
void operator delete(void* value, std::size_t, std::align_val_t) noexcept { freeAligned(value); }
void operator delete[](void* value, std::size_t, std::align_val_t) noexcept { freeAligned(value); }

namespace {
struct Command { std::uint64_t serial = 0, payload = 0; };
using Queue = catlive::audio::RealtimeCommandQueue<Command, 16, 3>;
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
void orderAndOverflow() {
    Queue queue;
    check(queue.retainedBlocks() == 4, "warm blocks are prepared up front");
    for (std::uint64_t i=0; i<10000; ++i) queue.push({i, ~i});
    std::uint64_t expected = 0;
    auditRealtime = true;
    const auto first = queue.consume(3, [&](const Command& c) {
        if(c.serial != expected || c.payload != ~expected) std::abort();
        ++expected;
    });
    auditRealtime = false;
    check(first == 3 && expected == 3, "consumer budget must be respected");
    while (expected < 10000) {
        auditRealtime = true;
        queue.consume(37, [&](const Command& c) {
            if(c.serial != expected || c.payload != ~expected) std::abort();
            ++expected;
        });
        auditRealtime = false;
        queue.collectRetired();
    }
    check(queue.retainedBlocks() <= 4, "overflow blocks must be reclaimed on control");
    check(queue.consume(0, [](const Command&) {}) == 0, "zero budget");
    check(queue.consume(100, [](const Command&) {}) == 0, "empty drain");
    // Reuse pooled blocks after their addresses have already been published.
    for (std::uint64_t cycle=0; cycle<1000; ++cycle) {
        for (std::uint64_t i=0; i<47; ++i) queue.push({i, cycle});
        std::uint64_t index=0;
        auditRealtime=true;
        const auto count=queue.consume(100, [&](const Command& c) {
            if(c.serial != index++ || c.payload != cycle) std::abort();
        });
        auditRealtime=false;
        check(count==47, "pool reuse lost commands");
    }
    queue.push({123,456});
    queue.resetAfterStop();
    check(queue.consume(10, [](const Command&) {})==0, "reset retained an obsolete graph command");
    queue.push({7,8});
    check(queue.consume(1, [](const Command& c) { if(c.serial!=7 || c.payload!=8) std::abort(); })==1, "restart");
}
void concurrentPublication() {
    Queue queue;
    constexpr std::uint64_t total=500000;
    std::atomic<bool> start{false}, finished{false};
    std::thread consumer([&] {
        while(!start.load(std::memory_order_acquire)) std::this_thread::yield();
        std::uint64_t expected=0;
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);
        while(expected<total) {
            auditRealtime=true;
            const auto count=queue.consume(31, [&](const Command& c) {
                if(c.serial!=expected || c.payload!=~expected) std::abort();
                ++expected;
            });
            auditRealtime=false;
            if(std::chrono::steady_clock::now()>deadline) std::abort();
            if(!count) std::this_thread::yield(); // test driver, outside callback audit
        }
        finished.store(true, std::memory_order_release);
    });
    start.store(true,std::memory_order_release);
    for(std::uint64_t i=0;i<total;++i) {
        queue.push({i,~i});
        if(i%257==0) std::this_thread::yield();
    }
    while(!finished.load(std::memory_order_acquire)) { queue.collectRetired(); std::this_thread::yield(); }
    consumer.join();
    queue.collectRetired();
    check(queue.retainedBlocks()<=4,"retirement retained excessive storage");
}
void preparedOwnership() {
    using Edits = catlive::audio::PreparedAudioEdits;
    Edits edits;
    catlive::audio::RealtimeCommandQueue<Edits::Ticket*,16,3> commands;
    auto current=std::make_unique<std::uint64_t>(0);
    constexpr std::uint64_t total=20000;
    std::atomic<bool> finished{false};
    std::thread consumer([&] {
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);
        std::uint64_t applied=0;
        while(applied<total) {
            auditRealtime=true;
            applied+=commands.consume(17, [](Edits::Ticket* const& ticket) noexcept { Edits::execute(ticket); });
            auditRealtime=false;
            if(std::chrono::steady_clock::now()>deadline) std::abort();
            std::this_thread::yield();
        }
        finished.store(true,std::memory_order_release);
    });
    for(std::uint64_t i=1;i<=total;++i) {
        auto next=std::make_unique<std::uint64_t>(i);
        auto* ticket=edits.prepare([&current,next=std::move(next),i]() mutable noexcept {
            if(*current!=i-1)std::abort();
            current.swap(next); // Old allocation stays inside control-owned ticket.
        });
        commands.push(ticket);
    }
    while(!finished.load(std::memory_order_acquire)) { edits.collectRetired(); std::this_thread::yield(); }
    consumer.join(); edits.collectRetired();
    check(*current==total && edits.retained()==0,"prepared edit ordering/retirement failed");
    bool executed=false;
    auto* cancelled=edits.prepare([&executed]() noexcept { executed=true; });
    edits.cancelUnpublished(cancelled);
    check(!executed && edits.retained()==0,"unpublished edit was not discarded");
    commands.push(edits.prepare([&executed]() noexcept { executed=true; }));
    commands.resetAfterStop(); edits.resetAfterStop();
    check(!executed && edits.retained()==0,"shutdown applied a cancelled edit");
}
void immutablePages() {
    struct Page { std::uint64_t serial; std::array<std::uint64_t,32> samples; };
    catlive::audio::SingleReaderSlots<Page,8> slots;
    auto makePage=[](std::uint64_t serial) {
        auto page=std::make_unique<Page>();page->serial=serial;page->samples.fill(~serial);return page;
    };
    slots.publish(0,makePage(1));
    {
        auto lease=slots.read();const auto* old=lease.get(0);
        slots.publish(0,makePage(2));
        check(old->serial==1 && slots.retiredCount()==1,"active lease lost its old page");
    }
    slots.collectRetired();check(slots.retiredCount()==0,"quiescent pages not retired");
    std::atomic<bool> finished{false};
    std::thread reader([&] {
        do {
            auditRealtime=true;
            {
                auto lease=slots.read();
                for(std::size_t i=0;i<8;++i)if(const auto* page=lease.get(i))
                    for(const auto sample:page->samples)if(sample!=~page->serial)std::abort();
            }
            auditRealtime=false;
        } while(!finished.load(std::memory_order_acquire));
    });
    for(std::uint64_t i=3;i<50000;++i)slots.publish(i%8,makePage(i));
    finished.store(true,std::memory_order_release);reader.join();
    slots.collectRetired();check(slots.retiredCount()==0,"page retirement after join");
}
void explicitRunLifecycle() {
    catlive::audio::RealtimeRunState state;
    volatile std::uint64_t prepared=0; // Force both unprotected payload reads for the race detector.
    std::atomic<bool> finished{false};
    std::thread callback([&] {
        while(!finished.load()) {
            auditRealtime=true;
            if(state.enter()) {
                const auto observed=prepared;
                if(observed!=prepared)std::abort();
                state.leave();
            }
            auditRealtime=false;
        }
    });
    for(std::uint64_t i=0;i<25000;++i) {
        state.stop();state.waitStopped();prepared=i;state.start();
    }
    state.stop();state.waitStopped();finished.store(true);callback.join();
    check(!state.running() && !state.enter(),"stopped callback admitted");
}
void latestControlSnapshots() {
    catlive::audio::RealtimeLatestValue<Command> latest;
    Command result;
    check(!latest.consume(result),"unpublished latest value");
    latest.publish({1,~std::uint64_t(1)});latest.publish({2,~std::uint64_t(2)});
    check(latest.consume(result) && result.serial==2 && result.payload==~result.serial,"latest value did not coalesce");
    check(!latest.consume(result),"latest value replayed");
    constexpr std::uint64_t count=250000;
    std::thread consumer([&] {
        std::uint64_t observed=2;
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);
        while(observed<count) {
            auditRealtime=true;
            if(latest.consume(result)) {
                if(result.serial<=observed || result.payload!=~result.serial)std::abort();
                observed=result.serial;
            }
            auditRealtime=false;
            if(std::chrono::steady_clock::now()>deadline)std::abort();
        }
    });
    for(std::uint64_t serial=3;serial<=count;++serial)latest.publish({serial,~serial});
    consumer.join();
}
void pcmCaptureQueue() {
    using catlive::audio::RealtimePCMQueue;
    RealtimePCMQueue small(2,8);
    std::array<float,16> signal{};
    for(std::size_t i=0;i<signal.size();++i)signal[i]=float(i+1);
    const float* input[]{signal.data(),nullptr};
    const float* planes[2]{};
    check(small.push(input,6),"initial PCM write");
    check(!small.push(input,3),"full PCM queue must reject complete block");
    check(small.peek(planes,4)==4 && planes[0][3]==4 && planes[1][3]==0,"PCM samples/null channel");
    small.consume(4);
    check(small.push(input,6),"wrapped PCM write");
    check(small.peek(planes,8)==4 && planes[0][0]==5 && planes[0][2]==1 && planes[0][3]==2,
          "wrapped first PCM span or partial overflow write");
    small.consume(4);
    check(small.peek(planes,8)==4 && planes[0][0]==3 && planes[0][3]==6,"wrapped second PCM span");
    small.consume(4);
    check(small.peek(planes,8)==0,"drained PCM queue is not empty");
    check(!small.push(input,9),"oversize PCM block accepted");
    check(small.push(nullptr,8) && small.peek(planes,8)>0,"silent PCM block");
    for(int ch=0;ch<2;++ch)for(std::size_t i=0;i<small.peek(planes,8);++i)
        check(planes[ch][i]==0,"silent PCM retained old samples");

    RealtimePCMQueue queue(3,1024);
    constexpr std::uint64_t total=1000000;
    std::thread consumer([&] {
        std::uint64_t observed=0;
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);
        while(observed<total) {
            const float* values[3]{};
            auditRealtime=true;
            const auto count=queue.peek(values,113);
            for(std::size_t i=0;i<count;++i) {
                if(values[0][i]!=float(observed+i) || values[1][i]!=-float(observed+i) || values[2][i]!=.25f)
                    std::abort();
            }
            queue.consume(count);
            auditRealtime=false;
            observed+=count;
            if(std::chrono::steady_clock::now()>deadline)std::abort();
        }
    });
    std::array<float,257> a{},b{},c{};c.fill(.25f);
    const float* sources[]{a.data(),b.data(),c.data()};
    for(std::uint64_t next=0;next<total;) {
        const auto count=std::min<std::uint64_t>(1+(next%257),total-next);
        for(std::size_t i=0;i<count;++i){a[i]=float(next+i);b[i]=-a[i];}
        auditRealtime=true;
        const bool accepted=queue.push(sources,std::size_t(count));
        auditRealtime=false;
        if(accepted)next+=count;
        else std::this_thread::yield(); // Test producer only; no retry inside push.
    }
    consumer.join();
}
void borrowedRecordingLifetime() {
    struct Capture {std::uint64_t frames=0;};
    catlive::audio::RealtimeBorrowedPointer<Capture> slot;
    std::atomic<bool> stop{false};
    std::thread reader([&] {
        while(!stop.load(std::memory_order_relaxed)) {
            auditRealtime=true;
            {
                auto lease=slot.read();
                if(auto* capture=lease.get())capture->frames+=64;
            }
            auditRealtime=false;
        }
    });
    std::uint64_t recorded=0;
    for(unsigned i=0;i<10000;++i) {
        auto capture=std::make_unique<Capture>();
        slot.publish(capture.get());
        if(i%16==0)std::this_thread::yield();
        slot.withdrawAndWait();
        // No callback may write after withdrawal acknowledges, even while new
        // blocks continue. Destruction here is always on the control thread.
        recorded+=capture->frames;
        check(capture->frames%64==0,"capture ended inside its block");
    }
    stop.store(true);reader.join();
    check(recorded>0,"concurrent recording lifetime test rendered no blocks");
}
void timelineTempoMaps() {
    using Map=catlive::audio::PiecewiseTimeMap;
    using Delay=catlive::native::TimelineDelay;
    Delay actual(257);actual.reset(2.);
    std::vector<Delay::Frame> expected(257);
    Delay::Frame fallback{2.,false};
    unsigned cursor=0,valid=0;
    for(unsigned n=0;n<24000;++n) {
        if(n%97==0) {
            Map edit;
            const double scale=(n/97)%2 ? .98 : 1.02;
            edit.append(1.,1.,scale);
            edit.append(4.,1.+3.*scale,1.);
            auto prepared=actual.prepareRemap(edit);
            auditRealtime=true;actual.adoptRemap(prepared);auditRealtime=false;
            fallback.position=edit.position(fallback.position);
            for(auto& f:expected)f.position=edit.position(f.position);
        }
        if(n%1013==0) {
            fallback={double(n%5),false};valid=0;
            auditRealtime=true;actual.reset(fallback.position);auditRealtime=false;
        }
        Delay::Frame input{double(n%911)/100.-.5,n%11!=0};
        const auto reference=valid>=expected.size()?expected[cursor%expected.size()]:fallback;
        expected[cursor%expected.size()]=input;++cursor;++valid;
        auditRealtime=true;const auto result=actual.process(input);const auto previous=actual.previous(17);auditRealtime=false;
        check(std::abs(result.position-reference.position)<1e-9 && result.moving==reference.moving,
            "Lazy tempo mapping changed delayed audio clock or loop wrap");
        const auto old=valid>=17?expected[(cursor-17)%expected.size()]:fallback;
        check(std::abs(previous.position-old.position)<1e-9&&previous.moving==old.moving,
            "Lazy tempo mapping changed previous clock lookup");
    }
    Map first;first.append(0.,0.,.5);first.append(2.,1.,2.);first.append(5.,7.,1.);
    Map second;second.append(0.,0.,2.);second.append(4.,8.,.25);second.append(8.,9.,1.);
    const auto composed=first.followedBy(second);
    for(int n=-100;n<10000;++n) {
        const double at=n*.001;
        check(std::abs(composed.position(at)-second.position(first.position(at)))<1e-11,"Time map composition changed a breakpoint");
        check(std::abs(composed.inverse(composed.position(at))-at)<1e-11,"Time map inverse lost a position");
    }
    auto global=first.followedBy(Map(1.3));
    check(std::abs(global.position(-2.)+2.6)<1e-12,"Global tempo scale lost negative preroll");
}
void cancelledPreparedEdits() {
    using Ledger=catlive::audio::PreparedAudioEdits;
    Ledger ledger;
    Ledger::Ticket* abandoned=nullptr;
    {
        int expired=0;
        abandoned=ledger.prepare([&expired]() noexcept { expired=1; });
        check(Ledger::cancelPending(abandoned),"unstarted edit did not cancel");
        ledger.collectRetired();
        check(ledger.retained()==1 && !Ledger::isComplete(abandoned),"cancelled queue entry lost ownership before consumption");
    }
    auditRealtime=true;Ledger::execute(abandoned);auditRealtime=false;
    check(Ledger::isComplete(abandoned),"cancelled edit did not acknowledge consumption");
    ledger.collectRetired();
    catlive::audio::RealtimeCommandQueue<Ledger::Ticket*,16,3> queue;
    constexpr unsigned count=20000;
    std::atomic<unsigned> applied{0},consumed{0};
    std::thread audio([&] {
        while(consumed.load()<count) {
            auditRealtime=true;
            queue.consume(32,[&](Ledger::Ticket* ticket){Ledger::execute(ticket);++consumed;});
            auditRealtime=false;
        }
    });
    unsigned cancelled=0;
    for(unsigned i=0;i<count;++i) {
        auto* ticket=ledger.prepare([&applied]() noexcept {++applied;});
        queue.push(ticket);
        if(Ledger::cancelPending(ticket))++cancelled;
    }
    audio.join();ledger.collectRetired();
    check(applied.load()+cancelled==count && ledger.retained()==0,"cancel/execute race applied an edit twice or leaked it");
}
}
int main() {
    orderAndOverflow(); concurrentPublication(); preparedOwnership(); immutablePages(); explicitRunLifecycle(); latestControlSnapshots(); pcmCaptureQueue(); borrowedRecordingLifetime(); cancelledPreparedEdits();timelineTempoMaps();
    check(realtimeAllocations.load()==0 && realtimeDeallocations.load()==0,
          "consumer allocated or released heap ownership");
    std::cout << "REALTIME_COMMANDS_PREPARED_EDITS_PAGE_LIFETIMES_RUN_STATE_ZERO_CALLBACK_HEAP_OK\n";
}
