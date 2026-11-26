#pragma once

#include "AudioDevice.h"
#include <array>
#include <atomic>
#include <cstddef>
#include <memory>
#include <span>
#include <thread>

namespace catlive::native::audio {

// A prepared, sequential mixer for independently rendered clients. This is not
// a graph scheduler and does not make a client's own callback realtime-safe.
//
// Construct, publish, collectRetired and destroy on one non-reentrant control
// thread (context destructors must not call back into this hub). The
// device must be stopped/joined before resetAfterStop or destruction, and cannot
// restart until those operations return. There is one serialized audio reader.
// The callback never releases an owner, allocates, waits, or retries publication.
class CallbackHub final {
public:
    static constexpr std::uint32_t maximumChannels = 128;
    static constexpr std::uint32_t maximumClients = 64;
    static constexpr std::uint32_t maximumFrames = 65536;

    struct Configuration {
        double sampleRate = 0;
        std::uint32_t maximumBlockFrames = 0;
        std::uint32_t physicalInputChannels = 0;
        std::uint32_t physicalOutputChannels = 0;
        // Match StreamInfo's packed channel order. Empty means no channels,
        // unlike StreamRequest's empty-map convention. Expand defaults first.
        std::vector<std::uint32_t> inputPhysicalIndices;
        std::vector<std::uint32_t> outputPhysicalIndices;
    };
    struct Client {
        std::uint64_t id = 0; // Nonzero and unique within a publication.
        ProcessCallback render = nullptr;
        void* context = nullptr;
        // Optional ownership only; context need not equal lifetime.get(). The
        // hub releases this reference exclusively on its control thread. If
        // omitted, context must stay valid until the device stops and resets.
        std::shared_ptr<void> lifetime;
    };
    struct Statistics {
        std::uint64_t blocks = 0;
        std::uint64_t frames = 0;
        std::uint64_t clientCalls = 0;
        std::uint64_t invalidBlocks = 0;
        std::uint64_t overlappingCallbacks = 0;
        std::uint64_t adoptedGeneration = 0;
    };

    explicit CallbackHub(Configuration);
    ~CallbackHub();
    CallbackHub(const CallbackHub&) = delete;
    CallbackHub& operator=(const CallbackHub&) = delete;

    // Allocates/validates entirely on the control thread. The newest pending
    // publication replaces an unconsumed one. Each block sees one complete
    // snapshot. An empty list deliberately produces silence.
    std::uint64_t publish(std::span<const Client>);
    // Service regularly from the control loop, including when no edits occur.
    // Until a retired snapshot is collected the callback keeps using its
    // current snapshot; it does not block or drop audio to adopt a newer one.
    bool collectRetired();
    // Only after AudioDevice::stop has joined all callbacks. Releases current,
    // pending and retired owners; permits a subsequent publish/start cycle.
    void resetAfterStop();
    Statistics statistics() const noexcept;

    static void process(void*, const AudioBlock&) noexcept;
    void render(const AudioBlock&) noexcept;

private:
    struct Snapshot;
    void requireControlThread() const;
    void collectRetiredUnchecked() noexcept;
    void adoptPending() noexcept;
    bool validBlock(const AudioBlock&) const noexcept;

    Configuration configuration_;
    const std::thread::id controlThread_;
    std::vector<float> scratch_, inputScratch_, silence_;
    std::array<const float*, maximumChannels> physicalInputs_ {};
    std::array<float*, maximumChannels> physicalOutputs_ {};

    // Ownership: control owns pending until exchange; audio owns current;
    // audio parks the previous current into retired for control destruction.
    // At most three snapshots are retained, plus a temporary publication.
    std::atomic<Snapshot*> pending_ { nullptr };
    std::atomic<Snapshot*> retired_ { nullptr };
    Snapshot* current_ = nullptr; // Audio-only except after stop/join.
    std::uint64_t nextGeneration_ = 1; // Control-only.
    std::atomic_flag rendering_ = ATOMIC_FLAG_INIT;
    std::atomic<std::uint64_t> blocks_ { 0 }, frames_ { 0 }, clientCalls_ { 0 };
    std::atomic<std::uint64_t> invalidBlocks_ { 0 }, overlappingCallbacks_ { 0 };
    std::atomic<std::uint64_t> adoptedGeneration_ { 0 };
};
} // namespace catlive::native::audio
