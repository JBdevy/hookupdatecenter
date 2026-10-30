#include "../CallbackHub.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <new>
#include <stdexcept>
#include <string>
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
using namespace catlive::native::audio;
void check(bool condition, const char* message)
{
    if (!condition) throw std::runtime_error(message);
}
template<class F> void rejects(F&& operation, const char* message)
{
    bool rejected = false;
    try { operation(); } catch (const std::exception&) { rejected = true; }
    check(rejected, message);
}
template<class F> void waitFor(F&& ready)
{
    auto limit = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!ready()) {
        if (std::chrono::steady_clock::now() >= limit)
            throw std::runtime_error("Timed out waiting for test callback");
        std::this_thread::yield();
    }
}
struct Block {
    std::array<float, 64> a {}, b {};
    std::array<float*, 2> outputs { a.data(), b.data() };
    AudioBlock block;
    explicit Block(std::uint32_t frames = 32)
    {
        block.outputs = outputs.data(); block.outputChannels = 2;
        block.frames = frames; block.sampleRate = 48000;
    }
};
CallbackHub::Configuration stereo()
{
    return { 48000, 64, 0, 2, {}, { 0, 1 } };
}
struct Constant {
    float value = 0;
    unsigned calls = 0;
    static void render(void* context, const AudioBlock& block) noexcept
    {
        auto& self = *static_cast<Constant*>(context);
        ++self.calls;
        for (std::uint32_t channel = 0; channel < block.outputChannels; ++channel)
            std::fill_n(block.outputs[channel], block.frames, self.value);
    }
};
void auditedRender(CallbackHub& hub, const AudioBlock& block)
{
    auditRealtime = true;
    CallbackHub::process(&hub, block);
    auditRealtime = false;
}

void mappingAndMixing()
{
    CallbackHub hub({ 48000, 64, 6, 6, { 5, 1 }, { 4, 0 } });
    struct Mapper {
        bool valid = true;
        static void render(void* context, const AudioBlock& block) noexcept
        {
            auto& self = *static_cast<Mapper*>(context);
            self.valid = self.valid && block.inputChannels == 6 && block.outputChannels == 6
                && block.framePosition == 1234 && block.qpcTime100ns == 999
                && block.deviceTimeNanoseconds == 777 && block.flags == (timestampValid | priming);
            for (std::uint32_t frame = 0; frame < block.frames; ++frame) {
                self.valid = self.valid && block.inputs[0][frame] == 0 && block.inputs[2][frame] == 0
                    && block.inputs[3][frame] == 0 && block.inputs[4][frame] == 0;
                block.outputs[4][frame] = block.inputs[5][frame] * 2;
                block.outputs[0][frame] = block.inputs[1][frame] * 3;
                block.outputs[3][frame] = 999; // Unmapped output stays private.
            }
        }
    } mapper;
    Constant one { 1 }, two { 2 };
    std::array clients { CallbackHub::Client { 1, Mapper::render, &mapper, {} },
        CallbackHub::Client { 2, Constant::render, &one, {} },
        CallbackHub::Client { 3, Constant::render, &two, {} } };
    hub.publish(clients);
    Block block(32);
    block.a.fill(4); block.b.fill(5);
    // Input and output deliberately alias. All clients must see original input.
    std::array<const float*, 2> inputs { block.a.data(), block.b.data() };
    block.block.inputs = inputs.data(); block.block.inputChannels = 2;
    block.block.framePosition = 1234; block.block.qpcTime100ns = 999;
    block.block.deviceTimeNanoseconds = 777; block.block.flags = timestampValid | priming;
    auditedRender(hub, block.block);
    check(mapper.valid, "Physical input expansion or timestamp forwarding changed");
    for (unsigned i = 0; i < 32; ++i)
        check(block.a[i] == 11 && block.b[i] == 18, "Clients did not mix independently in mapped physical order");
    check(block.a[32] == 4 && block.b[32] == 5, "Mixer wrote beyond callback frame count");
    check(hub.statistics().clientCalls == 3, "Client diagnostics count wrong");

    block.block.inputs = nullptr;
    auditedRender(hub, block.block);
    check(block.a[0] == 3 && block.b[0] == 3, "Unavailable inputs retained stale capture samples");
}

void partialWritesAndPublication()
{
    CallbackHub hub(stereo());
    Constant a { 1 }, b { 2 }, discarded { 99 };
    std::array first { CallbackHub::Client { 1, Constant::render, &a, {} } };
    std::array second { CallbackHub::Client { 2, Constant::render, &b, {} } };
    std::array unused { CallbackHub::Client { 3, Constant::render, &discarded, {} } };
    hub.publish(first);
    hub.publish(unused);
    const auto generation = hub.publish(second);
    Block block;
    auditedRender(hub, block.block);
    check(a.calls == 0 && discarded.calls == 0 && b.calls == 1, "Unconsumed publications were not coalesced");
    check(hub.statistics().adoptedGeneration == generation, "Whole snapshot generation not adopted");

    struct Partial {
        static void render(void*, const AudioBlock& block) noexcept { block.outputs[0][0] = 7; }
    };
    std::array mixed { second[0], CallbackHub::Client { 4, Partial::render, nullptr, {} } };
    hub.publish(mixed);
    auditedRender(hub, block.block);
    check(block.a[0] == 9 && block.a[1] == 2 && block.b[0] == 2,
          "Partial client write leaked prior client's scratch data");
    hub.collectRetired();
    hub.publish({});
    auditedRender(hub, block.block);
    check(block.a[0] == 0 && block.b[0] == 0, "Empty snapshot must intentionally silence output");
    hub.resetAfterStop();
    hub.publish(first);
    auditedRender(hub, block.block);
    check(block.a[0] == 1, "Stopped/reset hub did not restart cleanly");
}

void boundsAndInvalidBlocks()
{
    rejects([] { auto config = stereo(); config.maximumBlockFrames = 0; CallbackHub hub(config); }, "Zero frame capacity accepted");
    rejects([] { auto config = stereo(); config.maximumBlockFrames = CallbackHub::maximumFrames + 1; CallbackHub hub(config); }, "Excessive frame capacity accepted");
    rejects([] { auto config = stereo(); config.sampleRate = 0; CallbackHub hub(config); }, "Zero sample rate accepted");
    rejects([] { auto config = stereo(); config.physicalOutputChannels = 129; CallbackHub hub(config); }, "129 physical channels accepted");
    rejects([] { auto config = stereo(); config.outputPhysicalIndices = { 1, 1 }; CallbackHub hub(config); }, "Duplicate mapping accepted");
    rejects([] { auto config = stereo(); config.outputPhysicalIndices = { 0, 2 }; CallbackHub hub(config); }, "Out of range mapping accepted");

    CallbackHub hub(stereo()); Constant constant { 1 };
    std::array good { CallbackHub::Client { 1, Constant::render, &constant, {} } };
    auto generation = hub.publish(good);
    std::array duplicate { good[0], good[0] };
    rejects([&] { hub.publish(duplicate); }, "Duplicate client ID accepted");
    std::array missing { CallbackHub::Client { 1, nullptr, nullptr, {} } };
    rejects([&] { hub.publish(missing); }, "Null callback accepted");
    std::array<CallbackHub::Client, 65> tooMany {};
    rejects([&] { hub.publish(tooMany); }, "Client count overflow accepted");
    Block block(0);
    auditedRender(hub, block.block);
    check(hub.statistics().adoptedGeneration == 0 && constant.calls == 0, "Zero frame block consumed state");
    block.block.frames = 65;
    auditedRender(hub, block.block); // Arrays only hold 64; must not touch them.
    block.block.frames = 32; block.block.sampleRate = 44100;
    auditedRender(hub, block.block);
    block.block.sampleRate = 48000; block.block.outputChannels = 129;
    auditedRender(hub, block.block); // Pointer array only holds two.
    block.block.outputChannels = 2; block.block.outputs = nullptr;
    auditedRender(hub, block.block);
    check(hub.statistics().invalidBlocks == 4 && constant.calls == 0, "Invalid block entered client or was not diagnosed");
    block.block.outputs = block.outputs.data();
    auditedRender(hub, block.block);
    check(constant.calls == 1 && hub.statistics().adoptedGeneration == generation, "Validation error replaced pending snapshot");
    std::atomic<bool> rejected { false };
    std::thread foreign([&] { try { hub.publish(good); } catch (const std::logic_error&) { rejected = true; } });
    foreign.join();
    check(rejected, "Foreign control thread was allowed to publish");
}

void captureOnlyAndMaximumMap()
{
    CallbackHub::Configuration configuration { 48000, 64, 128, 0, { 127 }, {} };
    CallbackHub hub(configuration);
    struct Capture {
        bool valid = false;
        static void render(void* context, const AudioBlock& block) noexcept
        {
            auto& self = *static_cast<Capture*>(context);
            self.valid = block.inputs[127][0] == 42 && block.inputs[126][0] == 0
                && block.outputChannels == 0 && block.outputs == nullptr;
        }
    } capture;
    std::array clients { CallbackHub::Client { 1, Capture::render, &capture, {} } };
    hub.publish(clients);
    std::array<float, 64> samples {}; samples.fill(42);
    const float* input = samples.data();
    AudioBlock block; block.inputs = &input; block.inputChannels = 1; block.frames = 64; block.sampleRate = 48000;
    auditedRender(hub, block);
    check(capture.valid, "Capture-only physical input 127 was not expanded safely");
}

struct Lifetime {
    std::thread::id ownerThread;
    std::atomic<unsigned>& destroyed;
    std::atomic<unsigned>& wrongThread;
    std::atomic<bool>* entered = nullptr;
    std::atomic<bool>* proceed = nullptr;
    float value = 1;
    ~Lifetime()
    {
        if (std::this_thread::get_id() != ownerThread) ++wrongThread;
        ++destroyed;
    }
    static void render(void* context, const AudioBlock& block) noexcept
    {
        auto& self = *static_cast<Lifetime*>(context);
        if (self.entered) {
            self.entered->store(true, std::memory_order_release);
            // Deliberately stall only in this lifetime test to emulate a
            // descheduled client. Production clients must never spin/wait.
            while (!self.proceed->load(std::memory_order_acquire)) std::this_thread::yield();
        }
        for (std::uint32_t channel = 0; channel < block.outputChannels; ++channel)
            std::fill_n(block.outputs[channel], block.frames, self.value);
    }
};

void deferredLifetimeAndOverlap()
{
    std::atomic<unsigned> destroyed { 0 }, wrongThread { 0 };
    std::atomic<bool> entered { false }, proceed { false };
    CallbackHub hub(stereo());
    auto owner = std::shared_ptr<Lifetime>(new Lifetime { std::this_thread::get_id(), destroyed, wrongThread, &entered, &proceed, 3 });
    std::array clients { CallbackHub::Client { 1, Lifetime::render, owner.get(), owner } };
    hub.publish(clients); clients[0].lifetime.reset(); owner.reset();
    Block original;
    std::thread reader([&] { auditedRender(hub, original.block); });
    waitFor([&] { return entered.load(std::memory_order_acquire); });
    Block overlapping;
    auditedRender(hub, overlapping.block);
    check(hub.statistics().overlappingCallbacks == 1, "Overlapping callback entered shared scratch");
    rejects([&] { hub.resetAfterStop(); }, "Reset accepted an active callback");
    hub.publish({}); hub.collectRetired();
    check(destroyed == 0, "Control publication destroyed currently rendering client");
    proceed.store(true, std::memory_order_release);
    reader.join();
    check(original.a[0] == 3 && destroyed == 0, "Rendering client did not finish before retirement");
    auditedRender(hub, original.block); // Retires owner but cannot destroy it.
    check(destroyed == 0 && original.a[0] == 0, "Callback destroyed retired client or failed to adopt empty snapshot");
    check(hub.collectRetired() && destroyed == 1 && wrongThread == 0, "Retired context not destroyed on control thread");
}

void concurrentPublicationNeverDropsAudio()
{
    std::atomic<unsigned> destroyed { 0 }, wrongThread { 0 };
    std::atomic<bool> running { true }, ready { false };
    std::atomic<unsigned> badBlocks { 0 };
    CallbackHub hub(stereo());
    constexpr unsigned publications = 10000;
    auto publish = [&](float value) {
        // Direct initialization avoids a counted temporary owner destructor.
        auto owner = std::shared_ptr<Lifetime>(new Lifetime { std::this_thread::get_id(), destroyed, wrongThread, nullptr, nullptr, value });
        std::array clients { CallbackHub::Client { 1, Lifetime::render, owner.get(), owner } };
        return hub.publish(clients);
    };
    publish(1);
    std::thread reader([&] {
        Block block;
        auditedRender(hub, block.block);
        ready.store(true, std::memory_order_release);
        while (running.load(std::memory_order_acquire)) {
            auditedRender(hub, block.block);
            const auto first = block.a[0];
            if (first != 1 && first != 2) ++badBlocks;
            for (unsigned i = 0; i < 32; ++i)
                if (block.a[i] != first || block.b[i] != first) { ++badBlocks; break; }
        }
    });
    waitFor([&] { return ready.load(std::memory_order_acquire); });
    std::uint64_t latest = 0;
    for (unsigned i = 0; i < publications; ++i) {
        latest = publish((i & 1) ? 2.0f : 1.0f);
        if ((i % 7) == 0) hub.collectRetired();
    }
    waitFor([&] { hub.collectRetired(); return hub.statistics().adoptedGeneration == latest; });
    running.store(false, std::memory_order_release); reader.join();
    hub.resetAfterStop();
    check(badBlocks == 0, "Concurrent publication introduced silence or torn snapshot");
    check(destroyed == publications + 1 && wrongThread == 0, "Concurrent ownership leaked or was reclaimed on audio thread");
    check(hub.statistics().blocks > 1 && hub.statistics().invalidBlocks == 0, "Publication stress did not exercise valid callbacks");
}
}

int main()
{
    try {
        mappingAndMixing();
        partialWritesAndPublication();
        boundsAndInvalidBlocks();
        captureOnlyAndMaximumMap();
        deferredLifetimeAndOverlap();
        concurrentPublicationNeverDropsAudio();
        check(realtimeAllocations == 0, "Realtime callback allocated memory");
        check(realtimeDeallocations == 0, "Realtime callback destroyed memory");
        std::cout << "Native callback hub: mapping, mixing, bounds, capture, lifetime, publication and allocation tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
